import AppKit
import HermesKit
import Observation
import os
import UserNotifications

private let notifLog = Logger(subsystem: "net.jmaddington.hermes", category: "notifications")

/// What the app can notify about; each has its own Settings toggle (UserDefaults "notify.<kind>", default on).
enum NotificationKind: String, CaseIterable, Identifiable {
    case replies, approvals, cron
    var id: String { rawValue }
    var defaultsKey: String { "notify.\(rawValue)" }
    var label: String {
        switch self {
        case .replies: "Replies finished or failed"
        case .approvals: "Approval requests"
        case .cron: "Scheduled job runs"
        }
    }
    var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
}

/// Local notifications (bead hermes-mac-vqu): replies that finish while you aren't looking, approvals waiting on
/// you (answerable from the banner), and cron runs that ended. ChatStore/AppModel call the small hooks below.
/// AIDEV-NOTE: UNUserNotificationCenter.current() raises when the process has no bundle (`swift run`, checks), so
/// every use goes through `center`, which is nil outside a real .app. Authorization is requested lazily on the
/// first notification we'd actually post, never at launch.
@MainActor @Observable
final class Notifier {
    weak var app: AppModel?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private let delegate = NotificationDelegate()
    @ObservationIgnored private var cronWatcher = CronRunWatcher(since: .now)
    @ObservationIgnored private var lastCronPoll = Date.distantPast
    @ObservationIgnored private var cronPolling = false
    @ObservationIgnored private var loggedDenied = false
    /// Approvals we notified about and that are still unanswered: notification id -> what's needed to answer it.
    @ObservationIgnored private var pending: [String: (request: ApprovalRequest, entry: String, session: String)] = [:]

    static let approvalCategory = "approval"
    static let allowOnceAction = "approval.once"
    static let denyAction = "approval.deny"

    /// Only inside a real app bundle (see AIDEV-NOTE above).
    let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    var isAvailable: Bool { center != nil }

