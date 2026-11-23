import Foundation
import os
import HermesKit
import Observation
import Security
import SwiftUI

private let keychainLog = Logger(subsystem: "net.jmaddington.hermes", category: "keychain")

enum Keychain {
    static let service = "net.jmaddington.hermes"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    /// Update-or-add, so a failed write never deletes the old secret first; returns false on failure (hermes-mac-azh).
    @discardableResult
    static func set(_ account: String, _ value: String?) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        guard let value, !value.isEmpty else {
            let st = SecItemDelete(q as CFDictionary)
            return st == errSecSuccess || st == errSecItemNotFound
        }
        let data = Data(value.utf8)
        var st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            st = SecItemAdd(add as CFDictionary, nil)
        }
        if st != errSecSuccess { keychainLog.error("keychain write \(account, privacy: .public) failed status=\(st) [KEYCHAIN-WRITE-ERR]") }
        return st == errSecSuccess
    }
}

/// Connection settings. URLs in UserDefaults, secrets in the Keychain.
/// One saved Hermes server. URLs + name in UserDefaults ("servers"), secrets in the Keychain per server.
/// AIDEV-NOTE: the server with id "default" keeps the pre-multi-server Keychain accounts ("apiKey", "dashboardToken")
/// and UserDefaults keys, so existing installs migrate without touching secrets.
struct ConnectionSettings: Equatable, Identifiable {
    var id = "default"
    var name = ""
    var apiURL = "http://127.0.0.1:8642"
    var apiKey = ""
    var dashboardURL = "http://127.0.0.1:9119"
    var dashboardToken = ""

    /// Name for menus: the saved name, else the API host.
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return Self.validURL(apiURL)?.host() ?? "Hermes"
    }

    private static func account(_ base: String, _ id: String) -> String { id == "default" ? base : "\(base).srv.\(id)" }

    // MARK: server list

    private struct Stored: Codable { var id: String; var name: String; var apiURL: String; var dashboardURL: String }

    static var currentID: String {
        get { UserDefaults.standard.string(forKey: "server.current") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "server.current") }
    }

    /// All saved servers (secrets filled in), migrating the single legacy server on first run.
    static func all() -> [ConnectionSettings] {
        let d = UserDefaults.standard
        var stored = (d.data(forKey: "servers")).flatMap { try? JSONDecoder().decode([Stored].self, from: $0) } ?? []
        if stored.isEmpty {
            let legacy = ConnectionSettings()
            stored = [Stored(id: "default", name: "", apiURL: d.string(forKey: "apiURL") ?? legacy.apiURL,
                             dashboardURL: d.string(forKey: "dashboardURL") ?? legacy.dashboardURL)]
            if let data = try? JSONEncoder().encode(stored) { d.set(data, forKey: "servers") }
        }
        return stored.map { st in
            var s = ConnectionSettings(id: st.id, name: st.name, apiURL: st.apiURL, dashboardURL: st.dashboardURL)
            s.apiKey = Keychain.get(account("apiKey", st.id)) ?? ""
            s.dashboardToken = Keychain.get(account("dashboardToken", st.id)) ?? ""
            return s
        }
    }

    private static func writeList(_ list: [ConnectionSettings]) {
        let stored = list.map { Stored(id: $0.id, name: $0.name, apiURL: $0.apiURL, dashboardURL: $0.dashboardURL) }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: "servers") }
    }

    /// Removes a server and its secrets (never the last one).
    static func remove(_ id: String) {
        var list = all()
        guard list.count > 1 else { return }
        list.removeAll { $0.id == id }
        writeList(list)
        Keychain.set(account("apiKey", id), nil)
        Keychain.set(account("dashboardToken", id), nil)
        if currentID == id { currentID = list[0].id }
    }

    /// Suffix for per-server UserDefaults/Keychain names; "" for the default server (pre-multi-server names).
    static var scope: String { currentID == "default" ? "" : ".srv.\(currentID)" }

    static func newServer() -> ConnectionSettings {
        ConnectionSettings(id: UUID().uuidString.lowercased().prefix(8).description, name: "", apiURL: "http://", apiKey: "",
                           dashboardURL: "", dashboardToken: "")
    }

    static func load() -> ConnectionSettings {
        let list = all()
        var s = list.first { $0.id == currentID } ?? list[0]
        // AIDEV-NOTE: dev/test seam: HERMES_API_KEY etc. in the launch environment seed an empty Keychain.
        let env = ProcessInfo.processInfo.environment
        if s.apiKey.isEmpty, let k = env["HERMES_API_KEY"] {
            s.apiKey = k; s.dashboardToken = env["HERMES_DASHBOARD_TOKEN"] ?? ""
            if let u = env["HERMES_API_URL"] { s.apiURL = u }
            if let u = env["HERMES_DASHBOARD_URL"] { s.dashboardURL = u }
            s.save()
        }
        return s
    }

    /// Upserts this server in the list and stores its secrets. Returns false if a secret couldn't be stored.
    @discardableResult
    func save() -> Bool {
        var list = Self.all()
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = self } else { list.append(self) }
        Self.writeList(list)
        if id == "default" { // keep legacy keys current for older builds / tools
            UserDefaults.standard.set(apiURL, forKey: "apiURL")
            UserDefaults.standard.set(dashboardURL, forKey: "dashboardURL")
        }
        let a = Keychain.set(Self.account("apiKey", id), apiKey)
        let b = Keychain.set(Self.account("dashboardToken", id), dashboardToken)
        return a && b
    }

    var isConfigured: Bool { Self.validURL(apiURL) != nil && !apiKey.isEmpty }

    /// http(s) URL with a host; "localhost:8642" or "not a url" are rejected instead of failing later (hermes-mac-as0).
    static func validURL(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let h = u.host(), !h.isEmpty else { return nil }
        return u
    }

    func makeClient() -> HermesClient? {
        guard let a = Self.validURL(apiURL), !apiKey.isEmpty else { return nil }
        let dash = Self.validURL(dashboardURL).flatMap { u in
            dashboardToken.isEmpty ? nil : Endpoint(baseURL: u, token: dashboardToken, headerName: "X-Hermes-Session-Token")
        }
        return HermesClient(api: Endpoint(baseURL: a, token: apiKey, headerName: "Authorization"), dashboard: dash)
    }
}

