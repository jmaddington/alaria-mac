import Foundation
import HermesKit
import Observation
import os

let runLog = Logger(subsystem: "net.jmaddington.hermes", category: "runs")

/// One rendered item in a conversation.
struct ChatEntry: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, system }
    let id: String
    var role: Role
    var text: String
    var attachments: [Attachment] = []
    var thinking: String = ""
    var tools: [ToolActivity] = []
    var approval: ApprovalRequest?
    /// Commands YOLO answered "once" for, shown under the reply as an audit trail.
    var autoApproved: [String] = []
    /// An approval still unanswered when its run ended (Hermes timed it out); shown instead of a dead card.
    var expiredApproval: String?
    var answeringApproval = false
    var streaming = false
    var error: String?
    var date: Date?
    /// A turn sent while another was running, waiting its turn server-side (busy input "queue"). The user entry
    /// shows "Queued"; its reply placeholder stays hidden until the run starts.
    var queued = false
    /// Text the user steered this reply with while it ran (busy input "steer", /steer).
    var steers: [String] = []
}

/// A turn Alaria started (or re-attached to after a relaunch) and is following over /v1/runs (bead hermes-mac-wny).
/// The run lives on the server; this is the client's view of it, kept while the user looks at other chats.
struct LiveRun: Identifiable {
    /// Local key (= the reply entry's id).
    let id: String
    /// nil while the blank chat's session is being created.
    var session: String?
    /// The blank chat it was sent from (`ChatStore.blankGen`), so a New Chat meanwhile doesn't adopt it.
    let blankGen: Int
    /// The registry it is persisted in (server + profile), fixed at start.
    let registryKey: String
    var runId: String?
    /// Server clock; cuts the run's partial rows out of reloaded history (RunHistory.cut).
    var createdAt: Double?
    var lastSeq: Int?
    var user: ChatEntry
    var reply: ChatEntry
    /// Prompt ids the server said are settled; a replayed approval.request for one of them is stale.
    var settled: Set<String> = []
    /// Events were missed (buffer swept, run forgotten): reload the chat's stored history when it ends.
    var reloadHistory = false
    /// Cancelled while still queued: its bubbles go away when it ends instead of staying as "Stopped".
    var withdrawn = false
    /// Approvals YOLO already answered from a status poll, so the next poll doesn't answer them again.
    var yoloAnswered: Set<String> = []
    var onEvent: ((ChatEvent) -> Void)?
    var onFinish: ((Error?) -> Void)?
    var queued: Bool { reply.queued }
}

@MainActor @Observable
final class ChatStore {
    weak var app: AppModel?
    var sessions: [HermesSession] = []
    var loadingSessions = false
    var selection: String?
    var entries: [ChatEntry] = []
    var loadingMessages = false
    var draft = ""
    /// Composer attachments waiting to be sent (Attachments.swift).
    let attachments = AttachmentTray()
    /// Per-chat model locks + the picker inventory (SessionModels.swift).
    let models = SessionModels()
    var searchText = ""
    var searchHits: [SearchHit] = []

    // MARK: live runs
    // AIDEV-NOTE: turns run detached on the server (POST /v1/runs) and are followed here per run, NOT per selected
    // chat: switching chats just stops looking. The old session chat stream interrupted the agent on disconnect.
    // Each run's reply is owned by `live` and mirrored into `entries` while its chat is open (mutate/update).
    // Never key anything on streamTask-style "the one stream": several chats (and a queue) can run at once.
    private(set) var live: [LiveRun] = []
    @ObservationIgnored private var liveTasks: [String: Task<Void, Never>] = [:]
    /// Bumped by Cmd-R: follow loops waiting out a backoff retry right away.
    @ObservationIgnored private var kick = 0
    /// Bumped by New Chat; a run still creating its session only takes over the selection in its own blank chat.
    private var blankGen = 0
    /// The registry key whose persisted runs were resumed (server + profile); see syncScope().
    @ObservationIgnored private var attachedKey: String?

    /// Live runs of the open chat (the blank chat's own while its session is created), oldest first.
    var selectedRuns: [LiveRun] { live.filter { isSelected($0) } }
    /// The run of the open chat that is actually running (not queued behind it).
    var currentRun: LiveRun? { let rs = selectedRuns; return rs.first { !$0.queued } ?? rs.first }
    var isStreaming: Bool { !selectedRuns.isEmpty }
    /// The open chat's running run id (nil while queued or before POST /v1/runs returned).
    var runId: String? { selectedRuns.first { !$0.queued }?.runId }
    /// Chats with a run Alaria is following, for the list's "responding" indicator. Runs started by other
    /// clients aren't known: Hermes exposes no per-session running state.
    var runningSessions: Set<String> { Set(live.compactMap(\.session)) }

    private var loadedFor: String?
    /// Set when a chat's history failed to load; the conversation shows it with Try Again (hermes-mac-nze).
    var messagesError: String?

