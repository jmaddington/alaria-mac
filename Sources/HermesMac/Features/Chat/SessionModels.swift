import Foundation
import HermesKit
import Observation
import OSLog
import SwiftUI

private let modelLog = Logger(subsystem: "net.jmaddington.hermes", category: "model")

/// Per-chat model state (bead hermes-mac-ptp). Owned by ChatStore as `chats.models`.
///
/// The server keeps the truth (a session model lock, see HermesKit/API/SessionModel.swift) but never returns the
/// lock's reasoning/fast options, so the app remembers the full choice it locked per session (UserDefaults, per
/// server + profile) and resends it whole on every change.
// AIDEV-NOTE: a chat locked elsewhere (another client, or before this app remembered choices) shows session.model with
// unknown options; changing its model then resets reasoning/fast to defaults. Unavoidable without a read endpoint.
@MainActor @Observable
final class SessionModels {
    private(set) var catalog: ModelCatalog?
    private(set) var loadError: String?
    private(set) var loading = false
    /// The model a not-yet-created chat (selection == nil) will be created with; nil = server default.
    var pending: ModelChoice?
    /// What actually served each session's last turn (assistant.completed runtime).
    private(set) var served: [String: SessionRuntime] = [:]
    /// Session ids with a lock request in flight (the menu shows a spinner).
    private(set) var switching: Set<String> = []
    private var chosen: [String: ModelChoice] = [:]
    private var loadedFor: ObjectIdentifier?
    private var storeKey = ""

    /// The global default as a choice (what an unlocked chat runs on).
    var defaultChoice: ModelChoice? {
        guard let m = catalog?.model, !m.isEmpty else { return nil }
        return ModelChoice(provider: catalog?.provider, model: m)
    }

    func load(_ client: HermesClient?, force: Bool = false) async {
        guard let client else { catalog = nil; return }
        let id = ObjectIdentifier(client)
        guard force || loadedFor != id || catalog == nil else { return }
        if loadedFor != id { // another server/profile: its sessions and default model differ
            storeKey = "chats.modelChoices" + ConnectionSettings.scope + (client.profile.map { ".\($0)" } ?? "")
            chosen = Self.restore(storeKey)
            served = [:]
            pending = nil
        }
        loadedFor = id
        loading = true
        defer { loading = false }
        do {
            catalog = try await client.modelCatalog()
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.localizedDescription
            modelLog.error("model catalog load failed: \(error.localizedDescription, privacy: .public) [ALR-MODEL-CATALOG]")
        }
    }

    /// The choice in effect for a session (nil id = the new chat being composed). `isDefault` = no lock known.
    func current(for session: HermesSession?) -> (choice: ModelChoice?, isDefault: Bool) {
        guard let s = session else { return pending.map { ($0, false) } ?? (defaultChoice, true) }
        if let c = chosen[s.id] { return (c, false) }
        if let m = s.model, !m.isEmpty {
            return (ModelChoice(provider: served[s.id]?.provider ?? catalog?.provider(for: m), model: m), false)
        }
        if let r = served[s.id], let m = r.model { return (ModelChoice(provider: r.provider, model: m), false) }
        return (defaultChoice, true)
    }

    func noteServed(_ r: SessionRuntime, session: String) { served[session] = r }

    /// After a new chat was created with `pending`, remember it as that session's choice.
    func adoptPending(for session: String) {
        guard let p = pending else { return }
        remember(p, for: session)
        pending = nil
    }

    fileprivate func remember(_ c: ModelChoice, for session: String) {
        chosen[session] = c
        // Bound the store; order doesn't matter much, so drop arbitrary extras.
        if chosen.count > 300 { for k in chosen.keys.prefix(chosen.count - 300) where k != session { chosen[k] = nil } }
        if let d = try? JSONEncoder().encode(chosen) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
    fileprivate func setSwitching(_ id: String, _ on: Bool) { if on { switching.insert(id) } else { switching.remove(id) } }

    private static func restore(_ key: String) -> [String: ModelChoice] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ModelChoice].self, from: d)) ?? [:]
    }
}

extension ChatStore {
    /// The choice in effect for the selected chat (or the new chat being composed).
    var currentModel: (choice: ModelChoice?, isDefault: Bool) { models.current(for: selectedSession) }

