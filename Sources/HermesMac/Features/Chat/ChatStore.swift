import Foundation
import HermesKit
import Observation

/// One rendered item in a conversation.
struct ChatEntry: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, system }
    let id: String
    var role: Role
    var text: String
    var thinking: String = ""
    var tools: [ToolActivity] = []
    var approval: ApprovalRequest?
    var streaming = false
    var error: String?
    var date: Date?
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
    var runId: String?
    var isStreaming: Bool { streamTask != nil }
    var searchText = ""
    var searchHits: [SearchHit] = []

    private var streamTask: Task<Void, Never>?
    private var loadedFor: String?

    var client: HermesClient? { app?.client }
    var selectedSession: HermesSession? { sessions.first { $0.id == selection } }

    func reload() async {
        guard let client else { return }
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

    func select(_ id: String?) {
        guard id != loadedFor else { return }
        if isStreaming, id != selection { cancelStream() }
        selection = id
        loadedFor = id
        entries = []
        guard let id, let client else { return }
        loadingMessages = true
        Task {
            defer { loadingMessages = false }
            do {
                let msgs = try await client.messages(id)
                guard selection == id else { return }
                entries = Self.entries(from: msgs)
            } catch {
                app?.flash("Couldn't load messages: \(error.localizedDescription)")
            }
        }
    }

    /// Folds Hermes' stored messages (user / assistant / tool rows) into display entries:
    /// tool rows attach to the preceding assistant turn as finished tool chips.
    static func entries(from msgs: [HermesMessage]) -> [ChatEntry] {
        var out: [ChatEntry] = []
        for m in msgs {
            let date = m.timestamp.map { Date(timeIntervalSince1970: $0) }
            switch m.role {
            case "user":
                out.append(ChatEntry(id: "m\(m.id)", role: .user, text: m.content ?? "", date: date))
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
                } else if !text.isEmpty || !tools.isEmpty {
                    out.append(ChatEntry(id: "m\(m.id)", role: .assistant, text: text, thinking: m.thinking ?? "", tools: tools, date: date))
                }
            default:
                continue // tool results and system rows are summarized by the chips above
            }
        }
        return out
    }

    func newChat() {
        cancelStream()
        selection = nil
        loadedFor = nil
        entries = []
        draft = ""
    }

    /// Sends a message, creating a session first if needed. `onEvent` lets voice mode tap the stream.
    func send(_ text: String, onEvent: ((ChatEvent) -> Void)? = nil, onFinish: ((Error?) -> Void)? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client, !isStreaming else { return }
        draft = ""
        entries.append(ChatEntry(id: UUID().uuidString, role: .user, text: text, date: .now))
        let replyID = UUID().uuidString
        entries.append(ChatEntry(id: replyID, role: .assistant, text: "", streaming: true, date: .now))

        streamTask = Task {
            var failure: Error?
            do {
                let sid: String
                if let s = selection { sid = s } else {
                    let s = try await client.createSession(title: nil)
                    sid = s.id
                    selection = sid
                    loadedFor = sid
                    sessions.insert(s, at: 0)
                }
                for try await e in client.chatStream(session: sid, message: text) {
                    apply(e, to: replyID)
                    onEvent?(e)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failure = error; update(replyID) { $0.error = error.localizedDescription } }
            }
            update(replyID) { $0.streaming = false }
            streamTask = nil
            runId = nil
            onFinish?(failure)
            await reload() // titles are generated server-side after the first turn
        }
    }

    private func apply(_ e: ChatEvent, to id: String) {
        switch e {
        case .started(let r, _): runId = r
        case .delta(let d): update(id) { $0.text += d }
        case .thinking(let t): update(id) { $0.thinking += t }
        case .commentary(let t): update(id) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + t }
        case .toolStarted(let t): update(id) { $0.tools.append(t) }
        case .toolFinished(let tid, let failed):
            update(id) { e in if let i = e.tools.firstIndex(where: { $0.id == tid }) { e.tools[i].state = failed ? .failed : .done } }
        case .approval(let a): update(id) { $0.approval = a }
        case .completed(let content): update(id) { if !content.isEmpty { $0.text = content } }
        case .failed(let msg): update(id) { $0.error = msg }
        case .cancelled: update(id) { $0.error = $0.text.isEmpty ? "Stopped" : nil }
        case .status: break
        }
    }

    private func update(_ id: String, _ f: (inout ChatEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        f(&entries[i])
    }

    func stop() {
        guard let client else { return }
        if let r = runId { app?.run("Stop") { try await client.stopRun(r) } }
        // Give the server a moment to emit run.cancelled; then drop the stream regardless.
        Task { try? await Task.sleep(for: .seconds(2)); cancelStream() }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        runId = nil
    }

    func answer(_ a: ApprovalRequest, _ choice: String, entry: String) {
        guard let client else { return }
        update(entry) { $0.approval = nil }
        app?.run("Approval") { try await client.answerApproval(a, choice: choice) }
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

    func archive(_ s: HermesSession) {
        guard let client else { return }
        app?.run("Archive") {
            _ = try await client.updateSession(s.id, archived: true)
            if self.selection == s.id { self.newChat() }
            await self.reload()
        }
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
        }
    }

    func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let client, client.hasDashboard else { searchHits = []; return }
        do { searchHits = try await client.search(q) } catch { searchHits = [] }
    }
}
