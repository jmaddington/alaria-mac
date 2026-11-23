import Foundation

// AIDEV-NOTE: shapes verified against hermes-agent main @52b5271 with curl (see docs/agents/api-notes.md).
// Decoder uses convertFromSnakeCase, so `started_at` -> startedAt. Keep everything optional unless Hermes
// guarantees it: fields come and go between versions and a single strict field fails the whole list.

public struct HermesSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: String?
    public var model: String?
    public var title: String?
    public var startedAt: Double?
    public var endedAt: Double?
    public var endReason: String?
    public var messageCount: Int?
    public var toolCallCount: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var estimatedCostUsd: Double?
    public var parentSessionId: String?
    public var lastActive: Double?
    public var preview: String?
    public var pinned: Bool?
    public var archived: Bool?
    public var hidden: Bool?

    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        // A scheduled run has no title until it finishes; its preview is Hermes' cron preamble, not user words.
        if source == "cron" { return "Scheduled run" }
        if let p = preview, !p.isEmpty { return String(p.prefix(60)) }
        return "New Chat"
    }
    public var activityDate: Date { Date(timeIntervalSince1970: lastActive ?? startedAt ?? 0) }
}

struct SessionEnvelope: Decodable { let session: HermesSession }
struct ListEnvelope<T: Decodable>: Decodable { let data: [T]; let hasMore: Bool? }

public struct HermesMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var role: String
    public var content: String?
    public var toolCallId: String?
    public var toolCalls: JSONValue?
    public var toolName: String?
    public var timestamp: Double?
    public var finishReason: String?
    public var reasoning: String?
    public var reasoningContent: String?
    public var displayKind: String?
    /// Set when the server returned `content` as a part list (text + image_url) instead of a string; `content` then
    /// holds the joined text. Hermes main stores user rows as text, so this is forward compatibility.
    public var contentParts: [ContentPart]?

    public var thinking: String? { [reasoning, reasoningContent].compactMap { $0 }.first { !$0.isEmpty } }

    enum CodingKeys: String, CodingKey {
        case id, role, content, toolCallId, toolCalls, toolName, timestamp, finishReason, reasoning, reasoningContent, displayKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        // AIDEV-NOTE: content may be a string or an OpenAI-style part list; a list must not fail the whole history.
        switch try c.decodeIfPresent(JSONValue.self, forKey: .content) {
        case .string(let s)?: content = s
        case let v? where ChatContent.parts(from: v) != nil:
            let parts = ChatContent.parts(from: v) ?? []
            contentParts = parts
            content = ChatContent.split(parts).text
        case let v?: content = v == .null ? nil : v.description
        case nil: content = nil
        }
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolCalls = try c.decodeIfPresent(JSONValue.self, forKey: .toolCalls)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
        displayKind = try c.decodeIfPresent(String.self, forKey: .displayKind)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(finishReason, forKey: .finishReason)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try c.encodeIfPresent(displayKind, forKey: .displayKind)
    }
}

public struct SearchHit: Codable, Identifiable, Hashable, Sendable {
    public var sessionId: String
    public var snippet: String?
    public var role: String?
    public var title: String?
    public var source: String?
    public var model: String?
    public var lastActive: Double?
    public var messageCount: Int?
    public var id: String { sessionId + (snippet ?? "") }
}
struct SearchEnvelope: Decodable { let results: [SearchHit] }

// MARK: Skills (dashboard API; /v1/skills is broken upstream, see bead hermes-mac-6eg)

public struct Skill: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var category: String?
    public var locked: Bool?
    public var enabled: Bool?
    public var usage: Int?
    public var provenance: String?
    public var id: String { name }
}

public struct SkillContent: Codable, Hashable, Sendable {
    public var name: String
    public var content: String
    public var path: String?
}

// MARK: Cron jobs

public struct CronSchedule: Codable, Hashable, Sendable {
    public var kind: String?
    public var expr: String?
    public var minutes: Double?
    public var runAt: String?
    public var display: String?
}

