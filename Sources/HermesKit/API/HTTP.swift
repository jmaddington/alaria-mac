import Foundation
import os

let apiLog = Logger(subsystem: "net.jmaddington.hermes", category: "api")

public struct HermesError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public let code: String?
    public var errorDescription: String? { message }
    public init(status: Int, message: String, code: String? = nil) { self.status = status; self.message = message; self.code = code }

    /// Parses the THREE error envelopes Hermes uses: OpenAI-style `{"error":{message,code}}` (API server),
    /// bare `{"error":"..."}` (jobs API), FastAPI `{"detail": str|obj}` (dashboard).
    public static func from(status: Int, data: Data) -> HermesError {
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let d = obj as? [String: Any] {
            if let e = d["error"] as? [String: Any] {
                return HermesError(status: status, message: e["message"] as? String ?? "Request failed", code: e["code"] as? String)
            }
            // Bare string errors may carry a top-level code, e.g. the /p/<profile>/ 404 {"error":..,"code":"profile_unknown"}.
            if let e = d["error"] as? String { return HermesError(status: status, message: e, code: d["code"] as? String) }
            if let e = d["detail"] as? String { return HermesError(status: status, message: e) }
            if let e = d["detail"] { return HermesError(status: status, message: "\(e)") }
        }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        return HermesError(status: status, message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }
}

/// One Hermes HTTP endpoint (API server or dashboard) with its auth header.
public struct Endpoint: Sendable, Equatable, Codable {
    public var baseURL: URL
    public var token: String
    /// "Authorization: Bearer" for the API server; dashboard accepts either, we send X-Hermes-Session-Token.
    public var headerName: String
    public init(baseURL: URL, token: String, headerName: String) { self.baseURL = baseURL; self.token = token; self.headerName = headerName }

    func applyAuth(_ r: inout URLRequest) {
        if headerName == "Authorization" { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        else { r.setValue(token, forHTTPHeaderField: headerName) }
    }
}

public final class HTTPCore: Sendable {
    public let endpoint: Endpoint
    let session: URLSession
    /// Prepended to every path: `/p/<profile>` routes API-server calls to a multiplexed profile.
    public let pathPrefix: String
    /// Merged into every query: `profile=<name>` scopes dashboard calls to a profile.
    public let fixedQuery: [String: String]
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 // streams can run for a long agent turn
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        pathPrefix = ""
        fixedQuery = [:]
    }

    init(endpoint: Endpoint, session: URLSession, pathPrefix: String, fixedQuery: [String: String]) {
        self.endpoint = endpoint; self.session = session; self.pathPrefix = pathPrefix; self.fixedQuery = fixedQuery
    }

    /// A copy that shares this core's URLSession but routes every call through `pathPrefix` / `fixedQuery`
    /// (and optionally another token: a named profile has its own API_SERVER_KEY).
    func scoped(pathPrefix: String = "", fixedQuery: [String: String] = [:], token: String? = nil) -> HTTPCore {
        var e = endpoint
        if let token { e.token = token }
        return HTTPCore(endpoint: e, session: session, pathPrefix: pathPrefix, fixedQuery: fixedQuery)
    }