enum Section: String, CaseIterable, Identifiable, Hashable {
    case chats, skills, scheduled, tools, memory, usage, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chats: "Chats"; case .skills: "Skills"; case .scheduled: "Scheduled"; case .tools: "Tools"
        case .memory: "Memory"; case .usage: "Usage"; case .logs: "Logs"
        }
    }
    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.text.bubble.right"; case .skills: "sparkles.rectangle.stack"
        case .scheduled: "clock.badge.checkmark"; case .tools: "wrench.and.screwdriver"
        case .memory: "brain"; case .usage: "chart.bar.xaxis"; case .logs: "text.alignleft"
        }
    }
    var needsDashboard: Bool { ![.chats, .scheduled].contains(self) }
}

enum ConnectionState: Equatable {
    case unconfigured, connecting, connected(version: String?), failed(String)
}

@MainActor @Observable
final class AppModel {
    var settings = ConnectionSettings.load()
    /// Saved servers (for the switcher and Settings > Connection).
    var servers = ConnectionSettings.all()
    private(set) var client: HermesClient?
    var connection: ConnectionState = .unconfigured
    var section: Section? = .chats
    var showOnboarding = false
    var toast: String?

    let chats = ChatStore()
    let voice = VoiceController()
    let library = LibraryStore()
    let profiles = ProfileStore()
    let browser = BrowserModel()

    init() {
        chats.app = self
        voice.app = self
        library.app = self
        profiles.app = self
        browser.app = self
        browser.agent.startIfEnabled() // loopback MCP server for Hermes, only when the user allowed it
        if settings.isConfigured { connect() } else { showOnboarding = true }
        installVoiceTestHarness()
    }

    /// Voice test seam: `HERMES_VOICE_TEST=1` at launch lets scripts/voice-inject.swift feed an audio file into
    /// voice mode in place of the mic. Off by default so no other process can speak to Hermes as the user.
    // AIDEV-NOTE: security; keep this gated on the launch-time env var.
    private func installVoiceTestHarness() {
        guard ProcessInfo.processInfo.environment["HERMES_VOICE_TEST"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("net.jmaddington.hermes.test.injectVoice"), object: nil, queue: .main
        ) { [weak self] note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { self?.voice.injectTestAudio(path: path) }
        }
    }

