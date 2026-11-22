import AppKit
import HermesKit
import Observation
import os
import WebKit

let browserLog = Logger(subsystem: "net.jmaddington.hermes", category: "browser")

/// The in-app browser panel: one WKWebView shared by the user and by Hermes (via BrowserAgent's MCP tools).
// AIDEV-NOTE: the WKWebView is created lazily on first use so launch doesn't pay for WebKit. It uses the default
// (persistent) website data store, so Hermes acts with the user's in-panel sign-ins. That is the point of the
// feature; the Settings copy says so. Navigation is restricted to http(s) (BrowserAddress.allowedSchemes).
@MainActor @Observable
final class BrowserModel: NSObject {
    weak var app: AppModel?

    var isOpen = false
    var address = ""
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress = 0.0
    /// Bumped by ⌘L; the address field focuses when it changes.
    var focusAddressRequest = 0
    /// Last provisional/committed navigation failure, shown in the panel and returned to Hermes.
    var loadError: String?

    // Hermes activity (driven by BrowserAgent).
    var agentTool: String?
    var agentRecentlyActive = false
    /// The user took over: Hermes' tool calls are refused until they resume.
    var userHasControl = false

    @ObservationIgnored private var _webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private(set) lazy var agent = BrowserAgent(browser: self)

    var webView: WKWebView {
        if let w = _webView { return w }
        let w = makeWebView()
        _webView = w
        return w
    }

    var hasPage: Bool { url != nil }

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15" // look like Safari, not a bare embedded view
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.userContentController.addUserScript(BrowserScript.userScript)
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = true
        w.navigationDelegate = self
        w.uiDelegate = self
        observations = [
            w.observe(\.title, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            w.observe(\.url, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.urlChanged(w.url) } },
            w.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            w.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            w.observe(\.isLoading, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
            w.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
        ]
        return w
    }

    private func urlChanged(_ u: URL?) {
        url = u
        if let u, !addressEditing { address = u.absoluteString }
    }
    /// Set by the address field so a page load doesn't overwrite what the user is typing.
    @ObservationIgnored var addressEditing = false

    // MARK: user actions

    func toggle() { isOpen.toggle() }

    func focusAddress() {
        isOpen = true
        focusAddressRequest += 1
    }

    /// Address bar submit: URL or search.
    func go(_ text: String) {
        guard let u = BrowserAddress.resolve(text) else {
            app?.flash("Only web addresses (http and https) open in the browser panel.")
            return
        }
        load(u)
    }

    func load(_ u: URL) {
        loadError = nil
        isOpen = true
        address = u.absoluteString
        webView.load(URLRequest(url: u))
    }

    /// Opens a link from chat. Returns false when the system should handle it instead.
    func openFromChat(_ u: URL) -> Bool {
        guard let scheme = u.scheme?.lowercased(), BrowserAddress.allowedSchemes.contains(scheme) else { return false }
        load(u)
        return true
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reloadOrStop() { if isLoading { webView.stopLoading() } else { webView.reload() } }

    func openInDefaultBrowser() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        app?.flash("Link copied")
    }

    /// Take over from Hermes: stop its page load and refuse further tool calls until resumed.
    func takeOver() {
        userHasControl = true
        if agentTool != nil { webView.stopLoading() }
        browserLog.info("user took over the browser panel [BRW-TAKEOVER]")
    }

    func resumeHermes() {
        userHasControl = false
        browserLog.info("user resumed Hermes browser control [BRW-RESUME]")
    }
}

// MARK: WebKit delegates

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = action.request.url, let scheme = u.scheme?.lowercased() else { return .cancel }
        if BrowserAddress.allowedSchemes.contains(scheme) || ["about", "data", "blob"].contains(scheme) { return .allow }
        // mailto:, tel:, app links: hand to the system only when the user clicked, never on Hermes' behalf.
        if action.navigationType == .linkActivated, agentTool == nil, ["mailto", "tel", "facetime"].contains(scheme) {
            NSWorkspace.shared.open(u)
        } else {
            browserLog.info("blocked navigation to scheme \(scheme, privacy: .public) [BRW-NAV-BLOCK]")
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.canShowMIMEType { return .allow }
        browserLog.info("refused download \(response.response.mimeType ?? "?", privacy: .public) [BRW-DOWNLOAD-BLOCK]")
        app?.flash("Downloads aren't supported in the browser panel. Use Open in Browser.")
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loadError = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navFailed(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navFailed(error) }

    private func navFailed(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return } // superseded by a newer load
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted (we cancelled it)
        loadError = error.localizedDescription
        browserLog.error("navigation failed: \(error.localizedDescription, privacy: .public) [BRW-NAV-ERR]")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        browserLog.error("web content process terminated [BRW-WEB-CRASH]")
        loadError = "The page crashed. Reload to try again."
    }

    /// target=_blank and window.open: load in the same panel (no tabs).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let u = action.request.url, let s = u.scheme?.lowercased(), BrowserAddress.allowedSchemes.contains(s) {
            webView.load(action.request)
        }
        return nil
    }
}
