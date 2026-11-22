import Foundation
import HermesKit
import HermesMCPServer

/// JSON-RPC/MCP handling for the browser tool server, the HTTP router's security gates, the config.yaml editor,
/// and one headless round trip over a real loopback socket (no GUI, no WebKit).
func runMCPChecks() {
    let core = MCPServerCore(name: "hermes_mac", version: "test", instructions: "hi", tools: BrowserToolCatalog.tools) { name, args in
        if name == "client_browser_screenshot" { return MCPToolResult(content: [.text("shot"), .image(Data([1, 2, 3]), mimeType: "image/png")]) }
        if name == "client_browser_click" { return .error("stale ref \(args.string("ref") ?? "?")") }
        return .text("ok \(name) \(args.string("url") ?? "")")
    }
    func call(_ body: String) -> JSONValue? {
        var out: Data?
        var done = false
        Task { out = await core.handle(body: Data(body.utf8)); done = true }
        waitPumpingRunLoop(timeout: 5) { done }
        return out.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    check("mcp initialize negotiates version") {
        let r = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        expect(r?["id"] == .number(1), "\(String(describing: r))")
        expect(r?["result"]?["protocolVersion"]?.string == "2025-06-18")
        expect(r?["result"]?["capabilities"]?["tools"] != nil)
        expect(r?["result"]?["serverInfo"]?["name"]?.string == "hermes_mac")
        let future = call(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        expect(future?["result"]?["protocolVersion"]?.string == MCPServerCore.supportedVersions[0])
        expect(future?["id"]?.string == "a")
    }
    check("mcp id 1 round-trips as integer") {
        let raw = { () -> String in
            var s = ""; var done = false
            Task { s = String(data: await core.handle(body: Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)) ?? Data(), encoding: .utf8) ?? ""; done = true }
            waitPumpingRunLoop(timeout: 5) { done }
            return s
        }()
        expect(raw.contains(#""id":7"#) && !raw.contains("7.0"), raw)
    }
    check("mcp notifications and responses get no reply") {
        var out: Data? = Data(); var done = false
        Task { out = await core.handle(body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)); done = true }
        waitPumpingRunLoop(timeout: 5) { done }
        expect(out == nil)
        done = false; out = Data()
        Task { out = await core.handle(body: Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)); done = true }
        waitPumpingRunLoop(timeout: 5) { done }
        expect(out == nil)
    }
    check("mcp tools/list exposes the browser tools with schemas") {
        let tools = call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"]?["tools"]
        guard case .array(let list)? = tools else { expect(false, "no tools"); return }
        let names = list.compactMap { $0["name"]?.string }
        expect(names.contains("client_browser_navigate") && names.contains("client_browser_snapshot") && names.contains("client_browser_click")
               && names.contains("client_browser_type") && names.contains("client_browser_screenshot"), "\(names)")
        expect(names.allSatisfy { ("mcp_hermes_mac_" + $0).count <= 64 }, "prefixed name too long for OpenAI-style tool limits")
        for t in list {
            expect(t["inputSchema"]?["type"]?.string == "object", "\(t["name"] ?? .null)")
            expect(t["annotations"]?["readOnlyHint"]?.bool != nil)
        }
        let nav = list.first { $0["name"]?.string == "client_browser_navigate" }
        expect(nav?["inputSchema"]?["required"] == .array([.string("url")]))
    }
    check("mcp tools/call text, image, isError, unknown tool, bad args") {
        let ok = call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"client_browser_navigate","arguments":{"url":"https://x.test"}}}"#)
        expect(ok?["result"]?["content"] == .array([.object(["type": .string("text"), "text": .string("ok client_browser_navigate https://x.test")])]), "\(String(describing: ok))")
        expect(ok?["result"]?["isError"]?.bool == false)
        let img = call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"client_browser_screenshot"}}"#)
        if case .array(let c)? = img?["result"]?["content"] {
            expect(c.count == 2 && c[1]["type"]?.string == "image" && c[1]["data"]?.string == "AQID" && c[1]["mimeType"]?.string == "image/png")
        } else { expect(false, "no image content") }
        let err = call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"client_browser_click","arguments":{"ref":"e9"}}}"#)
        expect(err?["result"]?["isError"]?.bool == true)
        let unknown = call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rm_rf"}}"#)
        expect(unknown?["error"]?["code"] == .number(-32602))
        let badArgs = call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"client_browser_back","arguments":[1]}}"#)
        expect(badArgs?["error"]?["code"] == .number(-32602))
        expect(call(#"{"jsonrpc":"2.0","id":10,"method":"resources/list"}"#)?["error"]?["code"] == .number(-32601))
        expect(call("{nope")?["error"]?["code"] == .number(-32700))
    }
    check("mcp batch") {
        let r = call(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        if case .array(let a)? = r { expect(a.count == 1) } else { expect(false, "\(String(describing: r))") }
    }
    check("tool args coerce quoted numbers and bools") {
        let a: [String: JSONValue] = ["n": .string("12"), "b": .string("true"), "m": .number(3)]
        expect(a.int("n") == 12 && a.int("m") == 3 && a.bool("b") == true && a.int("x") == nil)
    }

    check("http parser") {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\nabcd"
        guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { expect(false); return }
        expect(r.method == "POST" && r.path == "/mcp" && r.headers["content-type"] == "application/json" && r.body == Data("abcd".utf8))
        expect(HTTPParser.parse(Data(raw.dropLast(2).utf8)) == .incomplete)
        expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
        if case .invalid(let s, _) = HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8)) { expect(s == 400) } else { expect(false) }
        if case .invalid(let s, _) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) { expect(s == 413) } else { expect(false) }
        if case .invalid(let s, _) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) { expect(s == 501) } else { expect(false) }
    }

    let router = MCPHTTPRouter(core: core, token: "sekret")
    func route(_ method: String = "POST", path: String = "/mcp", headers: [String: String] = [:], body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> HTTPResponse {
        var h = ["host": "127.0.0.1:47615", "authorization": "Bearer sekret", "content-type": "application/json"]
        for (k, v) in headers { h[k] = v.isEmpty ? nil : v }
        var out = HTTPResponse(status: 0); var done = false
        Task { out = await router.respond(to: HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8))); done = true }
        waitPumpingRunLoop(timeout: 5) { done }
        return out
    }
    check("router security gates") {
        expect(route().status == 200)
        expect(route(headers: ["authorization": "Bearer wrong"]).status == 401)
        expect(route(headers: ["authorization": ""]).status == 401)
        expect(route(headers: ["authorization": "Bearer sekret2"]).status == 401)
        expect(route(headers: ["host": "evil.example:47615"]).status == 403, "DNS rebinding Host must be refused")
        expect(route(headers: ["host": "localhost:47615"]).status == 200)
        expect(route(headers: ["host": "[::1]:47615"]).status == 200)
        expect(route(headers: ["origin": "https://evil.example"]).status == 403, "browser Origin must be refused")
        expect(route(headers: ["origin": "http://127.0.0.1:3000"]).status == 200)
        expect(route(path: "/other").status == 404)
        expect(route(path: "/mcp?x=1").status == 200)
        expect(route("GET").status == 405 && route("HEAD").status == 405 && route("DELETE").status == 405)
        expect(route("OPTIONS").headers.allSatisfy { !$0.0.lowercased().hasPrefix("access-control") }, "no CORS")
        expect(route(headers: ["content-type": "text/plain"]).status == 415)
        expect(route(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).status == 202)
        let unauth = route(headers: ["authorization": ""])
        expect(unauth.headers.contains { $0.0 == "WWW-Authenticate" })
    }
    check("router refuses an empty configured token") {
        let open = MCPHTTPRouter(core: core, token: "")
        var s = 0; var done = false
        Task { s = await open.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1", "authorization": "Bearer ", "content-type": "application/json"], body: Data("{}".utf8))).status; done = true }
        waitPumpingRunLoop(timeout: 5) { done }
        expect(s == 401)
    }

    check("config.yaml upsert/remove") {
        let e = MCPConfigYAML.entry(port: 47615, token: "T")
        let fresh = try MCPConfigYAML.upsert("model:\n  default: x\n", entry: e)
        expect(fresh == "model:\n  default: x\n\nmcp_servers:\n  hermes_mac:\n    url: \"http://127.0.0.1:47615/mcp\"\n    headers:\n      Authorization: \"Bearer T\"\n    timeout: 120\n    connect_timeout: 10\n", fresh)
        expect(MCPConfigYAML.contains(fresh))
        // Idempotent, and replaces an older entry in place without touching siblings or comments.
        let again = try MCPConfigYAML.upsert(fresh, entry: e); expect(again == fresh, again)
        let existing = "# top\nmcp_servers:   # mine\n    fs:\n        command: npx\n\n    hermes_mac:\n        url: old\n        # note\n    # sibling comment\n    gh:\n        url: g\nplatforms:\n  x: 1\n"
        let up = try MCPConfigYAML.upsert(existing, entry: MCPConfigYAML.entry(port: 1, token: "N"))
        expect(up.contains("mcp_servers:   # mine\n    fs:\n        command: npx\n\n    hermes_mac:\n      url: \"http://127.0.0.1:1/mcp\""), up)
        expect(!up.contains("url: old") && up.contains("    # sibling comment\n    gh:\n        url: g\nplatforms:\n  x: 1\n"), up)
        let empty = try MCPConfigYAML.upsert("mcp_servers: {}\nother: 1", entry: e)
        expect(empty.hasPrefix("mcp_servers:\n  hermes_mac:\n") && empty.hasSuffix("other: 1\n"), empty)
        do { _ = try MCPConfigYAML.upsert("mcp_servers: {a: {url: x}}\n", entry: e); expect(false, "flow style must throw") } catch {}
        // Remove keeps the others; removing the last one leaves a valid empty mapping.
        let removed = try MCPConfigYAML.remove(up)
        expect(!removed.contains("hermes_mac") && removed.contains("    fs:\n") && removed.contains("    gh:\n"), removed)
        let r2 = try MCPConfigYAML.remove(fresh); expect(r2 == "model:\n  default: x\n\nmcp_servers: {}\n", r2)
        let r3 = try MCPConfigYAML.remove("a: 1\n"); expect(r3 == "a: 1\n")
        // A key that merely starts with our name is a different server.
        expect(!MCPConfigYAML.contains("mcp_servers:\n  hermes_mac_old:\n    url: x\n"))
    }

    check("browser address parsing") {
        expect(BrowserAddress.url(from: "example.com")?.absoluteString == "https://example.com")
        expect(BrowserAddress.url(from: "localhost:3000/x")?.absoluteString == "http://localhost:3000/x")
        expect(BrowserAddress.url(from: "https://a.b/c?d=1")?.absoluteString == "https://a.b/c?d=1")
        expect(BrowserAddress.url(from: "file:///etc/passwd") == nil)
        expect(BrowserAddress.url(from: "javascript:alert(1)") == nil)
        expect(BrowserAddress.resolve("file:///etc/passwd") == nil)
        expect(BrowserAddress.resolve("swift concurrency")?.host() == "duckduckgo.com")
        expect(BrowserAddress.resolve("javascript:alert(1)")?.host() == "duckduckgo.com", "searched, never executed")
    }

    check("listener: real socket round trip (initialize, tools/list, auth)") {
        let listener = MCPHTTPListener(port: 0, router: router)
        var port: UInt16 = 0; var done = false; var failure: String?
        Task {
            do { port = try await listener.start() } catch { failure = "\(error)" }
            done = true
        }
        waitPumpingRunLoop(timeout: 10) { done }
        guard port != 0 else { expect(false, "listener did not start: \(failure ?? "?")"); return }
        defer { listener.stop() }
        // Security: a second bind of the same port must fail (no endpoint reuse that could intercept the token).
        let squatter = MCPHTTPListener(port: port, router: router)
        var squatErr: String?; var squatDone = false
        Task {
            do { _ = try await squatter.start(); squatter.stop() } catch { squatErr = error.localizedDescription }
            squatDone = true
        }
        waitPumpingRunLoop(timeout: 10) { squatDone }
        expect(squatErr?.contains("already in use") == true, "second listener on \(port) must fail: \(squatErr ?? "it bound")")
        func post(_ body: String, token: String = "sekret") -> (Int, JSONValue?) {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            r.httpMethod = "POST"; r.httpBody = Data(body.utf8)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var status = 0; var json: JSONValue?; var fin = false
            Task {
                if let (d, resp) = try? await URLSession.shared.data(for: r) {
                    status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    json = try? JSONDecoder().decode(JSONValue.self, from: d)
                }
                fin = true
            }
            waitPumpingRunLoop(timeout: 10) { fin }
            return (status, json)
        }
        let (s1, init_) = post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        expect(s1 == 200 && init_?["result"]?["protocolVersion"]?.string == "2025-11-25", "\(s1) \(String(describing: init_))")
        expect(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0 == 202)
        let (s2, list) = post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        if case .array(let a)? = list?["result"]?["tools"] { expect(s2 == 200 && a.count == BrowserToolCatalog.tools.count) } else { expect(false) }
        expect(post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: "nope").0 == 401)
        // A big body arrives in several TCP reads.
        let big = String(repeating: "x", count: 300_000)
        let (s3, echo) = post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"client_browser_navigate","arguments":{"url":"\#(big)"}}}"#)
        expect(s3 == 200 && echo?["result"]?["content"] != nil, "\(s3)")

        // Opt-in: the official MCP Python SDK (what Hermes uses) against this listener.
        // HERMES_MCP_PYTHON=/path/to/hermes-agent/venv/bin/python swift run hermes-checks
        if let py = ProcessInfo.processInfo.environment["HERMES_MCP_PYTHON"] {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../scripts/mcp-sdk-probe.py").standardized.path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: py)
            p.arguments = ["-I", script, "http://127.0.0.1:\(port)/mcp", "sekret"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { expect(false, "spawn \(py): \(error)"); return }
            waitPumpingRunLoop(timeout: 60) { !p.isRunning }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("mcp sdk probe: \(out.split(separator: "\n").last ?? "")")
            expect(p.terminationStatus == 0 && out.contains("OK version=2025-11-25 tools=\(BrowserToolCatalog.tools.count)"), out)
        }
    }
}