public struct CronRepeat: Codable, Hashable, Sendable {
    public var times: Int?
    public var completed: Int?
}

public struct CronJob: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var prompt: String?
    public var skills: [String]?
    public var model: String?
    public var provider: String?
    public var schedule: CronSchedule?
    public var scheduleDisplay: String?
    public var `repeat`: CronRepeat?
    public var enabled: Bool?
    public var state: String?
    public var pausedReason: String?
    public var createdAt: String?
    public var nextRunAt: String?
    public var lastRunAt: String?
    public var lastStatus: String?
    public var lastError: String?
    public var lastDeliveryError: String?
    public var failureStreak: Int?
    public var deliver: String?
    public var timezone: String?
    public var workdir: String?

    public var isPaused: Bool { state == "paused" || enabled == false }
    public var scheduleText: String { scheduleDisplay ?? schedule?.display ?? schedule?.expr ?? "—" }
}
struct JobsEnvelope: Decodable { let jobs: [CronJob] }
struct JobEnvelope: Decodable { let job: CronJob }

public struct CronRun: Codable, Identifiable, Hashable, Sendable {
    public var id: String?
    public var runId: String?
    public var status: String?
    public var startedAt: JSONValue?
    public var finishedAt: JSONValue?
    public var error: String?
    public var output: String?
    public var sessionId: String?
    /// The dashboard's runs endpoint returns SESSION rows (id = session id, started_at, ended_at, end_reason such as
    /// "cron_complete"), not status/output; these carry that shape (reported by the iOS port 2026-11-22).
    public var endedAt: JSONValue?
    public var endReason: String?
    public var stableID: String { id ?? runId ?? UUID().uuidString }
    /// Session to open for this run.
    public var conversationID: String? { sessionId ?? id }
    public var succeeded: Bool? {
        if let s = status { return ["ok", "success", "completed"].contains(s) }
        if let r = endReason { return r == "cron_complete" }
        return nil
    }
}
struct RunsEnvelope: Decodable { let runs: [CronRun] }

public struct DeliveryTarget: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
struct TargetsEnvelope: Decodable { let targets: [DeliveryTarget] }

// MARK: Tools, models, memory, analytics, status

public struct Toolset: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var label: String?
    public var description: String?
    public var enabled: Bool?
    public var available: Bool?
    public var configured: Bool?
    public var tools: [String]?
    public var id: String { name }
}

public struct ModelInfo: Codable, Hashable, Sendable {
    public var model: String?
    public var provider: String?
    public var effectiveContextLength: Int?
}

public struct ProviderOption: Codable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var name: String?
    public var isCurrent: Bool?
    public var authenticated: Bool?
    public var models: [JSONValue]?
    public var warning: String?
    public var id: String { slug }
    /// Model entries are strings in some versions and {id,...} objects in others.
    public var modelIDs: [String] { (models ?? []).compactMap { $0.string ?? $0["id"]?.string } }
}

public struct MemoryProvider: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var available: Bool?
    public var configured: Bool?
    public var status: String?
    public var id: String { name }
}

public struct MemoryState: Codable, Hashable, Sendable {
    public var active: String?
    public var providers: [MemoryProvider]?
    public var builtinFiles: [String: Int]?
}

public struct UsageDay: Codable, Hashable, Sendable, Identifiable {
    public var day: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var estimatedCost: Double?
    public var sessions: Int?
    public var id: String { day }
}

public struct UsageByModel: Codable, Hashable, Sendable, Identifiable {
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var estimatedCost: Double?
    public var sessions: Int?
    public var apiCalls: Int?
    public var id: String { model }
}

public struct UsageTotals: Codable, Hashable, Sendable {
    public var totalInput: Int?
    public var totalOutput: Int?
    public var totalReasoning: Int?
    public var totalEstimatedCost: Double?
    public var totalSessions: Int?
    public var totalApiCalls: Int?
}

public struct UsageReport: Codable, Hashable, Sendable {
    public var daily: [UsageDay]?
    public var byModel: [UsageByModel]?
    public var totals: UsageTotals?
    public var periodDays: Int?
}