    init() {
        guard let center else { return }
        delegate.notifier = self
        center.delegate = delegate // set before launch finishes so a click that launched the app is delivered
        let allow = UNNotificationAction(identifier: Self.allowOnceAction, title: "Allow Once", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny],
                                                                 intentIdentifiers: [], options: [])])
        Task { await refreshAuthorization() }
    }

    // MARK: authorization

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once (the system shows its prompt only while the status is notDetermined). Returns whether we may post.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        guard let center else { return false }
        await refreshAuthorization()
        switch authorization {
        case .authorized, .provisional, .ephemeral: return true
        case .denied:
            if !loggedDenied { loggedDenied = true; notifLog.info("notifications denied in System Settings; not posting [ALR-NOTIF-DENIED]") }
            return false
        case .notDetermined:
            do {
                let ok = try await center.requestAuthorization(options: [.alert, .sound])
                notifLog.info("notification authorization answered granted=\(ok) [ALR-NOTIF-AUTH]")
            } catch {
                notifLog.error("notification authorization failed: \(error.localizedDescription, privacy: .public) [ALR-NOTIF-AUTH-ERR]")
            }
            await refreshAuthorization()
            return authorization == .authorized || authorization == .provisional
        @unknown default: return false
        }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "net.jmaddington.hermes"
        if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: context

    /// Server + profile the app is showing; notifications carry it so a click can't act on another server's data.
    var currentScope: String { ConnectionSettings.currentID + "|" + (app?.client?.profile ?? "") }

    private var appActive: Bool { NSApp.isActive }
    /// A main window is on screen (not minimized, not fully covered).
    private var windowVisible: Bool {
        NSApp.windows.contains { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }
    private func isViewingChat(_ session: String) -> Bool {
        guard let app else { return false }
        return windowVisible && app.section == .chats && app.chats.selection == session
    }
    private func chatTitle(_ session: String) -> String {
        app?.chats.sessions.first { $0.id == session }?.displayTitle ?? "Alaria"
    }

    // MARK: hooks (ChatStore / AppModel)

    /// A streamed turn ended. `cancelled` = the stream was dropped (new chat, chat switch, server switch).
    func replyEnded(session: String, entry: String, cancelled: Bool) {
        clearApprovals(entry: entry)
        guard let app, !app.voice.isActive else { return } // voice mode speaks the reply already
        let e = app.chats.entries.first { $0.id == entry }
        guard let outcome = NotificationRules.replyOutcome(cancelled: cancelled, error: e?.error),
              NotificationRules.shouldNotify(enabled: NotificationKind.replies.isEnabled, appActive: appActive,
                                             viewingChat: isViewingChat(session)) else { return }
        let body: String
        switch outcome {
        case .finished: body = NotificationRules.preview(e?.text ?? "").isEmpty ? "Reply finished." : NotificationRules.preview(e?.text ?? "")
        case .failed(let msg): body = "Reply failed: \(NotificationRules.preview(msg))"
        }
        post(.replies, id: "reply.\(session).\(entry)", title: chatTitle(session), body: body, info: ["session": session])
    }

    func approvalRequested(_ a: ApprovalRequest, session: String, entry: String) {
        guard NotificationRules.shouldNotify(enabled: NotificationKind.approvals.isEnabled, appActive: appActive,
                                             viewingChat: isViewingChat(session)) else { return }
        let id = "approval.\(a.id)"
        pending[id] = (a, entry, session)
        let what = NotificationRules.preview(a.command ?? a.description ?? "Hermes wants to run a command.", limit: 200)
        post(.approvals, id: id, title: "Approval needed", subtitle: chatTitle(session), body: what,
             info: ["session": session], category: Self.approvalCategory)
    }

    /// Answered in the app (or from the banner): drop it so the banner can't answer twice.
    func approvalResolved(_ a: ApprovalRequest) {
        let id = "approval.\(a.id)"
        pending[id] = nil
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func clearApprovals(entry: String) {
        let ids = pending.filter { $0.value.entry == entry }.map(\.key)
        guard !ids.isEmpty else { return }
        ids.forEach { pending[$0] = nil }
        center?.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Called by AppModel's health monitor (every 15 s); actually polls `GET /api/jobs` at most every 30 s.
    func pollCron(force: Bool = false) async {
        guard let app, let client = app.client, isAvailable, !cronPolling else { return }
        guard NotificationKind.cron.isEnabled, authorization != .denied else { cronWatcher.reset(); return }
        guard force || Date.now.timeIntervalSince(lastCronPoll) >= 30 else { return }
        cronPolling = true; defer { cronPolling = false }
        lastCronPoll = .now
        let scope = currentScope
        let jobs: [CronJob]
        do { jobs = try await client.jobs() } catch {
            if !error.isCancellation { notifLog.debug("cron poll failed: \(error.localizedDescription, privacy: .public) [ALR-NOTIF-CRON-ERR]") }
            return
        }
        guard scope == currentScope else { return } // server/profile switched mid-request
        for ended in cronWatcher.update(scope: scope, jobs: jobs) {
            let j = ended.job
            if appActive, windowVisible, app.section == .scheduled, app.library.jobSelection == j.id { continue }
            let name = j.name?.isEmpty == false ? j.name! : "Scheduled job"
            let body: String
            switch ended.outcome {
            case .succeeded: body = "Finished."
            case .deliveryFailed: body = "Finished, but delivery failed" + (j.lastDeliveryError.map { ": \(NotificationRules.preview($0, limit: 140))" } ?? ".")
            case .failed: body = "Failed" + (j.lastError.map { ": \(NotificationRules.preview($0, limit: 140))" } ?? ".")
            }
            var info = ["job": j.id]
            // Best effort: the run's own session, so the click opens it (dashboard only; newest run first).
            if client.hasDashboard, let sid = try? await client.jobRuns(j.id, limit: 1).first?.conversationID { info["session"] = sid }
            post(.cron, id: "cron.\(j.id).\(j.lastRunAt ?? "")", title: name, body: body, info: info)
        }
    }

    // MARK: posting

    private func post(_ kind: NotificationKind, id: String, title: String, subtitle: String? = nil, body: String,
                      info: [String: String], category: String? = nil) {
        guard let center else { return }
        let scope = currentScope
        Task {
            guard await ensureAuthorized() else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            if let subtitle { c.subtitle = subtitle }
            c.body = body
            c.sound = .default
            c.threadIdentifier = info["session"] ?? kind.rawValue
            if let category { c.categoryIdentifier = category }
            c.userInfo = info.merging(["kind": kind.rawValue, "scope": scope]) { a, _ in a }
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
                notifLog.info("posted \(kind.rawValue, privacy: .public) notification [ALR-NOTIF-POST]")
            } catch {
                notifLog.error("posting \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public) [ALR-NOTIF-POST-ERR]")
            }
        }
    }

    // MARK: responses

    /// A click or a banner action. Values were copied out of the (non-Sendable) response by the delegate.
    func handle(action: String, notificationID: String, info: [String: String]) {
        guard let app else { return }
        let isAnswer = action == Self.allowOnceAction || action == Self.denyAction
        if !isAnswer { bringToFront() }
        // AIDEV-NOTE: security; never act on a notification from another server/profile (ids would be the old one's).
        guard info["scope"] == currentScope else {
            notifLog.info("notification from another server/profile ignored [ALR-NOTIF-SCOPE]")
            app.flash("That notification is from another server or profile. Switch to it to see the chat.")
            return
        }
        if isAnswer {
            guard let p = pending[notificationID] else {
                notifLog.info("approval action for a request that is no longer waiting [ALR-NOTIF-STALE]")
                app.flash("That approval is no longer waiting.")
                return
            }
            let choice = action == Self.allowOnceAction ? "once" : "deny"
            guard p.request.choices.contains(choice) else { bringToFront(); openChat(p.session); return }
            notifLog.info("approval answered from notification choice=\(choice, privacy: .public) [ALR-NOTIF-ANSWER]")
            pending[notificationID] = nil
            app.chats.answer(p.request, choice, entry: p.entry) // flashes + keeps the in-chat card on failure
            return
        }
        if let sid = info["session"] { openChat(sid) }
        else if let job = info["job"] { app.section = .scheduled; app.library.jobSelection = job }
    }

    private func bringToFront() {
        NSApp.unhide(nil)
        NSApp.windows.filter { $0.isMiniaturized && $0.canBecomeMain }.first?.deminiaturize(nil)
        NSApp.activate()
    }

    private func openChat(_ session: String) {
        guard let app else { return }
        app.section = .chats
        if app.chats.selection != session { app.chats.select(session) }
    }
}

/// UNUserNotificationCenter calls back off the main actor; copy what we need and hop over.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    weak var notifier: Notifier?

    // We only post when the user can't see the thing, so show banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        var collected: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo { if let k = k as? String, let v = v as? String { collected[k] = v } }
        let info = collected
        guard action != UNNotificationDismissActionIdentifier else { return }
        await MainActor.run { [weak self] in self?.notifier?.handle(action: action, notificationID: id, info: info) }
    }
}