    /// The URL a call to `path` goes to, after the profile prefix and fixed query are applied.
    public func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var q = query
        for (k, v) in fixedQuery where q[k] == nil { q[k] = v }
        return Self.url(base: endpoint.baseURL, path: pathPrefix + path, query: q)
    }

    /// Builds a request URL. `path` is ALREADY percent-encoded (HermesClient.path escapes ids), so it goes into
    /// percentEncodedPath; assigning it to `path` encoded it twice (hermes-mac-d80). Query values escape `+`, `&`,
    /// `=` too: the server decodes a literal `+` as a space, so "c++" searched for "c  " (hermes-mac-jcv).
    public static func url(base: URL, path: String, query: [String: String?] = [:]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let basePath = comps.percentEncodedPath.hasSuffix("/") ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        comps.percentEncodedPath = basePath + path
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        let items = query.compactMap { k, v in
            v.map { URLQueryItem(name: k, value: $0.addingPercentEncoding(withAllowedCharacters: allowed)) }
        }
        if !items.isEmpty { comps.percentEncodedQueryItems = items.sorted { $0.name < $1.name } }
        return comps.url!
    }

    func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        endpoint.applyAuth(&r)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    @discardableResult
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw HermesError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let err = HermesError.from(status: http.statusCode, data: data)
            apiLog.error("\(r.httpMethod ?? "?", privacy: .public) \(r.url?.path ?? "", privacy: .public) -> \(http.statusCode) \(err.message, privacy: .public) [API-HTTP-ERR]")
            throw err
        }
        return (data, http)
    }

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as: T.Type = T.self) async throws -> T {
        let (d, _) = try await send(request("GET", path, query: query))
        return try decode(T.self, d, path)
    }

    func json<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any?] = [:], query: [String: String?] = [:], as: T.Type = T.self) async throws -> T {
        let clean = body.compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: clean)
        let (d, _) = try await send(request(method, path, query: query, body: data))
        return try decode(T.self, d, path)
    }

    func decode<T: Decodable>(_ t: T.Type, _ d: Data, _ path: String) throws -> T {
        do { return try Self.decoder.decode(T.self, from: d) } catch {
            apiLog.error("decode \(path, privacy: .public) as \(String(describing: T.self), privacy: .public): \(String(describing: error), privacy: .public) [API-DECODE]")
            throw HermesError(status: 0, message: "Unexpected response from \(path)")
        }
    }

    /// Server-sent events. Yields (event name, data JSON) frames; skips `:` comment keepalives.
    func stream(_ r: URLRequest) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = r
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 60 * 60
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw HermesError(status: 0, message: "No HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var d = Data()
                        for try await b in bytes { d.append(b); if d.count > 4000 { break } }
                        throw HermesError.from(status: http.statusCode, data: d)
                    }
                    var parser = SSEParser()
                    var lines = SSELineSplitter()
                    // AIDEV-NOTE: not bytes.lines: it drops blank lines, so a frame followed by silence (an
                    // approval.request waiting on the user) was held until the next event. hermes-mac-bhv.
                    for try await b in bytes {
                        if let line = lines.push(b), let f = parser.feed(line) { cont.yield(f) }
                    }
                    if let line = lines.finish(), let f = parser.feed(line) { cont.yield(f) }
                    if let f = parser.feed("") { cont.yield(f) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

public struct SSEFrame: Sendable {
    public var event: String
    public var data: Data
    public func decode<T: Decodable>(_ t: T.Type) -> T? { try? HTTPCore.decoder.decode(T.self, from: data) }
    public var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
}

/// Splits a byte stream into lines on LF, keeping empty lines (SSE frame separators). CR is left for SSEParser.
public struct SSELineSplitter: Sendable {
    var buf: [UInt8] = []
    public init() {}
    public mutating func push(_ b: UInt8) -> String? {
        guard b == 0x0A else { buf.append(b); return nil }
        defer { buf.removeAll(keepingCapacity: true) }
        return String(decoding: buf, as: UTF8.self)
    }
    public mutating func finish() -> String? {
        guard !buf.isEmpty else { return nil }
        defer { buf.removeAll() }
        return String(decoding: buf, as: UTF8.self)
    }
}

/// Line-oriented SSE parser. NOTE: URLSession's `bytes.lines` drops empty lines, so a frame is also
/// flushed when a new `event:` line arrives or a `data:` follows an already-complete data line.
// AIDEV-NOTE: AsyncLineSequence swallows blank separators; that's why flush-on-next-event exists. Tested in checks.
public struct SSEParser: Sendable {
    var event = "message"
    var data: [String] = []
    public init() {}

    public mutating func feed(_ raw: String) -> SSEFrame? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let (field, value): (String, String) = {
            guard let i = line.firstIndex(of: ":") else { return (line, "") }
            var v = String(line[line.index(after: i)...])
            if v.hasPrefix(" ") { v.removeFirst() }
            return (String(line[..<i]), v)
        }()
        switch field {
        case "event":
            let out = flush()
            event = value
            return out
        case "data":
            // Hermes always sends one JSON object per data line; a second data line means a new frame.
            let out = data.isEmpty ? nil : flush()
            data.append(value)
            return out
        default: return nil // id:, retry:
        }
    }

    mutating func flush() -> SSEFrame? {
        defer { event = "message"; data = [] }
        guard !data.isEmpty else { return nil }
        return SSEFrame(event: event, data: Data(data.joined(separator: "\n").utf8))
    }
}

/// Loosely-typed JSON for fields Hermes leaves open (runtime, origin, approval payloads, metadata).
public enum JSONValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}
