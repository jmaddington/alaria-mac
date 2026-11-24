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

    func mergeEvents(_ history: [ChatEntry], session sid: String) -> [ChatEntry] {
        ChatEventStore.merge(history, ChatEventStore(data: UserDefaults.standard.data(forKey: eventsKey)).bySession[sid] ?? [])
    }
}
