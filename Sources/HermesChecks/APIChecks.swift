import Foundation
import HermesKit

/// Unit checks for the SSE parser, plus live checks against scripts/dev-hermes.sh when dev/hermes-home/.env exists.
/// HERMES_CHECK_CHAT=1 also runs one real streamed chat turn (slow on a local model).
func runAPIChecks() {
    check("url building: ids encoded once, + & = escaped in queries (hermes-mac-d80, -jcv)") {
        let base = URL(string: "http://h:1/prefix/")!
        let u = HTTPCore.url(base: base, path: "/api/sessions/\(HermesClient.path("a b%/c"))/messages", query: ["q": "c++ & x=1", "n": nil])
        expect(u.absoluteString == "http://h:1/prefix/api/sessions/a%20b%25%2Fc/messages?q=c%2B%2B%20%26%20x%3D1", u.absoluteString)
    }
    check("sse parser without blank lines (URLSession.lines drops them)") {
        var p = SSEParser()
        var frames: [SSEFrame] = []
        for l in ["event: run.started", #"data: {"run_id":"r1"}"#, ": keepalive", "event: assistant.delta", #"data: {"delta":"hi"}"#, "event: done", "data: {}"] {
            if let f = p.feed(l) { frames.append(f) }
        }
        if let f = p.feed("") { frames.append(f) }
        expect(frames.map(\.event) == ["run.started", "assistant.delta", "done"], "\(frames.map(\.event))")
        expect(frames.first?.object?["run_id"] as? String == "r1")
    }
    check("sse: a frame is delivered at its blank line, not held for the next event (hermes-mac-bhv)") {
        var lines = SSELineSplitter(), p = SSEParser()
        var frames: [SSEFrame] = []
        for b in Array("event: approval.request\r\ndata: {\"request_id\":\"q\"}\r\n\r\n".utf8) {
            if let l = lines.push(b), let f = p.feed(l) { frames.append(f) }
        }
        expect(frames.map(\.event) == ["approval.request"], "\(frames.map(\.event))")
        expect(frames.first?.object?["request_id"] as? String == "q")
    }
    check("sse parser plain data frames") {
        var p = SSEParser()
        var n = 0
        for l in [#"data: {"a":1}"#, "", #"data: {"a":2}"#, #"data: {"a":3}"#] { if p.feed(l) != nil { n += 1 } }
        if p.feed("") != nil { n += 1 }
        expect(n == 3, "got \(n)")
    }
    check("session source filter: default hides cron; app/cli kinds normalize") {
        expect(SessionSource.matches("buzz", filter: "chats") && !SessionSource.matches("cron", filter: "chats"))
        expect(SessionSource.matches(nil, filter: "app") && !SessionSource.matches("desktop", filter: "app"))
        expect(SessionSource.canContinue(nil) && SessionSource.canContinue("bot_room") && !SessionSource.canContinue("desktop"))
        expect(SessionSource.matches("local", filter: "cli") && SessionSource.matches("cron", filter: "all"))
        expect(SessionSource.label("cron") == "Scheduled Runs" && SessionSource.label("buzz") == "Buzz")
        expect(SessionSource.label(SessionSource.kind("whatsapp_cloud")) == "WhatsApp" && SessionSource.label("my_platform") == "My platform")
    }
    check("error envelopes") {
        expect(HermesError.from(status: 401, data: Data(#"{"error":{"message":"bad key","code":"x"}}"#.utf8)).message == "bad key")
        expect(HermesError.from(status: 404, data: Data(#"{"error":"Job not found"}"#.utf8)).message == "Job not found")
        expect(HermesError.from(status: 401, data: Data(#"{"detail":"Unauthorized"}"#.utf8)).message == "Unauthorized")
    }

    guard let client = devClient() else { print("(skipping live API checks: no dev/hermes-home/.env)"); return }
    var done = false
    Task {
        await liveChecks(client)
        done = true
    }
    waitPumpingRunLoop { done }
}

func devClient() -> HermesClient? {
    let env = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dev/hermes-home/.env")
    guard let text = try? String(contentsOf: env, encoding: .utf8) else { return nil }
    var kv: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { kv[parts[0]] = parts[1] }
    }
    guard let k = kv["API_SERVER_KEY"], let t = kv["HERMES_DASHBOARD_SESSION_TOKEN"] else { return nil }
    return HermesClient(api: Endpoint(baseURL: URL(string: "http://127.0.0.1:8642")!, token: k, headerName: "Authorization"),
                        dashboard: Endpoint(baseURL: URL(string: "http://127.0.0.1:9119")!, token: t, headerName: "X-Hermes-Session-Token"))
}

func asyncCheck(_ name: String, _ body: () async throws -> Void) async {
    current = name
    do { try await body() } catch { failures.append("\(name): threw \(error.localizedDescription)") }
}

func liveChecks(_ c: HermesClient) async {
    await asyncCheck("live health") { let h = try await c.health(); expect(h.status == "ok") }
    await asyncCheck("live bad key is a clean 401") {
        let bad = HermesClient(api: Endpoint(baseURL: c.api.endpoint.baseURL, token: "nope-nope-nope-nope", headerName: "Authorization"), dashboard: nil)
        do { _ = try await bad.sessions(); expect(false, "no throw") } catch let e as HermesError { expect(e.status == 401, "\(e.status)") }
    }
    await asyncCheck("live session lifecycle") {
        let s = try await c.createSession(title: "checks")
        // Chat admission only accepts api_server/bot_room sessions (regression 2026-11-22: source=desktop -> permission_denied).
        expect(s.source == "api_server", "session source \(s.source ?? "nil") would be refused by chat admission")
        let renamed = try await c.updateSession(s.id, title: "checks renamed", pinned: true)
        expect(renamed.title == "checks renamed" && renamed.pinned == true)
        let list = try await c.sessions()
        expect(list.items.contains { $0.id == s.id })
        _ = try await c.messages(s.id)
        try await c.deleteSession(s.id)
        let after = try await c.sessions()
        expect(!after.items.contains { $0.id == s.id }, "still listed after delete")
    }
    await asyncCheck("live jobs lifecycle") {
        var d = HermesClient.JobDraft(); d.name = "checks job"; d.schedule = "every 2h"; d.prompt = "say hi"
        let j = try await c.createJob(d, paused: true)
        expect(j.isPaused)
        d.name = "checks job 2"; d.schedule = "weekdays at 9am"
        let u = try await c.updateJob(j.id, d, from: HermesClient.JobDraft(j))
        expect(u.name == "checks job 2" && u.schedule?.kind == "cron", "\(String(describing: u.schedule))")
        let r = try await c.resumeJob(j.id); expect(!r.isPaused, "resume")
        let p = try await c.pauseJob(j.id); expect(p.isPaused, "pause")
        _ = try await c.jobRuns(j.id)
        try await c.deleteJob(j.id)
        // One-shot jobs: renaming must not re-send the lossy "once at ..." display as the schedule (hermes-mac-rao).
        var o = HermesClient.JobDraft(); o.name = "checks once"; o.schedule = "30m"; o.prompt = "say hi"
        let oj = try await c.createJob(o, paused: true)
        var o2 = HermesClient.JobDraft(oj); o2.name = "checks once renamed"
        let ou = try await c.updateJob(oj.id, o2, from: HermesClient.JobDraft(oj))
        expect(ou.name == "checks once renamed", "one-shot rename")
        try await c.deleteJob(oj.id)
        let jobsAfter = try await c.jobs(); expect(!jobsAfter.contains { $0.id == j.id })
    }
    await asyncCheck("live skills read/edit roundtrip") {
        let all = try await c.skills()
        expect(all.count > 5, "only \(all.count) skills")
        let name = "hermes-mac-checks"
        let body = "---\nname: \(name)\ndescription: Temporary skill written by hermes-mac checks.\n---\n\n# Checks\n\nv1\n"
        if !all.contains(where: { $0.name == name }) { try await c.createSkill(name, content: body, category: nil) }
        try await c.saveSkill(name, content: body.replacingOccurrences(of: "v1", with: "v2"))
        let back = try await c.skillContent(name)
        expect(back.content.contains("v2"), "edit not persisted")
        try await c.setSkill(name, enabled: false)
        let toggled = try await c.skills(); expect(toggled.first { $0.name == name }?.enabled == false, "toggle")
        try await c.setSkill(name, enabled: true)
    }
    await asyncCheck("live dashboard reads") {
        _ = try await c.search("pong")
        let ts = try await c.toolsets(); expect(!ts.isEmpty)
        let mi = try await c.modelInfo(); expect(mi.model != nil)
        _ = try await c.memory()
        let rc = try await c.rawConfig(); expect(rc.yaml.contains("model"))
        _ = try await c.logs(file: "agent", lines: 5)
        _ = try await c.usage(days: 7)
        _ = try await c.deliveryTargets()
        _ = try await c.dashboardStatus()
        let mo = try await c.modelOptions(); expect(!mo.isEmpty)
    }
    if ProcessInfo.processInfo.environment["HERMES_CHECK_CHAT"] == "1" {
        await asyncCheck("live chat stream") {
            let s = try await c.createSession(title: "checks chat")
            var text = "", done = false, started = false
            for try await e in c.chatStream(session: s.id, message: "Reply with exactly: pong") {
                switch e {
                case .started: started = true
                case .delta(let d): text += d
                case .completed: done = true
                default: break
                }
            }
            expect(started && done && text.lowercased().contains("pong"), "text=\(text)")
            try await c.deleteSession(s.id)
        }
        await liveRunChecks(c) // detached /v1/runs turn (RunChecks.swift)
    }
}
