import Foundation
import HermesKit

/// How an `@profile` mention in the composer is routed.
///
/// Hermes keeps each session in ONE profile's state.db, and a turn always runs in the profile that owns the
/// session, so a turn can't be sent to another profile inside an existing chat. The rule instead:
///  - `@name` naming the profile you're in: sent as usual (the mention is just text).
///  - `@name` naming another profile: the app switches to that profile and starts a NEW chat there with the
///    message (the composer says so before you press Return). The text is sent verbatim, mention included.
enum MentionRoute: Equatable {
    case none
    case here(String)                         // mention of the current profile
    case newChat(String, fromChat: Bool)      // switch + new chat; fromChat = leaving an open conversation
    case unavailable(String)                  // installed but not served by this gateway
}

extension ProfileStore {
    func route(for text: String, inChat: Bool) -> MentionRoute {
        guard isMulti, let m = ProfileMention.find(in: text, profiles: profiles.map(\.name)) else { return .none }
        if m.profile == current { return .here(m.profile) }
        if !isServed(m.profile) { return .unavailable(m.profile) }
        return .newChat(m.profile, fromChat: inChat)
    }
}

extension ChatStore {
    /// Composer entry point: honours an @profile mention (see MentionRoute), otherwise a plain send().
    func sendRouted(_ raw: String, attachments atts: [Attachment] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app, !text.isEmpty || !atts.isEmpty, !isStreaming else { return }
        // Attachments travel with the message, including into a new chat in another profile.
        func deliver() { if send(text, attachments: atts) { self.attachments.clear() } }
        let profiles = app.profiles
        switch profiles.route(for: text, inChat: selection != nil) {
        case .none, .here: deliver()
        case .unavailable(let name): app.flash(profiles.notServedMessage(name))
        case .newChat(let name, _):
            profiles.pendingMessage = text // delivered by retryAfterKey if the profile first needs a key
            Task {
                guard await profiles.switchTo(name) else { // draft stays put on failure
                    if profiles.keyPrompt != name { profiles.pendingMessage = nil } // only the key sheet resumes it
                    return
                }
                guard profiles.pendingMessage == text else { return }
                profiles.pendingMessage = nil
                deliver()
                app.flash("New chat in \(profiles.label(name))")
            }
        }
    }
}
