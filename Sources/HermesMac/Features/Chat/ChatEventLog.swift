import Foundation

/// A setting change in a chat (YOLO, model, rename), shown in the transcript as a one-line marker so there's a
/// record of when it happened (user: "it should be logged physically like a chat message").
// AIDEV-NOTE: client-side only. Hermes has no per-session event log for these, so they live in UserDefaults per
// server + profile and are merged into history by date on load. Other clients won't see them.
struct ChatLogEvent: Codable, Equatable {
    var id: String
    var date: Date
    var text: String
    var symbol: String

    var entry: ChatEntry { ChatEntry(id: "ev-\(id)", role: .system, text: text, date: date, symbol: symbol) }
}

/// Pure storage: events per session id, capped so UserDefaults stays small.
struct ChatEventStore: Codable {
    static let perChat = 50, chats = 300
    var bySession: [String: [ChatLogEvent]] = [:]
    var order: [String] = [] // most recently touched first, for the cap

    init(data: Data?) { if let data, let s = try? JSONDecoder().decode(Self.self, from: data) { self = s } }
    init() {}
    var data: Data? { try? JSONEncoder().encode(self) }

    mutating func add(_ e: ChatLogEvent, to sid: String) {
        bySession[sid, default: []].append(e)
        if bySession[sid]!.count > Self.perChat { bySession[sid]!.removeFirst(bySession[sid]!.count - Self.perChat) }
        order.removeAll { $0 == sid }; order.insert(sid, at: 0)
        while order.count > Self.chats { bySession[order.removeLast()] = nil }
    }

    mutating func remove(_ sid: String) { bySession[sid] = nil; order.removeAll { $0 == sid } }

    /// History plus this chat's events, in time order (events with the same date go after the message).
    static func merge(_ history: [ChatEntry], _ events: [ChatLogEvent]) -> [ChatEntry] {
        guard !events.isEmpty else { return history }
        var out: [ChatEntry] = [], pending = events.sorted { $0.date < $1.date }
        for h in history {
            if let d = h.date { while let e = pending.first, e.date < d { out.append(e.entry); pending.removeFirst() } }
            out.append(h)
        }
        return out + pending.map(\.entry)
    }
}

extension ChatStore {
    private var eventsKey: String { "chats.events" + ConnectionSettings.scope + (client?.profile.map { ".\($0)" } ?? "") }

    /// Shows the event in the open chat now and saves it with the chat (or with the blank chat until it's created).
    func logEvent(_ text: String, symbol: String, session sid: String?) {
        let e = ChatLogEvent(id: UUID().uuidString, date: .now, text: text, symbol: symbol)
        if sid == selection { entries.append(e.entry) }
        guard let sid else { pendingEvents.append(e); return }
        var store = ChatEventStore(data: UserDefaults.standard.data(forKey: eventsKey))
        store.add(e, to: sid)
        UserDefaults.standard.set(store.data, forKey: eventsKey)
    }

    func adoptPendingEvents(for sid: String) {
        guard !pendingEvents.isEmpty else { return }
        var store = ChatEventStore(data: UserDefaults.standard.data(forKey: eventsKey))
        for e in pendingEvents { store.add(e, to: sid) }
        UserDefaults.standard.set(store.data, forKey: eventsKey)
        pendingEvents = []
    }

    /// A deleted chat takes its events (a renamed title, among others) and its model choice with it.
    func forgetEvents(session sid: String) {
        var store = ChatEventStore(data: UserDefaults.standard.data(forKey: eventsKey))
        guard store.bySession[sid] != nil else { return }
        store.remove(sid)
        UserDefaults.standard.set(store.data, forKey: eventsKey)
    }

    func mergeEvents(_ history: [ChatEntry], session sid: String) -> [ChatEntry] {
        ChatEventStore.merge(history, ChatEventStore(data: UserDefaults.standard.data(forKey: eventsKey)).bySession[sid] ?? [])
    }
}

/// Per-server/per-profile chat data kept on this Mac, outside Hermes. Key = base + server scope + ".<profile>".
// AIDEV-NOTE: privacy. Removing a server or deleting a profile must purge these (dev-40 found renamed titles
// surviving deletes; iOS talaria-ios c344ab1). Add any new per-scope chat key to `bases`.
enum ChatLocalData {
    static let bases = ["chats.events", "chats.modelChoices", "chats.activeRuns"]

    /// Server scope for a server id ("" for the default server, as ConnectionSettings.scope).
    static func scope(forServer id: String) -> String { id == "default" ? "" : ".srv.\(id)" }

    /// True when `key` holds data of that server (every profile), or of one profile when `profile` is set.
    static func belongs(_ key: String, scope: String, profile: String?) -> Bool {
        bases.contains { base in
            if let profile { return key == base + scope + ".\(profile)" }
            guard key.hasPrefix(base + scope) else { return false }
            let rest = key.dropFirst(base.count + scope.count)
            // The default server's scope is "": its prefix also matches other servers' ".srv.…" keys.
            return rest.isEmpty || (rest.hasPrefix(".") && !(scope.isEmpty && rest.hasPrefix(".srv.")))
        }
    }

    static func purge(scope: String, profile: String? = nil, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where belongs(key, scope: scope, profile: profile) {
            defaults.removeObject(forKey: key)
        }
    }
}
