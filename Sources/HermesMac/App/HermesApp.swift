import AppKit
import SwiftUI

@main
struct HermesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("Hermes", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.section = .chats; model.chats.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("Conversation") {
                Button(model.voice.isActive ? "End Voice Mode" : "Start Voice Mode") {
                    model.section = .chats
                    model.voice.isActive ? model.voice.stop() : model.voice.start()
                }.keyboardShortcut("v", modifiers: [.command, .option])  // ⇧⌘V is commonly taken by clipboard managers
                Button("Stop Responding") { model.chats.stop() }
                    .keyboardShortcut(".", modifiers: .command).disabled(!model.chats.isStreaming)
                Divider()
                Button("Reload") { Task { await model.chats.reload() } }.keyboardShortcut("r")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables launch as background processes; promote to a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
