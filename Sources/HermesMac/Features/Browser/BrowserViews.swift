import AppKit
import SwiftUI
import WebKit

/// The fly-out browser: an inspector column on the window's trailing edge (RootView attaches it).
struct BrowserPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var addressFocused: Bool

    var body: some View {
        let b = model.browser
        VStack(spacing: 0) {
            BrowserChrome(addressFocused: $addressFocused)
            ZStack {
                if b.hasPage {
                    WebViewHost(webView: b.webView)
                } else {
                    EmptyState(symbol: "globe", title: "Browser",
                               message: "Type an address or a search above. Links from chats open here, and Hermes can browse here once you allow it in Settings › Browser.")
                }
                if let e = b.loadError {
                    VStack {
                        Spacer()
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .glassEffect(.regular, in: .capsule)
                            .padding(16)
                    }
                }
            }
            // A quiet accent edge while Hermes is driving, so it's obvious who is in control.
            .overlay {
                if b.agentRecentlyActive && !b.userHasControl {
                    Rectangle().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 2).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: b.agentRecentlyActive)
        }
        .onChange(of: b.focusAddressRequest) { addressFocused = true }
        .onChange(of: addressFocused) { b.addressEditing = addressFocused }
    }
}

struct BrowserChrome: View {
    @Environment(AppModel.self) private var model
    var addressFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var b = model.browser
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        iconButton("chevron.backward", "Back") { b.back() }.disabled(!b.canGoBack)
                        iconButton("chevron.forward", "Forward") { b.forward() }.disabled(!b.canGoForward)
                        iconButton(b.isLoading ? "xmark" : "arrow.clockwise", b.isLoading ? "Stop" : "Reload") { b.reloadOrStop() }
                            .disabled(!b.hasPage)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)

                    HStack(spacing: 6) {
                        Image(systemName: b.url?.scheme == "https" ? "lock.fill" : "globe")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Search or enter address", text: $b.address)
                            .textFieldStyle(.plain)
                            .focused(addressFocused)
                            .onSubmit { b.go(b.address); addressFocused.wrappedValue = false }
                            .onExitCommand { b.address = b.url?.absoluteString ?? ""; addressFocused.wrappedValue = false }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .overlay(alignment: .bottom) {
                        if b.isLoading {
                            GeometryReader { g in
                                Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * b.progress), height: 2)
                            }
                            .frame(height: 2).padding(.horizontal, 14)
                        }
                    }

                    Menu {
                        Button("Open in Default Browser") { b.openInDefaultBrowser() }.disabled(!b.hasPage)
                        Button("Copy Link") { b.copyLink() }.disabled(!b.hasPage)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("More")

                    iconButton("xmark", "Close Browser (⇧⌘B)") { b.isOpen = false }
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            HStack(spacing: 8) {
                Text(b.title.isEmpty ? (b.url?.host() ?? " ") : b.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                AgentStatusPill()
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Hermes is browsing · Take Over" while the agent drives; "Paused for Hermes · Resume" after a take-over.
struct AgentStatusPill: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let b = model.browser
        Group {
            if b.userHasControl {
                pill(symbol: "hand.raised.fill", text: "You have control", tint: .orange, action: "Let Hermes Continue") { b.resumeHermes() }
                    .help("Hermes' browser tools are paused until you let it continue.")
            } else if b.agentRecentlyActive {
                pill(symbol: "sparkles", text: b.agentTool.map(Self.label) ?? "Hermes is browsing", tint: Theme.accent, action: "Take Over") { b.takeOver() }
                    .help("Stop Hermes from using this browser until you let it continue.")
            }
        }
        .animation(.smooth(duration: 0.25), value: b.agentRecentlyActive)
        .animation(.smooth(duration: 0.25), value: b.userHasControl)
    }

    static func label(_ tool: String) -> String {
        switch tool {
        case "client_browser_navigate": "Hermes is opening a page"
        case "client_browser_click": "Hermes is clicking"
        case "client_browser_type", "client_browser_press_key": "Hermes is typing"
        case "client_browser_scroll": "Hermes is scrolling"
        case "client_browser_screenshot", "client_browser_snapshot", "client_browser_get_text": "Hermes is reading the page"
        default: "Hermes is browsing"
        }
    }

    private func pill(symbol: String, text: String, tint: Color, action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolEffect(.pulse, isActive: model.browser.agentTool != nil).foregroundStyle(tint)
            Text(text).font(.caption.weight(.medium))
            Button(action, action: run).buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: .capsule)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// Hosts the model's single WKWebView (same instance across panel open/close, so history and scroll survive).
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Toolbar toggle shown in the detail column's toolbar.
struct BrowserToolbarButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.browser.toggle() } label: {
            Label("Browser", systemImage: "globe")
        }
        .help(model.browser.isOpen ? "Hide Browser (⇧⌘B)" : "Show Browser (⇧⌘B)")
    }
}