    var client: HermesClient? { app?.client }
    var selectedSession: HermesSession? { sessions.first { $0.id == selection } }

    private func isSelected(_ r: LiveRun) -> Bool {
        r.session == nil ? (selection == nil && r.blankGen == blankGen) : r.session == selection
    }

    /// An entry by id, in the open chat or in a live run of another chat (the notifier reads finished replies).
    func entry(_ id: String) -> ChatEntry? {
        live.first { $0.reply.id == id }?.reply ?? entries.first { $0.id == id }
    }

    func reload() async {
        guard let client else { return }
        syncScope()
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            sessions = try await client.sessions(limit: 200).items
                .filter { $0.hidden != true }
                .sorted { ($0.pinned == true ? 1 : 0, $0.activityDate) > ($1.pinned == true ? 1 : 0, $1.activityDate) }
        } catch {
            app?.flash("Couldn't load chats: \(error.localizedDescription)")
        }
    }

    /// Cmd-R in Chats: the list, plus the open chat from the server - its live run reconnects now (if it was
    /// waiting to retry), otherwise its history is fetched again to catch up on turns made elsewhere.
    func refresh() async {
        await reload()
        resumePersisted() // a run this client lost track of (e.g. a failed resume) gets another try
        if let sel = selection, !live.contains(where: { $0.session == sel }) {
            loadedFor = nil
            select(sel)
        }
        kick += 1
        app?.flash("Refreshed")
    }

    func select(_ id: String?) {
        if id != nil { yoloNewChat = false; models.pending = nil } // pending YOLO/model belong to the blank chat only
        guard id != loadedFor else { return }
        // Leaving a chat with a running reply just stops showing it: the run goes on server-side (hermes-mac-wny).
        selection = id
        loadedFor = id
        messagesError = nil
        entries = liveEntries(for: id)
        guard let id, let client else { return }
        loadingMessages = true
        // Captured before the await: a run that finishes during it still has its turn on screen (dev-40 review #5).
        let runsBefore = live.filter { $0.session == id }
        Task {
            defer { if selection == id { loadingMessages = false } }
            do {
                let msgs = try await client.messages(id)
                guard selection == id else { return }
                // A live run's rows so far (user row, tool steps) are shown by its live reply instead.
                // Without a server created_at (its status check failed), a running run's turn starts at the last user row.
                let lastUser = msgs.last { $0.role == "user" }?.timestamp
                let now = live.filter { $0.session == id }
                let runs = now + runsBefore.filter { b in !now.contains { $0.id == b.id } }
                let starts = runs.compactMap { $0.createdAt ?? ($0.queued ? nil : lastUser) }
                let cut = RunHistory.cut(msgs, liveRunsCreatedAt: starts)
                // Keep anything sent while history was loading (hermes-mac-7j1): history goes in front of it.
                let history = Self.entries(from: cut)
                let known = Set(history.map(\.id))
                entries = history + entries.filter { !known.contains($0.id) }
            } catch {
                guard selection == id, !error.isCancellation else { return }
                loadedFor = nil // so selecting it again retries
                messagesError = error.localizedDescription
            }
        }
    }

    private func liveEntries(for session: String?) -> [ChatEntry] {
        live.filter { session == nil ? isSelected($0) : $0.session == session }.flatMap { [$0.user, $0.reply] }
    }

    /// Folds Hermes' stored messages (user / assistant / tool rows) into display entries:
    /// tool rows attach to the preceding assistant turn as finished tool chips.
    static func entries(from msgs: [HermesMessage]) -> [ChatEntry] {
        var out: [ChatEntry] = []
        for m in msgs {
            let date = m.timestamp.map { Date(timeIntervalSince1970: $0) }
            switch m.role {
            case "user":
                let (text, attachments) = Attachment.fromStored(m)
                out.append(ChatEntry(id: "m\(m.id)", role: .user, text: MessageText.display(text), attachments: attachments, date: date))
            case "assistant":
                let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var tools: [ToolActivity] = []
                if case .array(let calls)? = m.toolCalls {
                    for (i, c) in calls.enumerated() {
                        let name = c["function"]?["name"]?.string ?? c["name"]?.string ?? "tool"
                        tools.append(ToolActivity(id: "m\(m.id)-\(i)", name: name, preview: nil, state: .done))
                    }
                }
                if let last = out.last, last.role == .assistant, last.text.isEmpty {
                    // A tool-calling step followed by the answer: merge into one visual turn.
                    out[out.count - 1].text = text
                    out[out.count - 1].tools += tools
                    if let t = m.thinking { out[out.count - 1].thinking += t }
                } else if MessageText.isInterruption(text) {
                    // Hermes' stored "Your request was not processed..." for a stopped turn: show the quiet marker.
                    out.append(ChatEntry(id: "m\(m.id)", role: .assistant, text: "", tools: tools, error: "Stopped", date: date))
                } else if !text.isEmpty || !tools.isEmpty {
                    out.append(ChatEntry(id: "m\(m.id)", role: .assistant, text: text, thinking: m.thinking ?? "", tools: tools, date: date))
                }
            default:
                continue // tool results and system rows are summarized by the chips above
            }
        }
        return out
    }

    func retryMessages() {
        let id = selection
        loadedFor = nil
        select(id)
    }

    func newChat() {
        messagesError = nil
        blankGen += 1 // a reply still creating its chat stays in that chat, not this new one
        selection = nil
        yoloNewChat = false
        loadedFor = nil
        entries = []
        draft = ""
        attachments.clear()
        models.pending = nil // new chats follow the server's default unless a model is picked for them
        // The server's default can change (Settings > Model, another client): refresh what the menu shows.
        Task { await models.load(client, force: true) }
    }

    /// Sends a message as a new turn, creating a session first if needed. `onEvent` lets voice mode tap the reply.
    /// Returns false when nothing was sent (empty, busy, or over Hermes' attachment limits - that one flashes why).
    /// While a reply runs, the composer goes through `sendBusy` instead.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = [], onEvent: ((ChatEvent) -> Void)? = nil, onFinish: ((Error?) -> Void)? = nil) -> Bool {
        guard !isStreaming else { return false }
        return start(text, attachments: attachments, queued: false, onEvent: onEvent, onFinish: onFinish)
    }

    /// The default for Enter while a reply runs (Settings > Chat).
    // AIDEV-NOTE: GUI default is queue, not the TUI's interrupt: in a window you often type the next thought while
    // reading the reply, and a stray Enter should never throw away a long agent turn. Stop is one click/⌘. away.
    static let busyModeKey = "chat.busyInputMode"
    static var defaultBusyMode: BusyInputMode {
        UserDefaults.standard.string(forKey: busyModeKey).flatMap(BusyInputMode.init(rawValue:)) ?? .queue
    }

    /// Text sent while the open chat's reply is running: queue it, steer the reply with it, or stop and send.
    @discardableResult
    func sendBusy(_ raw: String, attachments atts: [Attachment] = [], mode: BusyInputMode? = nil) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !atts.isEmpty, let client else { return false }
        let mode = mode ?? Self.defaultBusyMode
        switch BusyInput.action(mode: mode, busy: isStreaming, runId: runId, hasAttachments: !atts.isEmpty, text: text) {
        case .send:
            return start(text, attachments: atts, queued: false)
        case .queue:
            if mode == .steer { app?.flash(atts.isEmpty ? "Queued: the reply can't take steering yet" : "Queued: steering takes text only") }
            return start(text, attachments: atts, queued: true)
        case .steer(let run):
            guard let key = selectedRuns.first(where: { $0.runId == run })?.id else { return false }
            let here = selection
            draft = ""
            mutate(key) { $0.reply.steers.append(text) }
            Task {
                do {
                    try await client.steer(run, text: text)
                    runLog.info("steered \(run, privacy: .public) [ALR-RUN-STEER]")
                } catch {
                    // Steer races the run's end (409 run_not_accepting_steer): send it as the next turn instead.
                    runLog.info("steer refused, queueing: \(error.localizedDescription, privacy: .public) [ALR-RUN-STEER-Q]")
                    mutate(key) { r in if let i = r.reply.steers.lastIndex(of: text) { r.reply.steers.remove(at: i) } }
                    guard selection == here else { app?.flash("Steering wasn't accepted, so this wasn't sent: “\(text)”"); return }
                    if start(text, attachments: [], queued: isStreaming) { app?.flash("The reply had moved on, so that was sent as the next message") }
                }
            }
            return true
        case .interrupt(let run):
            app?.run("Stop") { try await client.stopRun(run) }
            // Sent as a queued run: Hermes starts it the moment the stop lands.
            return start(text, attachments: atts, queued: true)
        }
    }

    /// Starts a run: shows the user's message + a reply placeholder, then `drive` posts and follows it.
    private func start(_ text: String, attachments: [Attachment], queued: Bool,
                       onEvent: ((ChatEvent) -> Void)? = nil, onFinish: ((Error?) -> Void)? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, let client else { return false }
        syncScope() // a scope change not yet synced would detach this run right after it starts
        let parts = Attachment.parts(text: text, attachments)
        if let problem = ChatContent.problem(with: parts) { app?.flash(problem); return false }
        draft = ""
        let user = ChatEntry(id: UUID().uuidString, role: .user, text: text, attachments: attachments, date: .now, queued: queued)
        let reply = ChatEntry(id: UUID().uuidString, role: .assistant, text: "", streaming: true, date: .now, queued: queued)
        let run = LiveRun(id: reply.id, session: selection, blankGen: blankGen, registryKey: registryKey,
                          user: user, reply: reply, onEvent: onEvent, onFinish: onFinish)
        live.append(run)
        entries.append(user)
        entries.append(reply)
        let armYolo = selection == nil && yoloNewChat // captured now: only the blank chat that armed it
        if selection == nil { yoloNewChat = false }
        liveTasks[run.id] = Task { await drive(run.id, client: client, parts: parts, armYolo: armYolo) }
        return true
    }

    private func run(_ key: String) -> LiveRun? { live.first { $0.id == key } }

    /// Applies `f` to a live run, mirroring its entries into the open conversation.
    private func mutate(_ key: String, _ f: (inout LiveRun) -> Void) {
        guard let i = live.firstIndex(where: { $0.id == key }) else { return }
        f(&live[i])
        let r = live[i]
        for e in [r.user, r.reply] {
            if let j = entries.firstIndex(where: { $0.id == e.id }), entries[j] != e { entries[j] = e }
        }
    }

    /// Creates the session if needed, posts the run, follows it to the end. Cancellation = detach (profile or
    /// server switch): the run keeps going server-side and stays persisted for when that profile comes back.
    private func drive(_ key: String, client: HermesClient, parts: [ContentPart], armYolo: Bool) async {
        var failure: Error?
        do {
            guard var r = run(key) else { return }
            if r.session == nil {
                let s = try await client.createSession(title: nil, model: models.pending) // a model picked pre-create
                // Detached (scope change) or stopped while creating: don't adopt the session into whatever is open now.
                try Task.checkCancellation()
                guard run(key) != nil else { return }
                if armYolo { setYolo(true, for: s.id) }
                models.adoptPending(for: s.id)
                sessions.insert(s, at: 0)
                let stillHere = isSelected(r)
                mutate(key) { $0.session = s.id }
                if stillHere { selection = s.id; loadedFor = s.id }
                r.session = s.id
            }
            guard let sid = r.session else { return }
            let h = try await client.startRun(session: sid, parts: parts)
            // Stopped or cancelled while the POST was in flight: the server has the run now, so stop it there too.
            guard run(key) != nil else {
                runLog.info("run \(h.runId, privacy: .public) was stopped before it started; stopping it [ALR-RUN-STOP-EARLY]")
                try? await client.stopRun(h.runId)
                return
            }
            mutate(key) { $0.runId = h.runId }
            runLog.info("run \(h.runId, privacy: .public) started in \(sid, privacy: .public) [ALR-RUN1]")
            persist(key)
            if var st = try? await client.runStatus(h.runId) {
                // Every run reports "queued" for a moment before it starts, so an idle chat looks again before
                // believing it (another client's turn can genuinely hold the session).
                let behindOurs = live.contains { $0.session == sid && $0.id != key && $0.runId != nil }
                if st.isQueued, !behindOurs {
                    try await Task.sleep(for: .seconds(1))
                    st = (try? await client.runStatus(h.runId)) ?? st
                }
                let queued = st.isQueued
                mutate(key) { $0.createdAt = st.createdAt; $0.user.queued = queued; $0.reply.queued = queued }
                persist(key)
            }
            try await follow(key, client: client)
        } catch {
            if error.isCancellation || Task.isCancelled { return } // detached; see detachAll()
            failure = error
            runLog.error("run failed: \(error.localizedDescription, privacy: .public) [ALR-RUN-ERR]")
            mutate(key) { $0.reply.error = error.localizedDescription }
        }
        await finish(key, failure: failure)
    }

    /// Follows a run's events until it ends: resumes after the last seq on a dropped stream, retries network
    /// errors with backoff while the server says it's still running, and polls when its event buffer is gone.
    private func follow(_ key: String, client: HermesClient) async throws {
        var backoff = 1.0
        while true {
            try Task.checkCancellation()
            guard let r = run(key), let runId = r.runId else { return }
            do {
                for try await ev in client.runEvents(runId, after: r.lastSeq) {
                    backoff = 1
                    handle(ev, key)
                    if ev.isTerminal { return }
                }
            } catch let e as HermesError where e.status == 404 {
                // Hermes drops a run's event buffer ~5 min after it started when nobody is attached (relaunch, sleep).
                runLog.info("events gone for \(runId, privacy: .public); polling status [ALR-RUN-POLL]")
                try await poll(key, client: client)
                return
            } catch {
                if error.isCancellation || Task.isCancelled { throw CancellationError() }
                runLog.info("event stream dropped for \(runId, privacy: .public): \(error.localizedDescription, privacy: .public) [ALR-RUN-DROP]")
            }
            // The stream closed without a terminal event (network, server dropped a slow subscriber): ask.
            do {
                let st = try await client.runStatus(runId)
                if st.isTerminal { applyTerminal(st, key); return }
            } catch let e as HermesError where e.status == 404 {
                gone(key); return
            } catch {
                if error.isCancellation || Task.isCancelled { throw CancellationError() }
            }
            try await sleepBackoff(backoff)
            backoff = min(backoff * 2, 30)
        }
    }

    /// No event stream to follow: poll the status until the run ends, surfacing a pending approval meanwhile.
    private func poll(_ key: String, client: HermesClient) async throws {
        var backoff = 2.0
        while let runId = run(key)?.runId {
            do {
                let st = try await client.runStatus(runId)
                if st.isTerminal { applyTerminal(st, key); reloadIfOpen(key); return }
                let sid = run(key)?.session, had = run(key)?.reply.approval
                if let a = st.pendingApprovals.first, let p = a.requestId, let sid, isYolo(sid), a.choices.contains("once"),
                   run(key)?.settled.contains(p) == false, run(key)?.yoloAnswered.contains(p) == false {
                    mutate(key) { $0.yoloAnswered.insert(p) }
                    autoApprove(a, entry: key)
                    backoff = 2
                    try await sleepBackoff(backoff)
                    continue
                }
                mutate(key) { r in
                    if st.isQueued == false { r.user.queued = false; r.reply.queued = false }
                    if let a = st.pendingApprovals.first, r.reply.approval == nil, !r.settled.contains(a.requestId ?? "") {
                        r.reply.approval = a
                    } else if st.pendingApprovals.isEmpty, r.reply.approval != nil, !r.reply.answeringApproval {
                        r.reply.approval = nil
                    }
                }
                if let a = run(key)?.reply.approval, a != had, let sid { app?.notifier.approvalRequested(a, session: sid, entry: key) }
                backoff = 2
            } catch let e as HermesError where e.status == 404 {
                gone(key); return
            } catch {
                if error.isCancellation || Task.isCancelled { throw CancellationError() }
                backoff = min(backoff * 2, 30)
            }
            try await sleepBackoff(backoff)
        }
    }

    /// Sleeps up to `seconds`, waking early when Cmd-R kicks.
    private func sleepBackoff(_ seconds: Double) async throws {
        let k = kick
        var left = seconds
        while left > 0, kick == k { try await Task.sleep(for: .milliseconds(250)); left -= 0.25 }
    }

    /// Hermes no longer knows the run (status expired, gateway restarted without a durable record): the stored
    /// history is all there is.
    private func gone(_ key: String) {
        runLog.info("run unknown to the server now; reloading history [ALR-RUN-GONE]")
        mutate(key) { if $0.reply.text.isEmpty && $0.reply.error == nil { $0.reply.error = "Lost track of this reply; showing what Hermes saved." } }
        reloadIfOpen(key)
    }

    /// Events were missed: when the run ends, show the stored history instead of the partial live reply.
    private func reloadIfOpen(_ key: String) { mutate(key) { $0.reloadHistory = true } }

    private func applyTerminal(_ st: RunStatus, _ key: String) {
        let e: ChatEvent
        switch st.status {
        case "completed": e = .completed(content: st.output ?? "")
        case "cancelled": e = .cancelled
        default: e = .failed(st.error ?? (st.status == "interrupted" ? "The gateway stopped before this reply finished" : "The run failed"))
        }
        handle(RunEvent(seq: nil, name: "status.\(st.status)", events: [e], isTerminal: true), key)
    }

    private func handle(_ ev: RunEvent, _ key: String) {
        guard let r = run(key) else { return }
        let sid = r.session
        mutate(key) { r in
            if let s = ev.seq { r.lastSeq = s }
            // Any real event means it left the queue.
            if r.queued, ev.name != "run.queued" { r.user.queued = false; r.reply.queued = false }
            if let p = ev.settledApproval {
                r.settled.insert(p)
                if r.reply.approval?.requestId == p { r.reply.approval = nil; r.reply.answeringApproval = false }
            }
        }
        if ev.settledApproval != nil, let a = r.reply.approval, a.requestId == ev.settledApproval { app?.notifier.approvalResolved(a) }
        for e in ev.events {
            if case .approval(let a) = e {
                if let p = a.requestId, run(key)?.settled.contains(p) == true { continue } // replayed, already answered
                if let sid, isYolo(sid), a.choices.contains("once") { autoApprove(a, entry: key); continue }
            }
            apply(e, to: key, session: sid)
            if case .approval(let a) = e, let sid { app?.notifier.approvalRequested(a, session: sid, entry: key) }
            r.onEvent?(e)
        }
    }

    private func apply(_ e: ChatEvent, to id: String, session: String?) {
        switch e {
        case .started: break // the run id comes from POST /v1/runs
        case .delta(let d): update(id) { $0.text += d }
        case .thinking(let t): update(id) { $0.thinking += ($0.thinking.isEmpty ? "" : "\n\n") + t }
        case .commentary(let t): update(id) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + t }
        case .toolStarted(let t): update(id) { e in if !e.tools.contains(where: { $0.id == t.id }) { e.tools.append(t) } }
        case .toolFinished(let tid, let failed):
            update(id) { e in if let i = e.tools.firstIndex(where: { $0.id == tid }) { e.tools[i].state = failed ? .failed : .done } }
        case .approval(let a): update(id) { $0.approval = a }
        case .completed(let content):
            update(id) {
                $0.approval = nil // it finished, so whatever the card asked was answered (no "expired" label)
                if MessageText.isInterruption(content) { $0.text = ""; $0.error = "Stopped" }
                else if !content.isEmpty { $0.text = content }
            }
        case .failed(let msg): update(id) { $0.error = Self.readable(msg) }
        case .cancelled: update(id) { $0.error = "Stopped" } // mark interrupted replies, with or without text (hermes-mac-d76)
        case .status: break
        case .runtime(let r): if let s = session { models.noteServed(r, session: s) }
        }
    }

    /// Updates an entry by id: a live run's reply goes through the run (so it survives a chat switch).
    private func update(_ id: String, _ f: (inout ChatEntry) -> Void) {
        if live.contains(where: { $0.reply.id == id }) { mutate(id) { f(&$0.reply) }; return }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        f(&entries[i])
    }

    /// The run is over: settle its entry, tell the notifier and caller, forget it, refresh titles.
    private func finish(_ key: String, failure: Error?) async {
        guard let r = run(key) else { return }
        // A run can't wait on an approval once it has ended: Hermes timed it out (or the run stopped).
        if let a = r.reply.approval {
            mutate(key) { $0.reply.approval = nil; $0.reply.expiredApproval = a.command ?? a.description ?? "a command" }
            app?.notifier.approvalResolved(a)
        }
        mutate(key) { $0.reply.streaming = false; $0.reply.queued = false; $0.user.queued = false }
        if r.withdrawn { entries.removeAll { $0.id == r.user.id || $0.id == r.reply.id } }
        if let sid = r.session, !r.withdrawn { app?.notifier.replyEnded(session: sid, entry: key, cancelled: false) }
        live.removeAll { $0.id == key }
        liveTasks[key] = nil
        unpersist(r)
        if r.reloadHistory, let sid = r.session, selection == sid, !live.contains(where: { $0.session == sid }) {
            loadedFor = nil; select(sid)
        }
        runLog.info("run \(r.runId ?? "-", privacy: .public) ended [ALR-RUN-END]")
        r.onFinish?(failure)
        // The next queued turn in this chat starts now; its first event can take a while (a thinking model).
        if let client, let next = live.first(where: { $0.session == r.session && $0.queued }), let nid = next.runId {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let st = try? await client.runStatus(nid), !st.isQueued { mutate(next.id) { $0.user.queued = false; $0.reply.queued = false } }
            }
        }
        await reload() // titles are generated server-side after the first turn...
        // ...a few seconds later, so look again (hermes-mac-5xc).
        for delay in [4, 12] {
            try? await Task.sleep(for: .seconds(delay))
            if !live.contains(where: { $0.session == r.session }) { await reload() }
        }
    }

    func stop() {
        guard let client, let r = currentRun else { return }
        let key = r.id
        if let id = r.runId { app?.run("Stop") { try await client.stopRun(id) } }
        // Give the server a moment to emit run.cancelled; then let go of THIS run regardless.
        Task {
            try? await Task.sleep(for: .seconds(r.runId == nil ? 0 : 5))
            guard run(key) != nil else { return }
            runLog.info("stop: no run.cancelled in time; letting go [ALR-RUN-STOP-LOCAL]")
            // Still posting (no run id): leave drive running so it can stop the server run once it gets the id.
            if run(key)?.runId != nil { liveTasks[key]?.cancel() }
            mutate(key) { if $0.reply.error == nil { $0.reply.error = "Stopped" } }
            await finish(key, failure: nil)
        }
    }

    /// Cancels a message still waiting in the queue (its "Queued" badge).
    func cancelQueued(entry userEntryID: String) {
        guard let client, let r = live.first(where: { $0.user.id == userEntryID }), r.queued else { return }
        mutate(r.id) { $0.withdrawn = true }
        if let id = r.runId { app?.run("Cancel") { try await client.stopRun(id) } }
        else { Task { await finish(r.id, failure: nil) } } // drive stops the server run once POST /v1/runs returns
    }

    // MARK: persistence + scope

    private var registryKey: String { "chats.activeRuns" + ConnectionSettings.scope + (client?.profile.map { ".\($0)" } ?? "") }

    private func persist(_ key: String) {
        guard let r = run(key), let runId = r.runId, let sid = r.session else { return }
        var reg = RunRegistry(data: UserDefaults.standard.data(forKey: r.registryKey))
        reg.upsert(PersistedRun(runId: runId, session: sid, createdAt: r.createdAt, text: r.user.text, queued: r.queued))
        UserDefaults.standard.set(reg.data, forKey: r.registryKey)
    }

    private func unpersist(_ r: LiveRun) {
        guard let runId = r.runId else { return }
        var reg = RunRegistry(data: UserDefaults.standard.data(forKey: r.registryKey))
        reg.remove(runId)
        UserDefaults.standard.set(reg.data, forKey: r.registryKey)
    }

    /// Called on every list reload: when the server or profile changed, stop following the old one's runs
    /// (they go on server-side and stay persisted under their own key) and pick up this one's.
    // AIDEV-NOTE: must run synchronously on a profile/server change BEFORE anything starts a run there; if a
    // deferred reload() does it later, detachAll() kills the run just started in the new scope (dev-40 review #1).
    func syncScope() {
        let key = registryKey
        guard key != attachedKey else { return }
        attachedKey = key
        detachAll()
        resumePersisted()
    }

    private func detachAll() {
        for t in liveTasks.values { t.cancel() }
        liveTasks = [:]
        if !live.isEmpty { runLog.info("detached \(self.live.count) run(s) on scope change [ALR-RUN-DETACH]") }
        live = []
    }

    /// Re-attaches to runs persisted for this server + profile (app relaunch): running ones are followed again
    /// (replayed from the start into a fresh reply), finished or unknown ones are dropped.
    private func resumePersisted() {
        guard let client else { return }
        let key = registryKey
        var reg = RunRegistry(data: UserDefaults.standard.data(forKey: key))
        reg.prune()
        UserDefaults.standard.set(reg.data, forKey: key)
        for p in reg.runs where !live.contains(where: { $0.runId == p.runId }) {
            Task {
                let st: RunStatus
                do { st = try await client.runStatus(p.runId) } catch {
                    if let e = error as? HermesError, e.status == 404 { dropPersisted(p, key: key) }
                    else { runLog.info("resume check failed for \(p.runId, privacy: .public): \(error.localizedDescription, privacy: .public) [ALR-RUN-RESUME-ERR]") }
                    return
                }
                guard registryKey == key, !live.contains(where: { $0.runId == p.runId }) else { return }
                // It may have been resumed and finished (unpersisted) by another pass while this check was in flight.
                guard RunRegistry(data: UserDefaults.standard.data(forKey: key)).runs.contains(where: { $0.runId == p.runId }) else { return }
                guard !st.isTerminal else { dropPersisted(p, key: key); return }
                let user = ChatEntry(id: UUID().uuidString, role: .user, text: p.text, date: nil, queued: st.isQueued)
                let reply = ChatEntry(id: UUID().uuidString, role: .assistant, text: "", streaming: true, date: nil, queued: st.isQueued)
                live.append(LiveRun(id: reply.id, session: p.session, blankGen: -1, registryKey: key, runId: p.runId,
                                    createdAt: st.createdAt ?? p.createdAt, user: user, reply: reply))
                runLog.info("resumed run \(p.runId, privacy: .public) (\(st.status, privacy: .public)) [ALR-RUN-RESUME]")
                if selection == p.session { loadedFor = nil; select(p.session) } // re-cut history around it
                let rk = reply.id
                liveTasks[rk] = Task {
                    do { try await follow(rk, client: client) } catch { return } // cancelled = detached
                    await finish(rk, failure: nil)
                }
            }
        }
    }

    /// A persisted run that already ended (or Hermes forgot): forget it; if its chat is open, show what was saved.
    private func dropPersisted(_ p: PersistedRun, key: String) {
        var reg = RunRegistry(data: UserDefaults.standard.data(forKey: key))
        reg.remove(p.runId)
        UserDefaults.standard.set(reg.data, forKey: key)
        if selection == p.session, registryKey == key { loadedFor = nil; select(p.session) }
    }

    /// The card stays up (buttons disabled) until Hermes accepts the answer; on failure it comes back so the
    /// run is never left blocked with no way to answer (hermes-mac-1ll).
    func answer(_ a: ApprovalRequest, _ choice: String, entry: String) {
        guard let client else { return }
        update(entry) { $0.answeringApproval = true }
        Task {
            do {
                try await client.answerApproval(a, choice: choice)
                update(entry) { if $0.approval == a { $0.approval = nil }; $0.answeringApproval = false }
                app?.notifier.approvalResolved(a)
            } catch {
                update(entry) { $0.answeringApproval = false }
                app?.flash("Approval wasn't sent: \(error.localizedDescription). Try again.")
            }
        }
    }

    // MARK: YOLO (per chat, client-side)

    // AIDEV-NOTE: security. Hermes can't do per-chat YOLO for API-server chats: each turn's approval key is its
    // run_id and the session row's yolo flag (set via /api/ws config.set) is never read on that path (investigated
    // 2026-11-22, hermes-mac-1pt). So the app answers "once" itself, only for streams it is watching, and logs each.
    /// YOLO for the chat that isn't created yet; applied when its session is.
    var yoloNewChat = false
    private var yoloVersion = 0 // UserDefaults isn't observed; bump to refresh views
    private var yoloKey: String { "chats.yolo" + ConnectionSettings.scope + (client?.profile.map { ".\($0)" } ?? "") }

    func isYolo(_ sid: String?) -> Bool {
        _ = yoloVersion
        guard let sid else { return yoloNewChat }
        return (UserDefaults.standard.stringArray(forKey: yoloKey) ?? []).contains(sid)
    }

    func setYolo(_ on: Bool, for sid: String?) {
        guard let sid else { yoloNewChat = on; return }
        var ids = (UserDefaults.standard.stringArray(forKey: yoloKey) ?? []).filter { $0 != sid }
        if on { ids.insert(sid, at: 0) }
        UserDefaults.standard.set(Array(ids.prefix(500)), forKey: yoloKey)
        yoloVersion += 1
    }

    private func autoApprove(_ a: ApprovalRequest, entry: String) {
        guard let client else { return }
        let what = a.command ?? a.description ?? "a command"
        Task {
            do {
                try await client.answerApproval(a, choice: "once")
                update(entry) { $0.autoApproved.append(what) }
            } catch {
                // A replayed request (re-attach after relaunch) may already be settled: nothing to ask then.
                if let p = a.requestId, live.first(where: { $0.id == entry })?.settled.contains(p) == true { return }
                // Fall back to asking, so the run is never left blocked.
                update(entry) { $0.approval = a }
                app?.flash("YOLO couldn't auto-approve: \(error.localizedDescription). Answer it in the chat.")
            }
        }
    }

    // MARK: session management

    func rename(_ s: HermesSession, to title: String) {
        guard let client else { return }
        app?.run("Rename") { _ = try await client.updateSession(s.id, title: title); await self.reload() }
    }

    func togglePin(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Pin") { _ = try await client.updateSession(s.id, pinned: !(s.pinned ?? false)); await self.reload() }
    }

    // AIDEV-NOTE: GET /api/sessions can't include archived chats (no include_archived), so the app remembers what it
    // archived to offer an Archived section + Unarchive (hermes-mac-d2w). Chats archived elsewhere stay invisible.
    var archived: [HermesSession] = []
    // Per profile: another profile's ids 404 here, and loadArchived would forget them as "gone".
    private var archivedKey: String { "chats.archivedIDs" + ConnectionSettings.scope + (client?.profile.map { ".\($0)" } ?? "") }
    private var archivedIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: archivedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: archivedKey) }
    }
    /// Set to a session id to have the list scroll to it (new or duplicated chats can sort off-screen).
    var scrollTarget: String?

    func archive(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Archive") {
            _ = try await client.updateSession(s.id, archived: true)
            self.archivedIDs = [s.id] + self.archivedIDs.filter { $0 != s.id }
            if self.selection == s.id { self.newChat() }
            await self.reload()
            await self.loadArchived()
            self.app?.flash("Archived “\(s.displayTitle)”")
        }
    }

    func unarchive(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Unarchive") {
            _ = try await client.updateSession(s.id, archived: false)
            self.archivedIDs.removeAll { $0 == s.id }
            await self.reload()
            await self.loadArchived()
            self.select(s.id); self.scrollTarget = s.id
        }
    }

    func loadArchived() async {
        guard let client else { return }
        // The list endpoint may return archived sessions (flagged) - use those, then fetch remembered ids it omits.
        var found = sessions.filter { $0.archived == true }, gone: [String] = []
        for id in archivedIDs.prefix(50) where !found.contains(where: { $0.id == id }) {
            do {
                let s = try await client.session(id)
                if s.archived == true { found.append(s) } else { gone.append(id) } // unarchived elsewhere
            } catch let e as HermesError where e.status == 404 { gone.append(id) }
            catch { app?.report("Couldn't load archived chats", error); break }
        }
        if !gone.isEmpty { archivedIDs.removeAll { gone.contains($0) } }
        archived = found
    }

    func delete(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Delete") {
            try await client.deleteSession(s.id)
            if self.selection == s.id { self.newChat() }
            self.sessions.removeAll { $0.id == s.id }
        }
    }

    func fork(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Duplicate") {
            let n = try await client.forkSession(s.id, title: "\(s.displayTitle) (copy)")
            await self.reload()
            self.select(n.id)
            self.scrollTarget = n.id // the copy keeps the original's dates, so it may sort off-screen (hermes-mac-vcc)
            self.app?.flash("Duplicated as “\(n.displayTitle)”")
        }
    }

    func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let client, client.hasDashboard else { searchHits = []; return }
        do { searchHits = try await client.search(q) }
        catch { searchHits = []; app?.report("Search failed", error) } // not "no matches" (hermes-mac-z8z)
    }

    /// Hermes reports run failures as bare codes ("permission_denied"); turn known ones into a sentence,
    /// and at least de-snake unknown ones. The raw code is kept in parentheses for bug reports.
    static func readable(_ msg: String) -> String {
        let known = [
            "permission_denied": "Hermes refused to run this turn",
            "invalid_params": "Hermes rejected the request",
            "busy": "Hermes is busy with another turn",
            "admission_closed": "Hermes is shutting down",
        ]
        guard !msg.contains(" ") else { return msg }
        let text = known[msg] ?? msg.replacingOccurrences(of: "_", with: " ").capitalized
        return "\(text) (\(msg))"
    }
}
