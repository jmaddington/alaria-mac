import Foundation

/// The whole Hermes HTTP surface a remote client can use, split across its two servers:
///  - `api`  : gateway API server (default :8642, Bearer API_SERVER_KEY) - chat, sessions, jobs, runs, approvals.
///  - `dash` : dashboard / `hermes serve` (default :9119, X-Hermes-Session-Token) - skills content, search,
///             config, toolsets, memory, logs, analytics, model switching. Optional; features gate on it.
// AIDEV-NOTE: route choice per call is deliberate (see docs/agents/api-notes.md). Don't "unify" onto one server:
// skill content exists only on dash, typed chat streaming only on api.
public final class HermesClient: Sendable {
    public let api: HTTPCore
    public let dash: HTTPCore?

    public init(api: Endpoint, dashboard: Endpoint?) {
        self.api = HTTPCore(endpoint: api)
        self.dash = dashboard.map(HTTPCore.init(endpoint:))
    }

    public var hasDashboard: Bool { dash != nil }

    func requireDash() throws -> HTTPCore {
        guard let dash else { throw HermesError(status: 0, message: "Connect the Hermes dashboard in Settings to use this.") }
        return dash
    }

    static func path(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }

    // MARK: Health

    public func health() async throws -> HealthInfo { try await api.get("/health") }
    public func dashboardStatus() async throws -> DashboardStatus { try await requireDash().get("/api/status") }

    // MARK: Sessions

    public func sessions(limit: Int = 100, offset: Int = 0) async throws -> (items: [HermesSession], hasMore: Bool) {
        let r: ListEnvelope<HermesSession> = try await api.get("/api/sessions", query: ["limit": "\(limit)", "offset": "\(offset)"])
        return (r.data, r.hasMore ?? false)
    }

    public func createSession(title: String? = nil, systemPrompt: String? = nil) async throws -> HermesSession {
        let r: SessionEnvelope = try await api.json("POST", "/api/sessions", ["title": title, "system_prompt": systemPrompt, "source": "desktop"])
        return r.session
    }

