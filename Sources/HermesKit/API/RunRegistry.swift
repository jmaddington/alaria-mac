import Foundation

// Pure, platform-neutral pieces of the detached-turn flow (bead hermes-mac-wny), kept here so hermes-checks can
// test them: the persisted registry of runs a client is following, how history and a live run's replay fit
// together, and what Enter does while a reply is running (busy input).

/// One run a client started and is following, as persisted across launches.
public struct PersistedRun: Codable, Hashable, Sendable {
    public var runId: String
    public var session: String
    /// Server clock (GET /v1/runs created_at); nil until known.
    public var createdAt: Double?
    /// The user's text, so a relaunch can show the turn before its stored row exists (queued runs).
    public var text: String
    public var queued: Bool
    /// Client clock, for pruning records nobody came back to.
    public var savedAt: Date
    public init(runId: String, session: String, createdAt: Double? = nil, text: String, queued: Bool = false, savedAt: Date = .now) {
        self.runId = runId; self.session = session; self.createdAt = createdAt; self.text = text
        self.queued = queued; self.savedAt = savedAt
    }
}

/// The runs a client follows for one server + profile (stored as JSON in UserDefaults by the app).
public struct RunRegistry: Codable, Hashable, Sendable {
    /// Hermes forgets terminal run statuses after a while; a record this old can only be stale.
    public static let maxAge: TimeInterval = 24 * 3600
    public static let maxRuns = 50

    public private(set) var runs: [PersistedRun] = []
    public init(runs: [PersistedRun] = []) { self.runs = runs }

    public init(data: Data?) {
        guard let data, let r = try? JSONDecoder().decode(RunRegistry.self, from: data) else { self.init(); return }
        self = r
    }
    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// Adds or replaces the record for `run.runId`, newest last; keeps at most `maxRuns`.
    public mutating func upsert(_ run: PersistedRun) {
        if let i = runs.firstIndex(where: { $0.runId == run.runId }) { runs[i] = run } else { runs.append(run) }
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
    }
    public mutating func remove(_ runId: String) { runs.removeAll { $0.runId == runId } }
    public func runs(in session: String) -> [PersistedRun] { runs.filter { $0.session == session } }
    public mutating func prune(now: Date = .now) { runs.removeAll { now.timeIntervalSince($0.savedAt) > Self.maxAge } }
}

public enum RunHistory {
    /// Where stored history stops being "before the live runs": the index of the first user row written at or
    /// after any live run's creation (server clock). Rows from there on are that run's partial steps (Hermes
    /// writes the user row and tool steps while the run is going), which the live reply already shows.
    /// A queued run has no row yet, so it cuts nothing. Returns `rows.count` when nothing is cut.
    // AIDEV-NOTE: tolerance 0 is deliberate: a run's user row is written at admission, BEFORE the 202, so it can
    // never be stamped after a later run's created_at. A looser cut would eat the previous turn of a queued run.
    public static func cut(rows: [(role: String, timestamp: Double?)], liveRunsCreatedAt: [Double]) -> Int {
        var cut = rows.count
        for c in liveRunsCreatedAt {
            if let i = rows.firstIndex(where: { $0.role == "user" && ($0.timestamp ?? -.infinity) >= c }) { cut = min(cut, i) }
        }
        return cut
    }

    public static func cut(_ msgs: [HermesMessage], liveRunsCreatedAt: [Double]) -> [HermesMessage] {
        Array(msgs.prefix(cut(rows: msgs.map { ($0.role, $0.timestamp) }, liveRunsCreatedAt: liveRunsCreatedAt)))
    }
}

/// What Enter does with new text while a reply is running (the Hermes TUI's `busy_input_mode`).
public enum BusyInputMode: String, CaseIterable, Codable, Sendable {
    /// Send it as the next turn once this one ends (Hermes queues a second run on a busy session).
    case queue
    /// Fold it into the running turn (`POST /v1/runs/{id}/steer`); text only.
    case steer
    /// Stop the running turn, then send it.
    case interrupt

    public var title: String {
        switch self {
        case .queue: return "Queue"
        case .steer: return "Steer"
        case .interrupt: return "Stop and Send"
        }
    }
}

public enum BusyAction: Equatable, Sendable {
    /// Nothing is running: an ordinary send.
    case send
    /// Start another run; the server queues it behind the current one.
    case queue
    case steer(runId: String)
    /// Stop `runId`, then send (as a queued run, so it starts the moment the stop lands).
    case interrupt(runId: String)
}

public enum BusyInput {
    /// `runId` = the running (not queued) run, nil when none or its id isn't known yet.
    /// Steer needs a running run and text only (steer takes no images or files); otherwise it falls back to queue.
    public static func action(mode: BusyInputMode, busy: Bool, runId: String?, hasAttachments: Bool, text: String) -> BusyAction {
        guard busy else { return .send }
        switch mode {
        case .queue: return .queue
        case .steer:
            guard let runId, !hasAttachments, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .queue }
            return .steer(runId: runId)
        case .interrupt:
            guard let runId else { return .queue }
            return .interrupt(runId: runId)
        }
    }
}
