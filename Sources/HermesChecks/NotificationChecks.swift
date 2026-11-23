import Foundation
import HermesKit

/// Notification decision logic (bead hermes-mac-vqu): when to notify, and cron-run diffing.
func runNotificationChecks() {
    func job(_ id: String, _ at: String?, _ status: String? = "ok") -> CronJob {
        var o: [String: Any] = ["id": id]
        if let at { o["last_run_at"] = at }
        if let status { o["last_status"] = status }
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try! d.decode(CronJob.self, from: JSONSerialization.data(withJSONObject: o))
    }

    check("notify: only when the user can't already see the chat") {
        expect(NotificationRules.shouldNotify(enabled: true, appActive: false, viewingChat: true), "app in background")
        expect(NotificationRules.shouldNotify(enabled: true, appActive: true, viewingChat: false), "other chat")
        expect(!NotificationRules.shouldNotify(enabled: true, appActive: true, viewingChat: true), "looking at it")
        expect(!NotificationRules.shouldNotify(enabled: false, appActive: false, viewingChat: false), "kind turned off")
    }
    check("notify: reply outcomes") {
        expect(NotificationRules.replyOutcome(cancelled: false, error: nil) == .finished)
        expect(NotificationRules.replyOutcome(cancelled: false, error: "Hermes is busy (busy)") == .failed("Hermes is busy (busy)"))
        expect(NotificationRules.replyOutcome(cancelled: true, error: nil) == nil, "left the chat / new chat")
        expect(NotificationRules.replyOutcome(cancelled: false, error: "Stopped") == nil, "user pressed Stop")
    }
    check("notify: cron statuses") {
        expect(NotificationRules.cronOutcome("ok") == .succeeded)
        expect(NotificationRules.cronOutcome("delivery_failed") == .deliveryFailed)
        expect(NotificationRules.cronOutcome("error") == .failed)
        expect(NotificationRules.cronOutcome("blocked_config") == .failed)
        expect(NotificationRules.cronOutcome("cancelled") == nil)
    }
    check("notify: preview text") {
        expect(NotificationRules.preview("## Done\n\n**All** `tests`\n  pass") == "Done All tests pass")
        let long = NotificationRules.preview(String(repeating: "word ", count: 100), limit: 20)
        expect(long.count <= 20 && long.hasSuffix("…"), long)
    }
    check("notify: Hermes timestamps") {
        let d = NotificationRules.parseDate("2026-11-22T10:00:00.123456-05:00")
        expect(d == NotificationRules.parseDate("2026-11-22T15:00:00.123Z"), "microseconds + offset")
        expect(NotificationRules.parseDate("2026-11-22T15:00:00+00:00") != nil)
        expect(NotificationRules.parseDate("2026-11-22T15:00:00") != nil, "naive local")
        expect(NotificationRules.parseDate("garbage") == nil && NotificationRules.parseDate(nil) == nil)
    }
    check("cron watcher: first load is silent, then only new runs after launch") {
        let launch = NotificationRules.parseDate("2026-11-22T12:00:00Z")!
        var w = CronRunWatcher(since: launch)
        // Baseline: a run that finished after launch but before our first look must not fire.
        expect(w.update(scope: "s", jobs: [job("a", "2026-11-22T12:05:00Z"), job("b", nil, nil)]).isEmpty, "baseline")
        expect(w.update(scope: "s", jobs: [job("a", "2026-11-22T12:05:00Z"), job("b", nil, nil)]).isEmpty, "unchanged")
        let ended = w.update(scope: "s", jobs: [job("a", "2026-11-22T12:10:00Z", "error"), job("b", "2026-11-22T12:11:00.5+00:00")])
        expect(ended.map(\.job.id) == ["a", "b"], "\(ended.map(\.job.id))")
        expect(ended.map(\.outcome) == [.failed, .succeeded])
        expect(w.update(scope: "s", jobs: [job("a", "2026-11-22T12:10:00Z", "error"), job("b", "2026-11-22T12:11:00.5+00:00")]).isEmpty, "no repeats")
    }
    check("cron watcher: new jobs, old runs, cancelled, scope changes") {
        let launch = NotificationRules.parseDate("2026-11-22T12:00:00Z")!
        var w = CronRunWatcher(since: launch)
        _ = w.update(scope: "s", jobs: [])
        expect(w.update(scope: "s", jobs: [job("n", "2026-11-22T12:01:00Z")]).count == 1, "job created + run after baseline")
        expect(w.update(scope: "s", jobs: [job("n", "2026-11-22T12:01:00Z"), job("old", "2026-11-21T09:00:00Z")]).isEmpty,
               "a run from before launch (e.g. job appeared from another client)")
        expect(w.update(scope: "s", jobs: [job("n", "2026-11-22T12:02:00Z", "cancelled")]).isEmpty, "operator stop is silent")
        expect(w.update(scope: "other", jobs: [job("n", "2026-11-22T12:09:00Z")]).isEmpty, "new profile/server re-baselines")
        expect(w.update(scope: "other", jobs: [job("n", "weird")]).count == 1, "unparseable but changed for a known job")
        w.reset()
        expect(w.update(scope: "other", jobs: [job("n", "2026-11-22T12:30:00Z")]).isEmpty, "reset re-baselines")
    }
}
