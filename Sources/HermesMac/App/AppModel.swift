import Foundation
import HermesKit
import Observation
import Security
import SwiftUI

enum Keychain {
    static let service = "net.jmaddington.hermes"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Connection settings. URLs in UserDefaults, secrets in the Keychain.
struct ConnectionSettings: Equatable {
    var apiURL = "http://127.0.0.1:8642"
    var apiKey = ""
    var dashboardURL = "http://127.0.0.1:9119"
    var dashboardToken = ""

    static func load() -> ConnectionSettings {
        var s = ConnectionSettings()
        let d = UserDefaults.standard
        s.apiURL = d.string(forKey: "apiURL") ?? s.apiURL
        s.dashboardURL = d.string(forKey: "dashboardURL") ?? s.dashboardURL
        s.apiKey = Keychain.get("apiKey") ?? ""
        s.dashboardToken = Keychain.get("dashboardToken") ?? ""
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

    func save() {
        UserDefaults.standard.set(apiURL, forKey: "apiURL")
        UserDefaults.standard.set(dashboardURL, forKey: "dashboardURL")
        Keychain.set("apiKey", apiKey)
        Keychain.set("dashboardToken", dashboardToken)
    }

    var isConfigured: Bool { URL(string: apiURL) != nil && !apiKey.isEmpty }

    func makeClient() -> HermesClient? {
        guard let a = URL(string: apiURL), !apiKey.isEmpty else { return nil }
        let dash = URL(string: dashboardURL).flatMap { u in
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
    private(set) var client: HermesClient?
    var connection: ConnectionState = .unconfigured
    var section: Section? = .chats
    var showOnboarding = false
    var toast: String?

    let chats = ChatStore()
    let voice = VoiceController()
    let library = LibraryStore()

    init() {
        chats.app = self
        voice.app = self
        library.app = self
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

    func apply(_ s: ConnectionSettings) {
        let serverChanged = s.apiURL != settings.apiURL || s.dashboardURL != settings.dashboardURL
        settings = s
        s.save()
        if serverChanged { resetServerState() } // never send to a session id that only existed on the old server
        connect()
    }

    private var connectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    /// (Re)connects. Cancels an in-flight connect so an older health result can't overwrite a newer one, and
    /// starts a monitor: every 15 s a dropped server turns the badge red and a failed one is retried (hermes-mac-1b9).
    func connect() {
        connectTask?.cancel()
        client = settings.makeClient()
        guard let client else { connection = .unconfigured; return }
        connection = .connecting
        connectTask = Task {
            do {
                let h = try await client.health()
                guard !Task.isCancelled else { return }
                connection = .connected(version: h.version == "unknown" ? nil : h.version)
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
            do { try await body() } catch { flash("\(what): \(error.localizedDescription)") }
        }
    }
}
