import Foundation
import HermesKit

/// Detached turns over /v1/runs (bead hermes-mac-wny): SSE ids, event mapping (frames captured from the dev
/// server 2026-11-22), resume/replay bookkeeping, the persisted run registry, history cut, busy-input decisions.
/// HERMES_CHECK_CHAT=1 adds a live run: detach mid-run, re-attach with replay, status.
func runRunChecks() {
    func frames(_ wire: String) -> [SSEFrame] {
        var lines = SSELineSplitter(), p = SSEParser(), out: [SSEFrame] = []
        for b in Array(wire.utf8) { if let l = lines.push(b), let f = p.feed(l) { out.append(f) } }
        if let l = lines.finish(), let f = p.feed(l) { out.append(f) }
        if let f = p.feed("") { out.append(f) }
        return out
    }
    let rid = "run_b3c0"

    check("sse: id lines become frame ids; frames without event: are 'message'") {
        let fs = frames(": open\n\nid: 0\ndata: {\"event\": \"message.delta\", \"delta\": \"po\", \"seq\": 0}\n\nid: 1\ndata: {\"event\": \"message.delta\", \"delta\": \"ng\", \"seq\": 1}\n\n: stream closed\n\n")
        expect(fs.map(\.id) == ["0", "1"], "\(fs.map(\.id))")
        expect(fs.allSatisfy { $0.event == "message" })
    }
    check("sse: id survives a following event: line; a lost separator still splits frames") {
        let a = frames("id: 7\nevent: x\ndata: {}\n\n")
        expect(a.count == 1 && a[0].id == "7" && a[0].event == "x", "\(a.map(\.id)) \(a.map(\.event))")
        var p = SSEParser(), out: [SSEFrame] = []
        for l in ["id: 1", #"data: {"a":1}"#, "id: 2", #"data: {"a":2}"#] { if let f = p.feed(l) { out.append(f) } }
        if let f = p.feed("") { out.append(f) }
        expect(out.map(\.id) == ["1", "2"], "\(out.map(\.id))")
        expect(frames("data: {}\n\n").first?.id == nil) // chat/stream frames keep no id
    }
    check("run events: deltas, tools by call id, terminal output") {
        var m = RunEventMapper(runId: rid)
        let wire = """
        id: 0
        data: {"event": "tool.started", "run_id": "run_b3c0", "tool": "terminal", "preview": "sleep 8 + 1 command", "tool_call_id": "toolu_1", "seq": 0}

        id: 1
        data: {"event": "run.steered", "run_id": "run_b3c0", "accepted": true, "seq": 1}

        id: 2
        data: {"event": "tool.completed", "run_id": "run_b3c0", "tool": "terminal", "duration": 0, "error": true, "tool_call_id": "toolu_1", "preview": "", "seq": 2}

        id: 3
        data: {"event": "message.delta", "run_id": "run_b3c0", "delta": "done", "seq": 3}

        id: 4
        data: {"event": "run.completed", "run_id": "run_b3c0", "output": "done", "usage": {"input_tokens": 1}, "runtime": {"provider": "", "model": "", "route_source": "global"}, "completed": true, "seq": 4}


        """
        let evs = frames(wire).compactMap { m.map($0) }
        expect(evs.map(\.seq) == [0, 1, 2, 3, 4], "\(evs.map(\.seq))")
        expect(evs.map(\.name) == ["tool.started", "run.steered", "tool.completed", "message.delta", "run.completed"])
        if case .toolStarted(let t)? = evs[0].events.first { expect(t.id == "toolu_1" && t.name == "terminal" && t.state == .running) } else { expect(false, "tool.started") }
        expect(evs[1].events.isEmpty && !evs[1].isTerminal)
        if case .toolFinished(let id, let failed)? = evs[2].events.first { expect(id == "toolu_1" && failed) } else { expect(false, "tool.completed") }
        if case .delta(let d)? = evs[3].events.first { expect(d == "done") } else { expect(false, "delta") }
        // Empty runtime (session-authority runs report provider/model "") yields no .runtime, just the output.
        expect(evs[4].isTerminal && evs[4].events.count == 1, "\(evs[4].events)")
        if case .completed(let c)? = evs[4].events.last { expect(c == "done") } else { expect(false, "completed") }
    }
    check("run events: approval.request answers with prompt_id; approval.settled; failures; cancel") {
        var m = RunEventMapper(runId: rid)
        let a = m.map(SSEFrame(event: "message", data: Data(#"{"event": "approval.request", "run_id": "run_b3c0", "kind": "approval", "prompt_id": "p9", "execution_generation": 1, "command": "rm -rf /tmp/x", "description": "delete in root path", "choices": ["once", "deny", "session", "always"], "seq": 1}"#.utf8), id: "1"))
        if case .approval(let r)? = a?.events.first {
            expect(r.requestId == "p9" && r.executionGeneration == 1 && r.runId == rid && r.choices.contains("deny") && r.command == "rm -rf /tmp/x")
        } else { expect(false, "approval") }
        let s = m.map(SSEFrame(event: "message", data: Data(#"{"event": "approval.settled", "prompt_id": "p9", "execution_generation": 1, "seq": 2}"#.utf8)))
        expect(s?.settledApproval == "p9" && s?.events.isEmpty == true && s?.seq == 2)
        let f = m.map(SSEFrame(event: "message", data: Data(#"{"event": "run.failed", "error": {"message": "boom"}}"#.utf8)))
        if case .failed(let msg)? = f?.events.first { expect(msg == "boom" && f?.isTerminal == true) } else { expect(false, "failed") }
        let c = m.map(SSEFrame(event: "message", data: Data(#"{"event": "run.cancelled", "interrupted": true, "turn_exit_reason": "interrupted_by_user"}"#.utf8)))
        if case .cancelled? = c?.events.first { expect(c?.isTerminal == true) } else { expect(false, "cancelled") }
        let i = m.map(SSEFrame(event: "message", data: Data(#"{"event": "message.interim", "text": "Looking...", "already_streamed": false}"#.utf8)))
        if case .commentary(let t)? = i?.events.first { expect(t == "Looking...") } else { expect(false, "interim") }
        let r = m.map(SSEFrame(event: "message", data: Data(#"{"event": "reasoning.available", "text": "hmm"}"#.utf8)))
        if case .thinking(let t)? = r?.events.first { expect(t == "hmm") } else { expect(false, "reasoning") }
    }
    check("run events: tools without call ids pair by name; hidden _tools skipped") {
        var m = RunEventMapper(runId: rid)
        let a = m.map(SSEFrame(event: "message", data: Data(#"{"event":"tool.started","tool":"web"}"#.utf8)))
        let b = m.map(SSEFrame(event: "message", data: Data(#"{"event":"tool.completed","tool":"web","error":false}"#.utf8)))
        let h = m.map(SSEFrame(event: "message", data: Data(#"{"event":"tool.started","tool":"_thinking"}"#.utf8)))
        if case .toolStarted(let t)? = a?.events.first, case .toolFinished(let id, let failed)? = b?.events.first {
            expect(t.id == id && !failed)
        } else { expect(false, "pairing") }
        expect(h?.events.isEmpty == true)
    }
    check("run status: terminal set, queued, pending approvals, error shapes") {
        let s = RunStatus(json: ["run_id": "r", "status": "waiting_for_approval", "session_id": "s", "created_at": 1795405347.66,
                                 "output": "", "pending_controls": [["kind": "approval", "prompt_id": "p1", "execution_generation": 2, "command": "rm x", "choices": ["once", "deny"]]]])
        expect(s?.isTerminal == false && s?.output == nil && s?.createdAt == 1795405347.66 && s?.sessionId == "s")
        expect(s?.pendingApprovals.first?.requestId == "p1" && s?.pendingApprovals.first?.executionGeneration == 2)
        expect(RunStatus(json: ["run_id": "r", "status": "queued"])?.isQueued == true)
        for t in ["completed", "failed", "cancelled", "interrupted"] { expect(RunStatus(json: ["run_id": "r", "status": t])?.isTerminal == true, t) }
        expect(RunStatus(json: ["run_id": "r", "status": "failed", "error": "x"])?.error == "x")
        expect(RunStatus(json: ["status": "running"]) == nil)
    }
    check("run registry: persists, upserts, removes, prunes, survives junk") {
        var r = RunRegistry()
        r.upsert(PersistedRun(runId: "a", session: "s1", text: "hi"))
        r.upsert(PersistedRun(runId: "b", session: "s1", createdAt: 5, text: "next", queued: true))
        r.upsert(PersistedRun(runId: "a", session: "s1", createdAt: 3, text: "hi"))
        let back = RunRegistry(data: r.data)
        expect(back == r && back.runs.count == 2 && back.runs[0].createdAt == 3 && back.runs(in: "s1").map(\.runId) == ["a", "b"])
        var old = back
        old.upsert(PersistedRun(runId: "z", session: "s2", text: "", savedAt: Date(timeIntervalSinceNow: -RunRegistry.maxAge - 60)))
        old.prune()
        expect(old.runs.map(\.runId) == ["a", "b"])
        old.remove("a")
        expect(old.runs.map(\.runId) == ["b"])
        expect(RunRegistry(data: Data("nope".utf8)).runs.isEmpty && RunRegistry(data: nil).runs.isEmpty)
        var cap = RunRegistry()
        for i in 0..<(RunRegistry.maxRuns + 5) { cap.upsert(PersistedRun(runId: "\(i)", session: "s", text: "")) }
        expect(cap.runs.count == RunRegistry.maxRuns && cap.runs.first?.runId == "5")
    }
    check("run history: live run's partial rows are cut, earlier turns and queued runs kept") {
        // Rows as Hermes stores them mid-run (verified): previous turn, then the live run's user row + a tool step.
        let rows: [(role: String, timestamp: Double?)] = [("user", 10), ("assistant", 11), ("session_meta", nil),
                                                           ("user", 20), ("assistant", 21), ("tool", 22)]
        expect(RunHistory.cut(rows: rows, liveRunsCreatedAt: [19.5]) == 3)
        expect(RunHistory.cut(rows: rows, liveRunsCreatedAt: []) == rows.count)
        // A queued run (created while the first ran) has no row yet: it cuts nothing beyond the running one.
        expect(RunHistory.cut(rows: rows, liveRunsCreatedAt: [19.5, 20.5]) == 3)
        expect(RunHistory.cut(rows: rows, liveRunsCreatedAt: [30]) == rows.count)
        // The previous turn's late assistant rows (after a queued run's creation) are never cut by it.
        let q: [(role: String, timestamp: Double?)] = [("user", 1), ("assistant", 6), ("user", 7), ("assistant", 8)]
        expect(RunHistory.cut(rows: q, liveRunsCreatedAt: [2]) == 2)
    }
    check("busy input: queue default, steer falls back to queue, interrupt needs a run") {
        expect(BusyInput.action(mode: .queue, busy: false, runId: "r", hasAttachments: false, text: "x") == .send)
        expect(BusyInput.action(mode: .queue, busy: true, runId: "r", hasAttachments: false, text: "x") == .queue)
        expect(BusyInput.action(mode: .steer, busy: true, runId: "r", hasAttachments: false, text: "x") == .steer(runId: "r"))
        expect(BusyInput.action(mode: .steer, busy: true, runId: "r", hasAttachments: true, text: "x") == .queue)
        expect(BusyInput.action(mode: .steer, busy: true, runId: nil, hasAttachments: false, text: "x") == .queue)
        expect(BusyInput.action(mode: .steer, busy: true, runId: "r", hasAttachments: true, text: " ") == .queue)
        expect(BusyInput.action(mode: .interrupt, busy: true, runId: "r", hasAttachments: true, text: "") == .interrupt(runId: "r"))
        expect(BusyInput.action(mode: .interrupt, busy: true, runId: nil, hasAttachments: false, text: "x") == .queue)
        expect(BusyInputMode(rawValue: "queue") == .queue && BusyInputMode.allCases.count == 3)
    }
}

/// Live: one short run, detached after its first event, re-attached from that seq; status reports the output.
func liveRunChecks(_ c: HermesClient) async {
    await asyncCheck("live run: detach, re-attach with replay, status") {
        let s = try await c.createSession(title: "agent test: checks run")
        let h = try await c.startRun(session: s.id, parts: [.text("Reply with exactly: pong")])
        var first: RunEvent?
        for try await e in c.runEvents(h.runId) { first = e; break } // detach: the run must keep going
        expect(first?.seq == 0, "first seq \(String(describing: first?.seq))")
        var text = "", terminal = false, seqs: [Int] = []
        if case .delta(let d)? = first?.events.first { text = d }
        for try await e in c.runEvents(h.runId, after: first?.seq) {
            if let q = e.seq { seqs.append(q) }
            for x in e.events { if case .delta(let d) = x { text += d } }
            if e.isTerminal { terminal = true }
        }
        expect(terminal && seqs.first.map { $0 > (first?.seq ?? -1) } != false, "seqs \(seqs)")
        let st = try await c.runStatus(h.runId)
        expect(st.status == "completed" && (st.output ?? "").lowercased().contains("pong") && st.sessionId == s.id, "\(st)")
        expect(text.lowercased().contains("pong"), "text=\(text)")
        do { _ = try await c.runStatus("run_nonexistent_check"); expect(false, "unknown run should 404") }
        catch let e as HermesError { expect(e.status == 404) }
        try await c.deleteSession(s.id)
    }
}
