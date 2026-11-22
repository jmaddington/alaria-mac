import AppKit
import HermesKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if model.voice.isActive || isVoiceError { VoiceOverlay().transition(.opacity) } }
        .animation(.smooth(duration: 0.35), value: model.voice.isActive)
        // Voice mode owns the whole window; toolbar glass buttons would otherwise float over the overlay.
        .toolbar(model.voice.isActive || isVoiceError ? .hidden : .automatic, for: .windowToolbar)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environment(model) }
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
        .safeAreaInset(edge: .bottom) { ConnectionBadge().padding(12) }
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { openSettings() } label: {
            HStack(spacing: 8) {
                StatusDot(color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .help("Connection settings")
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
                Text("Welcome to Talaria").font(.largeTitle.weight(.semibold))
                Text("Connect Talaria to your Hermes agent. You'll find the keys in your Hermes home's .env file.")
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
            .accessibilityLabel("Talaria")
    }
}