    public func updateSession(_ id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws -> HermesSession {
        let r: SessionEnvelope = try await api.json("PATCH", "/api/sessions/\(Self.path(id))", ["title": title, "pinned": pinned, "archived": archived])
        return r.session
    }

    public func deleteSession(_ id: String) async throws {
        try await api.send(api.request("DELETE", "/api/sessions/\(Self.path(id))"))
    }

    public func forkSession(_ id: String, title: String? = nil) async throws -> HermesSession {
        let r: SessionEnvelope = try await api.json("POST", "/api/sessions/\(Self.path(id))/fork", ["title": title])
        return r.session
    }

    public func messages(_ id: String, limit: Int = 500) async throws -> [HermesMessage] {
        let r: ListEnvelope<HermesMessage> = try await api.get("/api/sessions/\(Self.path(id))/messages", query: ["limit": "\(limit)", "order": "oldest"])
        return r.data
    }

    public func search(_ q: String, limit: Int = 30) async throws -> [SearchHit] {
        let r: SearchEnvelope = try await requireDash().get("/api/sessions/search", query: ["q": q, "limit": "\(limit)"])
        return r.results
    }

    // MARK: Chat

    /// Streams one turn. Events (verified): run.started, message.started, assistant.delta, tool.progress
    /// (reasoning preview), tool.started/completed/failed, assistant.commentary, approval.request,
    /// assistant.completed, run.completed|failed|cancelled, error, done.
    public func chatStream(session: String, message: String) -> AsyncThrowingStream<ChatEvent, Error> {
        let body = try? JSONSerialization.data(withJSONObject: ["message": message])
        let frames = api.stream(api.request("POST", "/api/sessions/\(Self.path(session))/chat/stream", body: body))
        return AsyncThrowingStream { cont in
            let task = Task {
                var runId = ""
                var toolSeq = 0
                var running: [String: [String]] = [:] // tool name -> ids still running (no call id in this stream)
                do {
                    for try await f in frames {
                        let o = f.object ?? [:]
                        switch f.event {
                        case "run.started":
                            runId = o["run_id"] as? String ?? ""
                            cont.yield(.started(runId: runId, messageId: nil))
                        case "message.started":
                            let m = o["message"] as? [String: Any]
                            cont.yield(.started(runId: runId, messageId: m?["id"] as? String))
                        case "assistant.delta":
                            if let d = o["delta"] as? String { cont.yield(.delta(d)) }
                        case "tool.progress":
                            if (o["tool_name"] as? String) == "_thinking", let d = o["delta"] as? String { cont.yield(.thinking(d)) }
                        case "assistant.commentary":
                            if let t = o["text"] as? String, (o["already_streamed"] as? Bool) != true { cont.yield(.commentary(t)) }
                        case "tool.started":
                            let name = o["tool_name"] as? String ?? "tool"
                            if name.hasPrefix("_") { break }
                            toolSeq += 1
                            let id = "\(runId)-\(toolSeq)"
                            running[name, default: []].append(id)
                            cont.yield(.toolStarted(ToolActivity(id: id, name: name, preview: o["preview"] as? String, state: .running)))
                        case "tool.completed", "tool.failed":
                            let name = o["tool_name"] as? String ?? "tool"
                            if var ids = running[name], !ids.isEmpty {
                                let id = ids.removeFirst(); running[name] = ids
                                cont.yield(.toolFinished(id: id, failed: f.event == "tool.failed"))
                            }
                        case "approval.request":
                            let choices = (o["choices"] as? [String]) ?? ["once", "session", "always", "deny"]
                            cont.yield(.approval(ApprovalRequest(runId: o["run_id"] as? String ?? runId,
                                                                 requestId: o["request_id"] as? String,
                                                                 command: o["command"] as? String,
                                                                 description: o["description"] as? String,
                                                                 choices: choices)))
                        case "assistant.completed":
                            cont.yield(.completed(content: o["content"] as? String ?? ""))
                        case "run.failed":
                            cont.yield(.failed((o["error"] as? String) ?? ((o["error"] as? [String: Any])?["message"] as? String) ?? "The run failed"))
                        case "run.cancelled":
                            cont.yield(.cancelled)
                        case "error":
                            cont.yield(.failed(o["message"] as? String ?? "Stream error"))
                        case "hermes.status":
                            if let t = o["text"] as? String { cont.yield(.status(t)) }
                        default: break
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func stopRun(_ runId: String) async throws {
        try await api.send(api.request("POST", "/v1/runs/\(Self.path(runId))/stop", body: Data("{}".utf8)))
    }

    public func steer(_ runId: String, text: String) async throws {
        let _: JSONValue = try await api.json("POST", "/v1/runs/\(Self.path(runId))/steer", ["input": text])
    }

    public func answerApproval(_ a: ApprovalRequest, choice: String) async throws {
        let _: JSONValue = try await api.json("POST", "/v1/runs/\(Self.path(a.runId))/approval", ["choice": choice, "request_id": a.requestId])
    }

    // MARK: Skills (dashboard)

    public func skills() async throws -> [Skill] { try await requireDash().get("/api/skills") }

    public func skillContent(_ name: String) async throws -> SkillContent {
        try await requireDash().get("/api/skills/content", query: ["name": name])
    }

    public func saveSkill(_ name: String, content: String) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/skills/content", ["name": name, "content": content])
    }

    public func createSkill(_ name: String, content: String, category: String?) async throws {
        let _: JSONValue = try await requireDash().json("POST", "/api/skills", ["name": name, "content": content, "category": category])
    }

    public func setSkill(_ name: String, enabled: Bool) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/skills/toggle", ["name": name, "enabled": enabled])
    }

    public func setSkill(_ name: String, locked: Bool) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/skills/lock", ["name": name, "locked": locked])
    }

    /// Hub uninstall is the only removal path Hermes exposes.
    public func uninstallSkill(_ name: String) async throws {
        let _: JSONValue = try await requireDash().json("POST", "/api/skills/hub/uninstall", ["name": name])
    }

    // MARK: Cron jobs (API server; run history + targets from dashboard)

    public func jobs() async throws -> [CronJob] {
        let r: JobsEnvelope = try await api.get("/api/jobs", query: ["include_disabled": "true"])
        return r.jobs
    }

    public struct JobDraft: Sendable, Equatable {
        public var name = "", schedule = "", prompt = "", deliver = "local", skills: [String] = []
        public var repeatTimes: Int? = nil
        public var timezone: String? = nil
        public init() {}
        public init(_ j: CronJob) {
            name = j.name ?? ""; schedule = j.schedule?.display ?? j.scheduleText; prompt = j.prompt ?? ""
            deliver = j.deliver ?? "local"; skills = j.skills ?? []; repeatTimes = j.repeat?.times; timezone = j.timezone
        }
        var body: [String: Any?] {
            ["name": name, "schedule": schedule, "prompt": prompt, "deliver": deliver, "skills": skills,
             "repeat": repeatTimes, "timezone": (timezone?.isEmpty ?? true) ? nil : timezone]
        }
    }

    public func createJob(_ d: JobDraft, paused: Bool = false) async throws -> CronJob {
        var b = d.body; b["paused"] = paused
        let r: JobEnvelope = try await api.json("POST", "/api/jobs", b)
        return r.job
    }

    public func updateJob(_ id: String, _ d: JobDraft) async throws -> CronJob {
        let r: JobEnvelope = try await api.json("PATCH", "/api/jobs/\(Self.path(id))", d.body)
        return r.job
    }

    public func deleteJob(_ id: String) async throws {
        try await api.send(api.request("DELETE", "/api/jobs/\(Self.path(id))"))
    }

    public func pauseJob(_ id: String) async throws -> CronJob {
        let r: JobEnvelope = try await api.json("POST", "/api/jobs/\(Self.path(id))/pause"); return r.job
    }
    public func resumeJob(_ id: String) async throws -> CronJob {
        let r: JobEnvelope = try await api.json("POST", "/api/jobs/\(Self.path(id))/resume"); return r.job
    }
    public func runJobNow(_ id: String) async throws -> CronJob {
        let r: JobEnvelope = try await api.json("POST", "/api/jobs/\(Self.path(id))/run"); return r.job
    }

    public func jobRuns(_ id: String, limit: Int = 20) async throws -> [CronRun] {
        let r: RunsEnvelope = try await requireDash().get("/api/cron/jobs/\(Self.path(id))/runs", query: ["limit": "\(limit)"])
        return r.runs
    }

    public func deliveryTargets() async throws -> [DeliveryTarget] {
        let r: TargetsEnvelope = try await requireDash().get("/api/cron/delivery-targets")
        return r.targets
    }

    // MARK: Tools, model, memory, config, logs, analytics (dashboard)

    public func toolsets() async throws -> [Toolset] { try await requireDash().get("/api/tools/toolsets") }
    public func setToolset(_ name: String, enabled: Bool) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/tools/toolsets/\(Self.path(name))", ["enabled": enabled])
    }

    public func modelInfo() async throws -> ModelInfo { try await requireDash().get("/api/model/info") }
    public func modelOptions() async throws -> [ProviderOption] {
        let r: ProvidersEnvelope = try await api.get("/api/model/options"); return r.providers
    }
    public func setModel(provider: String, model: String) async throws {
        let _: JSONValue = try await requireDash().json("POST", "/api/model/set", ["scope": "main", "provider": provider, "model": model])
    }

    public func memory() async throws -> MemoryState { try await requireDash().get("/api/memory") }
    public func setMemoryProvider(_ name: String) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/memory/provider", ["provider": name])
    }
    public func resetMemory(_ target: String) async throws {
        let _: JSONValue = try await requireDash().json("POST", "/api/memory/reset", ["target": target])
    }

    public func rawConfig() async throws -> (yaml: String, path: String?) {
        let r: RawConfig = try await requireDash().get("/api/config/raw"); return (r.yaml, r.path)
    }
    /// NOTE: GET returns `yaml`, PUT takes `yaml_text` (RawConfigUpdate in hermes_cli/web_models.py).
    public func saveRawConfig(_ yaml: String) async throws {
        let _: JSONValue = try await requireDash().json("PUT", "/api/config/raw", ["yaml_text": yaml])
    }

    public func logs(file: String, lines: Int = 300, search: String? = nil) async throws -> [String] {
        let r: LogLines = try await requireDash().get("/api/logs", query: ["file": file, "lines": "\(lines)", "search": search])
        return r.lines
    }

    public func usage(days: Int) async throws -> UsageReport {
        try await requireDash().get("/api/analytics/usage", query: ["days": "\(days)"])
    }
}
