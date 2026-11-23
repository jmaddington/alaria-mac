import AppKit
import HermesKit
import SwiftUI

struct RootView: View {
    /// Widens the key window toward the right (or left) by up to `points` within the visible screen; true if it now
    /// has room for the browser panel without squeezing the columns.
    @MainActor static func growWindow(by points: CGFloat) -> Bool {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow, let screen = w.screen?.visibleFrame else { return false }
        var f = w.frame
        let target = min(f.width + points, screen.width)
        guard target - f.width >= points * 0.75 else { return false }
        f.size.width = target
        if f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
        w.setFrame(f, display: true, animate: true)
        return true
    }

    @Environment(AppModel.self) private var model
    @ViewState private var columns = NavigationSplitViewVisibility.all
    @ViewState private var columnsBeforeBrowser: NavigationSplitViewVisibility?
    @ViewState private var frameBeforeBrowser: NSRect?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            content
                .id(model.profiles.current) // a profile switch rebuilds panes so their .task loaders run again
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail.id(model.profiles.current)
                .toolbar { ToolbarItem(placement: .primaryAction) { BrowserToolbarButton() } }
                .environment(\.openURL, OpenURLAction { url in
                    // Chat links open in the browser panel (Settings › Browser); ⌘-click keeps the default browser.
                    guard UserDefaults.standard.object(forKey: "browser.openChatLinks") as? Bool ?? true,
                          !NSEvent.modifierFlags.contains(.command), model.browser.openFromChat(url) else { return .systemAction }
                    return .handled
                })
        }
        .inspector(isPresented: Binding(get: { model.browser.isOpen }, set: { model.browser.isOpen = $0 })) {
            BrowserPanel()
                .inspectorColumnWidth(min: 360, ideal: 480, max: 1000)
        }
        // The panel needs room: widen the window if the screen allows, otherwise hide the sidebar while it's open
        // (three columns + a 480 pt panel overflowed a 1240 pt window and clipped everything).
        .onChange(of: model.browser.isOpen) { _, open in
            if open {
                let before = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame
                if Self.growWindow(by: 480) { frameBeforeBrowser = before }
                else { columnsBeforeBrowser = columns; withAnimation(.smooth) { columns = .doubleColumn } }
            } else {
                if let f = frameBeforeBrowser, let w = NSApp.keyWindow ?? NSApp.mainWindow { w.setFrame(f, display: true, animate: true) }
                frameBeforeBrowser = nil
                if let prev = columnsBeforeBrowser { withAnimation(.smooth) { columns = prev }; columnsBeforeBrowser = nil }
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if model.voice.isActive || isVoiceError { VoiceOverlay().transition(.opacity) } }
        .animation(.smooth(duration: 0.35), value: model.voice.isActive)
        // Voice mode owns the whole window; toolbar glass buttons would otherwise float over the overlay.
        .toolbar(model.voice.isActive || isVoiceError ? .hidden : .automatic, for: .windowToolbar)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environment(model) }
        .profileSheets(model)
    }

    private var isVoiceError: Bool { if case .error = model.voice.phase { return true }; return false }

    @ViewBuilder private var content: some View {
        switch model.section ?? .chats {
        case .chats: SessionList()
        case .skills: SkillsList()
        case .scheduled: JobsList()
        case .tools: ToolsList()
        case .memory: MemoryList()
        case .usage: UsagePeriods()
        case .logs: LogFiles()
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section ?? .chats {
        case .chats: ConversationView()
        case .skills: SkillDetail()
        case .scheduled: JobDetail()
        case .tools: ToolDetail()
        case .memory: MemoryDetail()
        case .usage: UsageDetail()
        case .logs: LogDetail()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            SwiftUI.Section {
                ForEach([Section.chats, .skills, .scheduled]) { s in
                    Label(s.title, systemImage: s.symbol).hoverRow().tag(s)
                }
            }
            SwiftUI.Section("Agent") {
                ForEach([Section.tools, .memory]) { s in Label(s.title, systemImage: s.symbol).hoverRow().tag(s) }
            }
            SwiftUI.Section("Insight") {
                ForEach([Section.usage, .logs]) { s in Label(s.title, systemImage: s.symbol).hoverRow().tag(s) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) { ProfileSwitcher(); ConnectionBadge() }.padding(12)
        }
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.tab") private var settingsTab = "connection"
    // The badge doubles as the server switcher (multiple Hermes servers, user request 2026-11-22).
    var body: some View {
        Menu {
            SwiftUI.Section("Servers") {
                ForEach(model.servers) { s in
                    Button { model.switchServer(to: s.id) } label: {
                        if s.id == model.settings.id { Label(s.displayName, systemImage: "checkmark") } else { Text(s.displayName) }
                    }
                }
            }
            Divider()
            Button("Manage Servers…") { settingsTab = "connection"; openSettings() }
        } label: {
            HStack(spacing: 8) {
                StatusDot(color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.servers.count > 1 ? model.settings.displayName : title).font(.caption.weight(.medium))
                    Text(model.servers.count > 1 ? "\(title) · \(subtitle)" : subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .help("Switch Hermes server")
        .accessibilityLabel("Server: \(model.settings.displayName), \(title)")
    }
    private var color: Color {
        switch model.connection {
        case .connected: .green; case .connecting: .orange; case .failed: .red; case .unconfigured: .secondary
        }
    }
    private var title: String {
        switch model.connection {
        case .connected: "Connected"; case .connecting: "Connecting…"; case .failed: "Can't reach Hermes"; case .unconfigured: "Not set up"
        }
    }
    private var subtitle: String {
        switch model.connection {
        case .connected(let v): [URL(string: model.settings.apiURL)?.host(), v.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .failed(let e): e
        default: URL(string: model.settings.apiURL)?.host() ?? ""
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.toast {
            Text(t).font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
                .animation(.spring, value: model.toast)
        }
    }
}

/// First-run connection sheet. Same fields as Settings › Connection.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft = ConnectionSettings()
    @ViewState private var testing = false
    @ViewState private var result: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HermesMark(size: 64)
                Text("Welcome to Alaria").font(.largeTitle.weight(.semibold))
                Text("Connect Alaria to your Hermes agent. You'll find the keys in your Hermes home's .env file.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(.top, 34).padding(.bottom, 24)
            ConnectionForm(draft: $draft)
            if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("✓") ? .green : .red).padding(.top, 8) }
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                Button("Test") { Task { await test() } }.disabled(testing)
                Button("Connect") { model.apply(draft); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!draft.isConfigured)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear { draft = model.settings }
    }

    private func test() async {
        testing = true; defer { testing = false }
        result = await ConnectionForm.test(draft)
    }
}

/// The Hermes mark: a winged-sandal-free abstraction - two stacked arcs suggesting a messenger in motion.
/// The app's mark: the app icon itself (a winged-sandal wing, drawn by scripts/make-icon.swift).
struct HermesMark: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: size * 1.25, height: size * 1.25) // the icon art carries its own inset and shadow
            .frame(width: size, height: size)
            .accessibilityLabel("Alaria")
    }
}