public struct HealthInfo: Codable, Hashable, Sendable {
    public var status: String?
    public var version: String?
    public var platform: String?
}

public struct DashboardStatus: Codable, Hashable, Sendable {
    public var version: String?
    public var releaseDate: String?
    public var gatewayRunning: Bool?
    public var gatewayState: String?
    /// Profiles this gateway also serves at /p/<name>/ (multiplexing). [] = only its own; nil = server predates it.
    public var gatewaySharedWith: [String]?
}

public struct LogLines: Codable, Sendable { public var file: String?; public var lines: [String] }
struct RawConfig: Decodable { let yaml: String; let path: String? }

// MARK: Chat stream (POST /api/sessions/{id}/chat/stream)

public struct ToolActivity: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var preview: String?
    public var state: State
    public enum State: Hashable, Sendable { case running, done, failed }
    public init(id: String, name: String, preview: String?, state: State) {
        self.id = id; self.name = name; self.preview = preview; self.state = state
    }
}

public struct ApprovalRequest: Identifiable, Hashable, Sendable {
    public var id: String { runId + (requestId ?? command ?? "") }
    public var runId: String
    public var requestId: String?
    public var command: String?
    public var description: String?
    public var choices: [String]
    /// AIDEV-NOTE: servers with a session authority reject an answer whose body isn't exactly
    /// {request_id, execution_generation, choice} ("invalid_params"); echo the event's generation.
    public var executionGeneration: Int? = nil
}

/// Typed view of the session chat SSE events (verified event names; see HermesClient.chatStream).
public enum ChatEvent: Sendable {
    case started(runId: String, messageId: String?)
    case delta(String)
    case thinking(String)
    case commentary(String)
    case toolStarted(ToolActivity)
    case toolFinished(id: String, failed: Bool)
    case approval(ApprovalRequest)
    case completed(content: String)
    case failed(String)
    case cancelled
    case status(String)
    /// The provider/model serving this run (run.started when locked; assistant.completed always).
    case runtime(SessionRuntime)
}

// MARK: - Session sources (list filter)

/// Where a session came from, normalized for filtering: "app" (API-server chats: Alaria, iOS), "desktop" (Hermes
/// Desktop), "cli", "cron" (scheduled runs), or the raw platform name (buzz, telegram, slack...).
public enum SessionSource {
    public static func kind(_ source: String?) -> String {
        switch (source ?? "api_server").lowercased() {
        case "api_server", "bot_room", "": return "app"
        case "local", "cli", "tui": return "cli"
        case "whatsapp_cloud": return "whatsapp"
        case "wecom_callback": return "wecom"
        case let s: return s
        }
    }
    /// AIDEV-NOTE: chat admission only continues api_server / bot_room sessions (session_api_turn.py raises
    /// permission_denied otherwise), so every other source gets a read-only composer. nil = api_server default.
    public static func canContinue(_ source: String?) -> Bool {
        guard let s = source?.lowercased(), !s.isEmpty else { return true }
        return s == "api_server" || s == "bot_room"
    }
    public static func label(_ kind: String) -> String {
        switch kind {
        case "app": return "Alaria"
        case "cli": return "Terminal"
        case "cron": return "Scheduled Runs"
        case "desktop": return "Hermes Desktop"
        case "acp": return "Code Editor"
        case "whatsapp": return "WhatsApp"
        case "msgraph_webhook": return "Microsoft 365"
        case "bluebubbles": return "iMessage"
        case "qqbot": return "QQ"
        case "wecom": return "WeCom"
        case "sms": return "SMS"
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
    /// The list filter: "chats" (everything except scheduled runs, the default), "all", or one kind.
    public static func matches(_ source: String?, filter: String) -> Bool {
        let k = kind(source)
        switch filter {
        case "all": return true
        case "chats": return k != "cron"
        default: return k == filter
        }
    }
}

extension HermesSession {
    public var sourceKind: String { SessionSource.kind(source) }
    public var canContinue: Bool { SessionSource.canContinue(source) }
}
