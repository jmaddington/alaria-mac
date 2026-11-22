import Foundation
import os

let mcpLog = Logger(subsystem: "net.jmaddington.hermes", category: "mcp")

// AIDEV-NOTE: pure Foundation on purpose (HermesKit also compiles on iOS). The Network.framework listener lives in
// the HermesMCPServer target and everything WebKit in the app. See docs/agents/browser-tool.md.

/// One tool a local MCP server exposes (`tools/list` entry).
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// `annotations.readOnlyHint`. Hermes only prompts on `trust: untrusted` servers, and then not for read-only tools.
    public var readOnly: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }

    var json: JSONValue {
        .object(["name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
                 "annotations": .object(["title": .string(title), "readOnlyHint": .bool(readOnly),
                                         "destructiveHint": .bool(false), "openWorldHint": .bool(true)])])
    }
}

/// A content block in a `tools/call` result.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let t): .object(["type": .string("text"), "text": .string(t)])
        case .image(let d, let mime): .object(["type": .string("image"), "data": .string(d.base64EncodedString()), "mimeType": .string(mime)])
        }
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public var content: [MCPContent]
    /// Tool-level failure: the model sees the text and can recover (as opposed to a JSON-RPC protocol error).
    public var isError: Bool
    public init(content: [MCPContent], isError: Bool = false) { self.content = content; self.isError = isError }
    public static func text(_ s: String) -> MCPToolResult { MCPToolResult(content: [.text(s)]) }
    public static func error(_ s: String) -> MCPToolResult { MCPToolResult(content: [.text(s)], isError: true) }

    var json: JSONValue { .object(["content": .array(content.map(\.json)), "isError": .bool(isError)]) }
}

/// JSON-RPC 2.0 + MCP lifecycle for a tools-only server. Transport-agnostic: feed it a request body, get the
/// response body back (nil when the message was a notification or a response, i.e. HTTP 202 with no body).
public final class MCPServerCore: Sendable {
    public typealias ToolHandler = @Sendable (_ name: String, _ arguments: [String: JSONValue]) async -> MCPToolResult

    /// Handshake revisions we answer with. A client asking for one of these gets it echoed; anything else gets the newest.
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String?
    public let tools: [MCPTool]
    let handler: ToolHandler

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool], handler: @escaping ToolHandler) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools; self.handler = handler
    }

    public enum ErrorCode: Int {
        case parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    }

    /// Handles one HTTP POST body: a single message or a (pre-2025-06-18) batch array.
    public func handle(body: Data) async -> Data? {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return Self.encode(Self.error(id: .null, .parse, "Parse error"))
        }
        if case .array(let batch) = msg {
            if batch.isEmpty { return Self.encode(Self.error(id: .null, .invalidRequest, "Empty batch")) }
            var out: [JSONValue] = []
            for m in batch { if let r = await handle(message: m) { out.append(r) } }
            return out.isEmpty ? nil : Self.encode(.array(out))
        }
        return await handle(message: msg).map(Self.encode)
    }

    /// One JSON-RPC message. Returns nil for notifications and for responses (we never send requests).
    public func handle(message: JSONValue) async -> JSONValue? {
        guard case .object(let o) = message else { return Self.error(id: .null, .invalidRequest, "Expected a JSON-RPC object") }
        let id = o["id"]
        guard let method = o["method"]?.string else {
            // A response to something we sent (we send nothing) or junk with an id.
            return o["result"] != nil || o["error"] != nil ? nil : Self.error(id: id ?? .null, .invalidRequest, "Missing method")
        }
        guard let id else { return nil } // notification: notifications/initialized, notifications/cancelled, ...
        let params = o["params"]
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.string ?? ""
            let v = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(v),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "version": .string(version)]),
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return Self.result(id: id, .object(result))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(tools.map(\.json))]))
        case "tools/call":
            guard let toolName = params?["name"]?.string else { return Self.error(id: id, .invalidParams, "tools/call needs params.name") }
            guard tools.contains(where: { $0.name == toolName }) else { return Self.error(id: id, .invalidParams, "Unknown tool: \(toolName)") }
            var args: [String: JSONValue] = [:]
            switch params?["arguments"] {
            case .object(let a)?: args = a
            case nil, .null?: break
            default: return Self.error(id: id, .invalidParams, "params.arguments must be an object")
            }
            mcpLog.info("tools/call \(toolName, privacy: .public) [MCP-CALL]")
            let r = await handler(toolName, args)
            if r.isError { mcpLog.info("tools/call \(toolName, privacy: .public) returned isError [MCP-CALL-TOOLERR]") }
            return Self.result(id: id, r.json)
        default:
            return Self.error(id: id, .methodNotFound, "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ r: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": r]) }
    static func error(id: JSONValue, _ code: ErrorCode, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code.rawValue)), "message": .string(message)])])
    }
    static func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        return (try? e.encode(v)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8)
    }
}

// MARK: Argument helpers for tool handlers

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ k: String) -> String? { self[k]?.string }
    func int(_ k: String) -> Int? {
        if let d = self[k]?.double, d.isFinite { return Int(d) }
        if let s = self[k]?.string { return Int(s) } // small models sometimes quote numbers
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = self[k]?.bool { return b }
        if let s = self[k]?.string?.lowercased() { return s == "true" ? true : s == "false" ? false : nil }
        return nil
    }
}