    /// Saves a server's settings. Editing the current server reconnects; editing another one just saves it.
    func apply(_ s: ConnectionSettings) {
        if !s.save() { flash("Couldn't save the key to your Keychain. It will be forgotten when Alaria quits.") }
        servers = ConnectionSettings.all()
        guard s.id == settings.id else { return }
        let serverChanged = s.apiURL != settings.apiURL || s.dashboardURL != settings.dashboardURL
        settings = s
        if serverChanged { resetServerState() } // never send to a session id that only existed on the old server
        connect()
    }

    /// Switches the whole app to another saved server: clears everything from the old one, then connects.
    func switchServer(to id: String) {
        guard id != settings.id, let s = servers.first(where: { $0.id == id }) else { return }
        ConnectionSettings.currentID = id
        settings = s
        resetServerState()
        profiles.serverChanged()
        connect()
        flash("Switched to \(s.displayName)")
    }

    func removeServer(_ id: String) {
        let wasCurrent = id == settings.id
        ConnectionSettings.remove(id)
        servers = ConnectionSettings.all()
        if wasCurrent, let first = servers.first { settings = first; resetServerState(); profiles.serverChanged(); connect() }
    }

    private var connectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    /// (Re)connects. Cancels an in-flight connect so an older health result can't overwrite a newer one, and
    /// starts a monitor: every 15 s a dropped server turns the badge red and a failed one is retried (hermes-mac-1b9).
    func connect() {
        connectTask?.cancel()
        client = settings.makeClient().map(profiles.scope) // the remembered Hermes profile (Features/Profiles)
        guard let client else { connection = .unconfigured; return }
        connection = .connecting
        connectTask = Task {
            do {
                let h = try await client.health()
                guard !Task.isCancelled else { return }
                connection = .connected(version: h.version == "unknown" ? nil : h.version)
                await profiles.load() // may fall back to the gateway's own profile and re-scope `client`
                await chats.reload()
                await library.loadJobs()
                await library.loadSkills()
            } catch {
                guard !Task.isCancelled else { return }
                connection = .failed(error.localizedDescription)
            }
        }
        if monitorTask == nil { monitorTask = Task { await monitor() } }
    }

    private func monitor() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard let client else { continue }
            switch connection {
            case .failed: connect() // auto-retry; connect() keeps this monitor
            case .connected:
                do { _ = try await client.health() }
                catch { if case .connected = connection { connection = .failed(error.localizedDescription) } }
            default: break
            }
        }
    }

    func reloadCurrent() {
        if case .failed = connection { connect(); return }
        Task {
            switch section ?? .chats {
            case .chats: await chats.reload()
            case .skills: await library.loadSkills()
            case .scheduled: await library.loadJobs()
            case .tools: await library.loadToolsets()
            case .memory: await library.loadMemory()
            case .usage, .logs: break // these panes poll / reload on their own
            }
        }
    }

    /// Re-derives `client` for the current profile (ProfileStore changed the selection).
    func rescopeClient() { client = settings.makeClient().map(profiles.scope) }

    /// The user switched Hermes profile: everything on screen belonged to the old one (sessions, skills, jobs,
    /// memory live in each profile's own home), so drop it and load the new profile's.
    func profileChanged() {
        chats.newChat()
        chats.sessions = []
        chats.archived = []
        library.reset()
        rescopeClient()
        Task {
            await chats.reload()
            await library.loadJobs()
            await library.loadSkills()
        }
    }

    private func resetServerState() {
        chats.newChat()
        chats.sessions = []
        library.reset()
    }

    func flash(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(3)); if toast == message { toast = nil } }
    }

    /// Runs an action and surfaces failures as a toast instead of swallowing them.
    func run(_ what: String, _ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { report(what, error) }
        }
    }

    /// Flashes a failure unless it's just a cancelled request (re-selection cancels .task loads) (hermes-mac-r6c).
    func report(_ what: String, _ error: Error) {
        guard !error.isCancellation else { return }
        flash("\(what): \(error.localizedDescription)")
    }
}


extension Error {
    /// Task cancellation or a URLSession request cancelled underneath it.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