    /// Locks the selected chat to `choice` via POST /api/sessions/{id}/model; for a new chat, remembers it for creation.
    func setModel(_ choice: ModelChoice) {
        guard let client else { return }
        guard let s = selectedSession else {
            models.pending = choice
            app?.flash("New chat will use \(choice.label)")
            return
        }
        let wasStreaming = isStreaming
        models.setSwitching(s.id, true)
        Task {
            defer { models.setSwitching(s.id, false) }
            do {
                let rt = try await client.lockSessionModel(s.id, choice)
                models.remember(choice, for: s.id)
                if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i].model = rt.model ?? choice.model }
                modelLog.info("locked \(s.id, privacy: .public) to \(choice.model, privacy: .public) [ALR-MODEL1]")
                app?.flash(wasStreaming ? "\(choice.label) from the next message" : "This chat now uses \(choice.label)")
            } catch {
                modelLog.error("model lock failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public) [ALR-MODEL-ERR]")
                app?.report("Couldn't switch model", error)
            }
        }
    }

    /// Changes only reasoning effort / fast mode, keeping the chat's model.
    func setModelOptions(effort: String?? = .none, fast: Bool? = nil) {
        guard var c = currentModel.choice else { app?.flash("No model is configured on this server yet"); return }
        if case .some(let e) = effort { c.reasoningEffort = e }
        if let fast { c.fast = fast }
        setModel(c)
    }
}

// MARK: - Toolbar menu

/// The chat's model in the window toolbar; picking one locks it for this chat (not the global default).
struct ChatModelMenu: View {
    @Environment(AppModel.self) private var model
    private var chats: ChatStore { model.chats }

    var body: some View {
        let ms = chats.models
        let (choice, isDefault) = chats.currentModel
        Menu {
            if let err = ms.loadError, ms.catalog == nil {
                Text("Couldn't load models: \(err)")
                Button("Try Again") { Task { await ms.load(model.client, force: true) } }
            } else if let cat = ms.catalog {
                ForEach(cat.usable) { p in
                    SwiftUI.Section(p.name ?? p.slug) {
                        ForEach(p.modelIDs, id: \.self) { id in
                            Button { pick(provider: p.slug, model: id, keeping: choice) } label: {
                                if choice?.model == id && (choice?.provider == nil || choice?.provider == p.slug) { Image(systemName: "checkmark") }
                                Text(id)
                            }
                        }
                    }
                }
                if cat.usable.isEmpty { Text("No models available. Set up a provider in Hermes.") }
                Divider()
                Menu("Reasoning Effort") {
                    effortButton(nil, "Default", current: choice?.reasoningEffort)
                    ForEach(ModelChoice.efforts, id: \.self) { effortButton($0, $0 == "none" ? "Off" : $0.capitalized, current: choice?.reasoningEffort) }
                }
                .disabled(choice == nil)
                Toggle("Fast Mode", isOn: Binding(get: { choice?.fast ?? false }, set: { chats.setModelOptions(fast: $0) }))
                    .disabled(choice == nil)
                if let d = ms.defaultChoice {
                    Divider()
                    Button("Use Default (\(ModelChoice.shortName(d.model)))") { pick(provider: d.provider, model: d.model, keeping: nil) }
                }
            } else {
                Text("Loading models…")
            }
        } label: {
            HStack(spacing: 5) {
                if let id = chats.selection, ms.switching.contains(id) { ProgressView().controlSize(.mini) }
                else { Image(systemName: "cpu") }
                Text(choice?.label ?? "Model").lineLimit(1)
            }
        }
        .help(help(choice, isDefault))
        .accessibilityLabel("Model: \(choice?.label ?? "unknown")")
        .task(id: model.client.map(ObjectIdentifier.init)) { await ms.load(model.client) }
    }

    @ViewBuilder private func effortButton(_ e: String?, _ title: String, current: String?) -> some View {
        Button { chats.setModelOptions(effort: .some(e)) } label: {
            if current == e { Image(systemName: "checkmark") }
            Text(title)
        }
    }

    /// A new model keeps the chat's reasoning/fast options (the lock replaces them wholesale otherwise).
    private func pick(provider: String?, model id: String, keeping c: ModelChoice?) {
        chats.setModel(ModelChoice(provider: provider, model: id, reasoningEffort: c?.reasoningEffort, fast: c?.fast ?? false))
    }

    private func help(_ c: ModelChoice?, _ isDefault: Bool) -> String {
        guard let c else { return "Choose the model for this chat" }
        let who = chats.selection == nil ? "New chat" : "This chat"
        return "\(who) uses \(c.model)\(c.provider.map { " (\($0))" } ?? "")\(isDefault ? ", the server default" : ""). Type /model to switch."
    }
}
