import Foundation

/// Minimal HTTP/1.1 request parsing + MCP Streamable HTTP routing for a loopback-only server.
/// Pure Foundation so it can be unit-checked; the socket side is HermesMCPServer.MCPHTTPListener.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Header names lowercased. Repeated headers keep the last value (fine for what we read).
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public enum HTTPParseResult: Equatable {
    case incomplete
    case invalid(status: Int, String)
    case complete(HTTPRequest)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 32 * 1024
    public static let maxBodyBytes = 4 * 1024 * 1024

    public static func parse(_ buf: Data) -> HTTPParseResult {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = buf.range(of: sep) else {
            return buf.count > maxHeaderBytes ? .invalid(status: 431, "Request headers too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes, let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 431, "Request headers too large")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400, "Bad request line") }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() where !l.isEmpty {
            guard let c = l.firstIndex(of: ":") else { return .invalid(status: 400, "Bad header") }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"].map({ $0.lowercased() != "identity" }) == true {
            return .invalid(status: 501, "Chunked request bodies are not supported") // httpx sends Content-Length for JSON
        }
        let length: Int
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid(status: 400, "Bad Content-Length") }
            length = n
        } else { length = 0 }
        if length > maxBodyBytes { return .invalid(status: 413, "Request body too large") }
        let bodyStart = end.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return .incomplete }
        let body = Data(buf[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), headers: headers, body: body))
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    static func json(_ status: Int, _ body: Data, extra: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + extra, body: body)
    }
    static func plain(_ status: Int, _ text: String, extra: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + extra, body: Data(text.utf8))
    }

    public func serialized() -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(s.utf8) + body
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"
        case 404: "Not Found"; case 405: "Method Not Allowed"; case 413: "Payload Too Large"; case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"; case 501: "Not Implemented"; default: "Error"
        }
    }
}

/// Streamable HTTP (MCP 2025-03-26+) in its simplest legal form: POST-only, JSON responses, no SSE stream, no
/// session id. GET/HEAD/DELETE get 405, which both the MCP SDK and Hermes' content-type preflight accept.
// AIDEV-NOTE: security. Order matters: path, then Host/Origin (DNS rebinding), then bearer token, then method.
// Never add CORS headers: a web page (including one in our own browser panel) must not be able to call this.
public struct MCPHTTPRouter: Sendable {
    public let core: MCPServerCore
    public let token: String
    public let path: String

    public init(core: MCPServerCore, token: String, path: String = "/mcp") {
        self.core = core; self.token = token; self.path = path
    }

    public func respond(to req: HTTPRequest) async -> HTTPResponse {
        let p = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.path
        guard p == path || p == path + "/" else { return .plain(404, "Not found") }
        guard Self.isLoopbackHost(req.headers["host"]) else { return .plain(403, "Host not allowed") }
        if let origin = req.headers["origin"], !Self.isLoopbackOrigin(origin) { return .plain(403, "Origin not allowed") }
        guard let auth = req.headers["authorization"], Self.constantTimeEquals(auth, "Bearer \(token)"), !token.isEmpty else {
            return .plain(401, "Missing or wrong bearer token", extra: [("WWW-Authenticate", "Bearer")])
        }
        switch req.method {
        case "POST":
            let ct = req.headers["content-type"]?.lowercased() ?? ""
            guard ct.hasPrefix("application/json") else { return .plain(415, "Content-Type must be application/json") }
            guard let out = await core.handle(body: req.body) else { return HTTPResponse(status: 202) }
            return .json(200, out)
        default:
            return .plain(405, "This MCP server only accepts POST", extra: [("Allow", "POST")])
        }
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") { h = String(h.dropFirst().prefix { $0 != "]" }) } // [::1]:port
        else if let c = h.lastIndex(of: ":") { h = String(h[..<c]) }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let u = URL(string: origin), let h = u.host() else { return false }
        return isLoopbackHost(h.contains(":") ? "[\(h)]" : h)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }
}
