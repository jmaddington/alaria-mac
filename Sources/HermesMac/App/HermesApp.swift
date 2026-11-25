import os
import AppKit
import SwiftUI

private let appLog = Logger(subsystem: "net.jmaddington.hermes", category: "app")

@main
struct HermesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("Alaria", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
                .tint(Theme.accent)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }.disabled(!Updater.shared.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.section = .chats; model.chats.newChat() }.keyboardShortcut("n")
            }
            // Multiple Hermes servers: ⌃⌘1-9 switch between them.
            CommandMenu("Server") {
                ForEach(Array(model.servers.prefix(9).enumerated()), id: \.element.id) { i, srv in
                    Button(srv.id == model.settings.id ? "✓ \(srv.displayName)" : srv.displayName) { model.switchServer(to: srv.id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
            }
            CommandMenu("Conversation") {
                Button(model.voice.isActive ? "End Voice Mode" : "Start Voice Mode") {
                    model.section = .chats
                    model.voice.isActive ? model.voice.stop() : model.voice.start()
                }.keyboardShortcut("v", modifiers: [.command, .option])  // ⇧⌘V is commonly taken by clipboard managers
                Button("Stop Responding") { model.chats.stop() }
                    .keyboardShortcut(".", modifiers: .command).disabled(!model.chats.isStreaming)
                Divider()
                // Reloads what's on screen, and reconnects if Hermes was unreachable (hermes-mac-6o9, -1b9).
                Button("Reload") { model.reloadCurrent() }.keyboardShortcut("r")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button(model.browser.isOpen ? "Hide Browser" : "Show Browser") { model.browser.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Open Location…") { model.browser.focusAddress() }.keyboardShortcut("l")
                Divider()
            }
        }

        Settings {
            SettingsView().environment(model).tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables launch as background processes; promote to a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Self.purgeHTTPCache()
        Updater.shared.start()
    }

    /// Removes the URL cache and cookie file older builds wrote (transcripts and auth headers; HTTPCore no longer caches).
    /// Runs every launch before anything else makes a request; the browser panel's WebKit data lives elsewhere.
    static func purgeHTTPCache() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = lib.appendingPathComponent("Caches").appendingPathComponent(id)
        let targets = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"].map { caches.appendingPathComponent($0) }
            + [lib.appendingPathComponent("HTTPStorages").appendingPathComponent(id + ".binarycookies"),
               lib.appendingPathComponent("HTTPStorages").appendingPathComponent(id)]
        URLCache.shared.removeAllCachedResponses()
        for t in targets where fm.fileExists(atPath: t.path) {
            do { try fm.removeItem(at: t) }
            catch { appLog.error("cache purge failed for \(t.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) [ALR-CACHE-PURGE]") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
