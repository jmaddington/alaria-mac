import Foundation

/// Pure decision logic for the Mac app's local notifications (bead hermes-mac-vqu), kept in HermesKit so
/// `hermes-checks` can test it. No UserNotifications/AppKit here (HermesKit also compiles on iOS).
public enum NotificationRules {
    /// Notify about a chat event unless the user is already looking at that chat in the frontmost app.
    public static func shouldNotify(enabled: Bool, appActive: Bool, viewingChat: Bool) -> Bool {
        enabled && !(appActive && viewingChat)
    }

    /// How a finished turn should be announced; nil = say nothing (the user stopped it or left the chat).
    public enum ReplyOutcome: Equatable, Sendable { case finished, failed(String) }
    public static func replyOutcome(cancelled: Bool, error: String?) -> ReplyOutcome? {
        if cancelled || error == "Stopped" { return nil }
        if let error, !error.isEmpty { return .failed(error) }
        return .finished
    }

    public enum CronOutcome: Equatable, Sendable { case succeeded, deliveryFailed, failed }
    /// Maps hermes cron `last_status` (cron/jobs.py `_record_run_outcome`). "cancelled" is an operator stop: silent.
    public static func cronOutcome(_ status: String?) -> CronOutcome? {
        switch status {
        case "ok": .succeeded
        case "delivery_failed": .deliveryFailed
        case "cancelled": nil
        default: .failed // error, blocked_config, interrupted, unknown future codes; nil status counts as failed too
        }
    }

    /// One-line notification body: markdown markers dropped, whitespace collapsed, capped at `limit` characters.
    public static func preview(_ text: String, limit: Int = 180) -> String {
        var s = text.replacingOccurrences(of: "```", with: " ")
        for m in ["**", "__", "`", "#", "> "] { s = s.replacingOccurrences(of: m, with: "") }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Parses Hermes timestamps: Python `isoformat()` gives 6 fractional digits ("...T10:00:00.123456-05:00"),
    /// which ISO8601DateFormatter rejects, so the fraction is cut to milliseconds first.
    public static func parseDate(_ s: String?) -> Date? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."), s[s.startIndex..<dot].contains("T") {
            let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
            let digits = s[s.index(after: dot)..<digitsEnd]
            s.replaceSubrange(s.index(after: dot)..<digitsEnd, with: String((digits + "000").prefix(3)))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Naive timestamp (no offset): Hermes writes these in local time.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            naive.dateFormat = fmt
            if let d = naive.date(from: s) { return d }
        }
        return nil
    }
}

/// Spots cron runs that ended since the last poll by diffing each job's `last_run_at` (stamped when a run
/// completes, see hermes cron/jobs.py `_record_run_outcome`). The server has no push channel for runs we didn't start.
/// AIDEV-NOTE: never-spam rules. The first poll for a scope (server + profile) only records a baseline, and a run
/// must also have ended after `since` (app launch). Changing scope re-baselines silently.
public struct CronRunWatcher: Sendable {
    public struct Ended: Equatable, Sendable {
        public var job: CronJob
        public var outcome: NotificationRules.CronOutcome
    }

    public let since: Date
    public private(set) var scope: String?
    private var lastRun: [String: String] = [:] // job id -> last_run_at ("" = never ran)

    public init(since: Date = .now) { self.since = since }

    /// Feed a fresh job list; returns the runs that ended since the previous call for the same scope.
    public mutating func update(scope: String, jobs: [CronJob]) -> [Ended] {
        defer { lastRun = Dictionary(jobs.map { ($0.id, $0.lastRunAt ?? "") }, uniquingKeysWith: { a, _ in a }) }
        guard scope == self.scope else { self.scope = scope; return [] }
        var out: [Ended] = []
        for j in jobs {
            guard let at = j.lastRunAt, !at.isEmpty, lastRun[j.id] != at else { continue }
            // Unparseable timestamp: trust the diff only for a job we had already seen.
            if let d = NotificationRules.parseDate(at) { if d < since { continue } } else if lastRun[j.id] == nil { continue }
            if let o = NotificationRules.cronOutcome(j.lastStatus) { out.append(Ended(job: j, outcome: o)) }
        }
        return out
    }

    /// Forget the baseline (e.g. the notification kind was turned off), so turning it back on can't replay old runs.
    public mutating func reset() { scope = nil; lastRun = [:] }
}
