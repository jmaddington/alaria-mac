import Foundation
import HermesKit
import Observation
import os
import Security

private let profileLog = Logger(subsystem: "net.jmaddington.hermes", category: "profiles")

/// Which Hermes profile the app is looking at, and everything needed to reach it.
///
/// A profile is a separate HERMES_HOME (own model, skills, memory, jobs and sessions). Switching re-scopes
/// `AppModel.client` (HermesClient.scoped) and reloads every pane; the server's sticky "active profile" is never
/// touched. Named profiles authenticate at /p/<name>/ with their OWN API_SERVER_KEY, kept per profile in the
/// Keychain ("apiKey.profile.<name>"); the gateway's own profile keeps using the main key, unprefixed.
// AIDEV-NOTE: `selected == nil` means the gateway's own profile; keep that path byte-identical to pre-profile builds.
@MainActor @Observable
final class ProfileStore {
    weak var app: AppModel?

    private(set) var profiles: [HermesProfile] = []
    /// The dashboard's (and, normally, the gateway's) own profile: reached without a /p/ prefix.
    private(set) var own = "default"
    /// Profiles the gateway answers for at /p/<name>/; nil when the server doesn't report it.
    private(set) var served: Set<String>?
    /// Remembered choice; nil = the gateway's own profile.
    private(set) var selected: String? = UserDefaults.standard.string(forKey: "profile.selected" + ConnectionSettings.scope)
    /// Profile being switched to (spinner in the switcher).
    private(set) var switching: String?
    /// A profile that answered 401: drives the "needs its own key" sheet.
    var keyPrompt: String?
    /// A message whose @mention is waiting on keyPrompt; sent once that profile is reachable.
    var pendingMessage: String?

    var current: String { selected ?? own }
    var currentProfile: HermesProfile? { profiles.first { $0.name == current } }
    /// More than one profile installed: worth showing profile chrome (badges, subtitles).
    var isMulti: Bool { profiles.count > 1 }

    func label(_ name: String) -> String { profiles.first { $0.name == name }?.label ?? name }
    func isServed(_ name: String) -> Bool { name == own || (served?.contains(name) ?? true) }

    // MARK: keys

    /// Per server: the default server keeps the original account names.
    static func keyAccount(_ name: String, scope: String = ConnectionSettings.scope) -> String { "apiKey.profile.\(name)" + scope }
    func storedKey(_ name: String) -> String? { Keychain.get(Self.keyAccount(name)).flatMap { $0.isEmpty ? nil : $0 } }

    /// The client for `name`, derived from any client on the same servers.
    func client(for name: String, from base: HermesClient) -> HermesClient {
        name == own ? base.scoped(to: nil) : base.scoped(to: name, apiKey: storedKey(name))
    }

    /// AppModel.connect() hook: scope a fresh connection to the remembered profile.
    func scope(_ base: HermesClient) -> HermesClient {
        guard let s = selected, s != own else { return base.scoped(to: nil) }
        return client(for: s, from: base)
    }

    // MARK: loading

    /// Lists profiles (needs the dashboard). A remembered profile that no longer exists, or that the gateway no
    /// longer serves, falls back to the gateway's own so the app never sits on a dead route.
    func load() async {
        guard let c = app?.client, c.hasDashboard else { profiles = []; return }
        let gen = generation
        do {
            async let list = c.profiles()
            async let active = c.activeProfile()
            async let servedList = c.servedProfiles()
            let (ps, a, sv) = try await (list, active, servedList)
            guard gen == generation, !Task.isCancelled else { return } // server switched while loading
            profiles = ps.sorted { ($0.isDefault == true ? 0 : 1, $0.name) < ($1.isDefault == true ? 0 : 1, $1.name) }
            if let cur = a.current, cur != "custom" { own = cur }
            served = sv.map { Set($0).union([own]) }
            if let s = selected, s == own || !profiles.contains(where: { $0.name == s }) || !isServed(s) {
                if s != own {
                    profileLog.info("remembered profile \(s, privacy: .public) unavailable, using \(self.own, privacy: .public) [PROF-FALLBACK]")
                    app?.flash("Profile “\(s)” isn't available on this server; showing \(label(own)).")
                }
                setSelected(nil)
                app?.rescopeClient()
            }
        } catch {
            profileLog.error("profile list failed: \(error.localizedDescription, privacy: .public) [PROF-LOAD-ERR]")
            app?.report("Couldn't load profiles", error)
        }
    }

