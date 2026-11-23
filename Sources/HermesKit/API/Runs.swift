import Foundation

// AIDEV-NOTE: detached turns (bead hermes-mac-wny; wire contract in docs/agents/api-notes.md "Runs"). The session
// chat stream (/api/sessions/{id}/chat/stream) interrupts the agent when its client disconnects; a /v1/runs run
// keeps going and its events can be re-attached with replay (`last_seq`). Event names differ from the session
// stream: message.delta (not assistant.delta), message.interim, reasoning.available, tool.* carry `tool` +
// `tool_call_id`, approval.request carries `prompt_id` (the request id to answer with), and the final text is
// run.completed.output. Frames have NO `event:` line: the name is the payload's "event" field, the seq is `id:`.

/// `POST /v1/runs` accepted a turn (202). `status` is "started" even when the server queued it behind a busy
/// session; `HermesClient.runStatus` reports "queued" until it actually starts.
public struct RunHandle: Sendable, Hashable {
    public var runId: String
    public var status: String
    public init(runId: String, status: String) { self.runId = runId; self.status = status }
}

/// `GET /v1/runs/{id}`: the pollable state of a run.
public struct RunStatus: Sendable, Hashable {
    /// Statuses after which nothing more happens. `interrupted` = the gateway shut down or restarted mid-run.
    public static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "interrupted"]

    public var runId: String
    /// queued | started | running | waiting_for_approval | stopping | completed | failed | cancelled | interrupted
    public var status: String
    public var sessionId: String?
    /// The final reply text (completed runs).
    public var output: String?
    public var error: String?
    /// Server clock (Unix seconds); comparable with stored message timestamps.
    public var createdAt: Double?
    /// Approvals the run is blocked on right now (`pending_controls`).
    public var pendingApprovals: [ApprovalRequest] = []

    public var isTerminal: Bool { Self.terminalStatuses.contains(status) }
    public var isQueued: Bool { status == "queued" }

    public init(runId: String, status: String, sessionId: String? = nil, output: String? = nil, error: String? = nil,
                createdAt: Double? = nil, pendingApprovals: [ApprovalRequest] = []) {
        self.runId = runId; self.status = status; self.sessionId = sessionId; self.output = output
        self.error = error; self.createdAt = createdAt; self.pendingApprovals = pendingApprovals
    }

    public init?(json o: [String: Any]) {
        guard let id = o["run_id"] as? String, let status = o["status"] as? String else { return nil }
        let controls = (o["pending_controls"] as? [[String: Any]]) ?? []
        self.init(runId: id, status: status, sessionId: o["session_id"] as? String,
                  output: (o["output"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  error: RunEventMapper.errorText(o["error"]),
                  createdAt: (o["created_at"] as? NSNumber)?.doubleValue,
                  pendingApprovals: controls.filter { ($0["kind"] as? String ?? "approval") == "approval" }
                      .map { RunEventMapper.approval($0, runId: id) })
    }
}

/// One `/v1/runs/{id}/events` frame, typed. `events` is what it means in `ChatEvent` terms (may be empty for
/// bookkeeping frames such as run.steered or replay.truncated; run.completed yields runtime + completed).
public struct RunEvent: Sendable {
    /// The server's per-run sequence number (SSE `id:`); pass the last one seen as `after:` to resume.
    public var seq: Int?
    /// The payload's "event" field, e.g. "message.delta", "approval.settled".
    public var name: String
    public var events: [ChatEvent]
    /// run.completed / failed / cancelled / interrupted: the run is over and the stream is about to close.
    public var isTerminal: Bool
    /// approval.settled: this prompt (ApprovalRequest.requestId) no longer waits - answered here, by another
    /// client, or timed out.
    public var settledApproval: String?
    public init(seq: Int?, name: String, events: [ChatEvent], isTerminal: Bool = false, settledApproval: String? = nil) {
        self.seq = seq; self.name = name; self.events = events; self.isTerminal = isTerminal; self.settledApproval = settledApproval
    }
}

/// Maps run event frames to `RunEvent`s. Stateful only for tool ids: tool.completed is matched to its
/// tool.started by `tool_call_id`, or by tool name when the server sent no call id.
public struct RunEventMapper: Sendable {
    public let runId: String
    private var toolSeq = 0
    private var running: [String: [String]] = [:] // tool name -> ids still running (call-id-less fallback)
    public init(runId: String) { self.runId = runId }

    public mutating func map(_ f: SSEFrame) -> RunEvent? {
        guard let o = f.object else { return nil }
        let name = o["event"] as? String ?? f.event
        let seq = f.id.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? (o["seq"] as? NSNumber)?.intValue
        var out: [ChatEvent] = []
        var terminal = false, settled: String?
        switch name {
        case "message.delta":
            if let d = o["delta"] as? String { out.append(.delta(d)) }
        case "message.interim":
            if let t = o["text"] as? String, (o["already_streamed"] as? Bool) != true { out.append(.commentary(t)) }
        case "reasoning.available":
            if let t = o["text"] as? String, !t.isEmpty { out.append(.thinking(t)) }
        case "tool.started":
            let tool = o["tool"] as? String ?? o["tool_name"] as? String ?? "tool"
            if tool.hasPrefix("_") { break }
            toolSeq += 1
            let id = (o["tool_call_id"] as? String) ?? "\(runId)-t\(toolSeq)"
            running[tool, default: []].append(id)
            out.append(.toolStarted(ToolActivity(id: id, name: tool, preview: (o["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 }, state: .running)))
        case "tool.completed", "tool.failed":
            let tool = o["tool"] as? String ?? o["tool_name"] as? String ?? "tool"
            let failed = name == "tool.failed" || (o["error"] as? Bool) == true
            var id = o["tool_call_id"] as? String
            if let i = id { running[tool]?.removeAll { $0 == i } }
            else if var ids = running[tool], !ids.isEmpty { id = ids.removeFirst(); running[tool] = ids }
            if let id { out.append(.toolFinished(id: id, failed: failed)) }
        case "approval.request":
            out.append(.approval(Self.approval(o, runId: runId)))
        case "approval.settled":
            settled = (o["prompt_id"] as? String) ?? (o["request_id"] as? String)
        case "run.completed":
            if let rt = SessionRuntime(o["runtime"]) { out.append(.runtime(rt)) }
            out.append(.completed(content: o["output"] as? String ?? ""))
            terminal = true
        case "run.failed":
            out.append(.failed(Self.errorText(o["error"]) ?? "The run failed"))
            terminal = true
        case "run.cancelled":
            out.append(.cancelled)
            terminal = true
        case "run.interrupted":
            out.append(.failed(Self.errorText(o["error"]) ?? "The gateway stopped before this reply finished"))
            terminal = true
        default:
            break // run.queued, run.steered, run.stopping, replay.truncated, subagent.*: bookkeeping
        }
        return RunEvent(seq: seq, name: name, events: out, isTerminal: terminal, settledApproval: settled)
    }

    static func approval(_ o: [String: Any], runId: String) -> ApprovalRequest {
        ApprovalRequest(runId: o["run_id"] as? String ?? runId,
                        requestId: (o["request_id"] as? String) ?? (o["prompt_id"] as? String),
                        command: o["command"] as? String,
                        description: o["description"] as? String,
                        choices: (o["choices"] as? [String]) ?? ["once", "session", "always", "deny"],
                        executionGeneration: (o["execution_generation"] as? NSNumber)?.intValue)
    }

    static func errorText(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let d = v as? [String: Any] { return d["message"] as? String }
        return nil
    }
}

extension HermesClient {
    /// Starts a detached turn in `session` (`POST /v1/runs`). The run keeps going when no one is watching; follow
    /// it with `runEvents`. A session that is busy queues it server-side (runs after the current turn).
    /// `idempotencyKey` makes the POST safe to retry after a network drop (retried here twice on URLError).
    public func startRun(session: String, parts: [ContentPart], idempotencyKey: String? = UUID().uuidString) async throws -> RunHandle {
        let input: Any
        if parts.allSatisfy({ if case .text = $0 { return true }; return false }) {
            input = ChatContent.messageValue(parts) // plain string
        } else {
            // /v1/runs reads the LAST message's content; a part list goes through like the chat stream's.
            input = [["role": "user", "content": parts.map(\.json)]]
        }
        let body = try JSONSerialization.data(withJSONObject: ["session_id": session, "input": input])
        var r = api.request("POST", "/v1/runs", body: body)
        if let idempotencyKey { r.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        var attempt = 0
        while true {
            do {
                let (d, _) = try await api.send(r)
                let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                guard let id = o["run_id"] as? String else { throw HermesError(status: 0, message: "Unexpected response from /v1/runs") }
                return RunHandle(runId: id, status: o["status"] as? String ?? "started")
            } catch let e as URLError where idempotencyKey != nil && attempt < 2 && e.code != .cancelled {
                attempt += 1
                apiLog.info("POST /v1/runs retry \(attempt) after \(e.code.rawValue) [API-RUN-RETRY]")
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    public func runStatus(_ runId: String) async throws -> RunStatus {
        let (d, _) = try await api.send(api.request("GET", "/v1/runs/\(Self.path(runId))"))
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = RunStatus(json: o) else {
            throw HermesError(status: 0, message: "Unexpected response from /v1/runs/\(runId)")
        }
        return s
    }

    /// Follows a run's events. `after` = the last seq already applied (replays everything newer the server still
    /// holds: up to 1000 events, ~5 min after the run started if nobody was attached). The stream finishes after
    /// the terminal event, or early if the server drops a slow subscriber - check `runStatus` and resume then.
    /// A 404 HermesError = unknown run or its event buffer was swept; `runStatus` may still answer.
    public func runEvents(_ runId: String, after seq: Int? = nil) -> AsyncThrowingStream<RunEvent, Error> {
        let frames = api.stream(api.request("GET", "/v1/runs/\(Self.path(runId))/events", query: ["last_seq": seq.map(String.init)]))
        return AsyncThrowingStream { cont in
            let task = Task {
                var mapper = RunEventMapper(runId: runId)
                do {
                    for try await f in frames {
                        guard let e = mapper.map(f) else { continue }
                        cont.yield(e)
                        if e.isTerminal { break }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