    /// Another server was selected: profiles, their keys and the remembered choice are per server.
    func serverChanged() {
        generation += 1 // in-flight loads/switches from the old server drop their results
        profiles = []; served = nil; own = "default"; switching = nil; keyPrompt = nil; pendingMessage = nil
        selected = UserDefaults.standard.string(forKey: "profile.selected" + ConnectionSettings.scope)
    }

    /// Bumped on every server switch; async work captures it and bails if it changed (security review: a key or
    /// selection from server A must never be stored under server B).
    // AIDEV-NOTE: security; check `generation` after every await that leads to a state/Keychain write.
    private(set) var generation = 0

    private func setSelected(_ name: String?) {
        selected = (name == own) ? nil : name
        UserDefaults.standard.set(selected, forKey: "profile.selected" + ConnectionSettings.scope)
    }

    // MARK: switching

    /// Probes the profile, then makes it current and reloads every pane. Returns false (and explains) when the
    /// gateway doesn't serve it or refuses the key; a 401 opens the key sheet instead of a toast.
    @discardableResult
    func switchTo(_ name: String) async -> Bool {
        guard let app, let base = app.client else { return false }
        if name == current { return true }
        if !isServed(name) { app.flash(notServedMessage(name)); return false }
        let target = client(for: name, from: base)
        let gen = generation
        switching = name
        defer { if gen == generation { switching = nil } }
        do {
            _ = try await target.sessions(limit: 1) // /health is unauthenticated; this proves the route AND the key
            guard gen == generation else { return false }
        } catch let e as HermesError where e.isAuthFailure {
            profileLog.info("profile \(name, privacy: .public) refused our key [PROF-NEEDS-KEY]")
            keyPrompt = name
            return false
        } catch let e as HermesError where e.isProfileNotServed {
            app.flash(notServedMessage(name)); return false
        } catch {
            app.report("Couldn't switch to \(label(name))", error); return false
        }
        profileLog.info("switched to profile \(name, privacy: .public) [PROF-SWITCH]")
        setSelected(name)
        app.profileChanged()
        return true
    }

    func notServedMessage(_ name: String) -> String {
        "This gateway doesn't serve “\(label(name))”. Turn on gateway.multiplex_profiles and restart the gateway, or unpark the profile."
    }

    // MARK: management

    /// Generates a fresh API_SERVER_KEY, writes it into the profile's .env (dashboard) and keeps it in the Keychain.
    /// A profile-specific key keeps profiles isolated: the main key never unlocks another profile.
    func provisionKey(for name: String) async throws {
        guard let c = app?.client else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HermesError(status: 0, message: "Couldn't generate a key")
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let scope = ConnectionSettings.scope // the server this key is being written to, captured before the await
        try await c.setEnv("API_SERVER_KEY", value: key, profile: name)
        guard saveKey(key, for: name, scope: scope) else { throw HermesError(status: 0, message: "Couldn't save the key to your Keychain") }
        profileLog.info("provisioned API key for profile \(name, privacy: .public) [PROF-KEY-NEW]")
    }

    @discardableResult
    func saveKey(_ key: String?, for name: String, scope: String = ConnectionSettings.scope) -> Bool {
        Keychain.set(Self.keyAccount(name, scope: scope), key)
    }

    /// After the key sheet: try the switch again and deliver a message that was waiting on it.
    func retryAfterKey(_ name: String) async {
        keyPrompt = nil
        let msg = pendingMessage
        pendingMessage = nil
        if await switchTo(name), let msg { app?.chats.send(msg) }
    }

    func create(_ name: String, description: String, cloneCurrent: Bool) async throws {
        guard let c = app?.client else { return }
        try await c.createProfile(name, description: description.isEmpty ? nil : description, cloneFrom: cloneCurrent ? current : nil)
        // Best effort: without a key the profile exists but /p/<name>/ refuses us; the sheet can fix that later.
        do { try await provisionKey(for: name) } catch { app?.report("Created “\(name)”, but couldn't give it an API key", error) }
        await load()
    }

    func delete(_ name: String) async throws {
        guard let c = app?.client, name != own else { return }
        let scope = ConnectionSettings.scope, gen = generation
        if current == name { _ = await switchTo(own) }
        try await c.deleteProfile(name)
        saveKey(nil, for: name, scope: scope)
        ChatLocalData.purge(scope: scope, profile: name)
        if gen == generation { await load() }
    }

    func setDescription(_ name: String, _ text: String) async throws {
        guard let c = app?.client else { return }
        try await c.setProfileDescription(name, text)
        await load()
    }
}
