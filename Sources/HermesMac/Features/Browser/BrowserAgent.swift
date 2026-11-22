import AppKit
import HermesKit
import HermesMCPServer
import Observation
import os
import Security
import WebKit

/// Lets Hermes drive the browser panel: runs the loopback MCP server and implements the client_browser_* tools.
// AIDEV-NOTE: flow = Hermes gateway -> HTTP POST 127.0.0.1:<port>/mcp (bearer token) -> MCPHTTPListener ->
// MCPServerCore -> BrowserAgent.call (MainActor, one call at a time) -> WKWebView + BrowserScript in an isolated
// content world. See docs/agents/browser-tool.md before changing tool names: Hermes prompts/history reference them.
@MainActor @Observable
final class BrowserAgent {
    enum ServerState: Equatable { case off, starting, listening(UInt16), failed(String) }

    @ObservationIgnored unowned let browser: BrowserModel
    var state: ServerState = .off
    @ObservationIgnored private var listener: MCPHTTPListener?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    static let enabledKey = "browser.agentEnabled"
    static let portKey = "browser.agentPort"
    static let tokenAccount = "browserToolToken"

    init(browser: BrowserModel) {
        self.browser = browser
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(p) ? UInt16(p) : BrowserToolCatalog.defaultPort
    }

    /// The bearer token Hermes must send. Created on first use and kept in the Keychain.
    var token: String {
        if let cachedToken { return cachedToken }
        if let t = Keychain.get(Self.tokenAccount), t.count >= 32 { cachedToken = t; return t }
        let t = Self.newToken()
        if !Keychain.set(Self.tokenAccount, t) {
            browserLog.error("browser tool token not saved to Keychain [BRW-TOKEN-KEYCHAIN-ERR]")
            browser.app?.flash("Couldn't save the browser tool token to your Keychain. It changes when the app quits.")
        }
        cachedToken = t
        return t
    }
    private var cachedToken: String?

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            browserLog.error("SecRandomCopyBytes failed; falling back to UUIDs [BRW-TOKEN-RAND-ERR]")
            return "hm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return "hm_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    var configSnippet: String { MCPConfigYAML.snippet(port: port, token: token) }

    // MARK: server lifecycle

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    func startIfEnabled() { if enabled { start() } }

    func start() {
        stop()
        let token = self.token
        let core = MCPServerCore(name: BrowserToolCatalog.serverName, version: Bundle.main.shortVersion,
                                 instructions: BrowserToolCatalog.instructions, tools: BrowserToolCatalog.tools) { [weak self] name, args in
            guard let self else { return .error("The Hermes Mac browser is shutting down.") }
            return await self.call(name, args)
        }
        let l = MCPHTTPListener(port: port, router: MCPHTTPRouter(core: core, token: token))
        listener = l
        state = .starting
        Task {
            do {
                let p = try await l.start()
                guard listener === l else { l.stop(); return }
                state = .listening(p)
            } catch {
                guard listener === l else { return }
                listener = nil
                state = .failed(error.localizedDescription)
                browserLog.error("browser tool server failed to start: \(error.localizedDescription, privacy: .public) [BRW-MCP-START-ERR]")
                browser.app?.flash("Browser tool for Hermes didn't start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        state = .off
    }

    /// New token: the old config.yaml entry stops working until it's rewritten.
    func regenerateToken() {
        let t = Self.newToken()
        if !Keychain.set(Self.tokenAccount, t) { browser.app?.flash("Couldn't save the new token to your Keychain.") }
        cachedToken = t
        if listener != nil { start() }
    }

    // MARK: tool dispatch

    func call(_ name: String, _ args: [String: JSONValue]) async -> MCPToolResult {
        await acquire(); defer { release() }
        if browser.userHasControl {
            return .error("The user has taken control of the in-app browser and paused Hermes' browser tools. Stop using client_browser_* tools, tell the user what you were trying to do, and continue only after they resume.")
        }
        browser.isOpen = true
        browser.agentTool = name
        browser.agentRecentlyActive = true
        idleTask?.cancel()
        defer {
            browser.agentTool = nil
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.browser.agentRecentlyActive = false
            }
        }
        browserLog.info("Hermes browser tool \(name, privacy: .public) [BRW-TOOL]")
        do {
            return try await run(name, args)
        } catch {
            browserLog.error("browser tool \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public) [BRW-TOOL-ERR]")
            return .error(Self.message(error))
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    struct ToolError: LocalizedError { let errorDescription: String? }
    static func fail(_ s: String) -> ToolError { ToolError(errorDescription: s) }

    /// WKWebView JS exceptions arrive as WKError.javaScriptExceptionOccurred with the message in userInfo.
    static func message(_ error: Error) -> String {
        let ns = error as NSError
        if let m = ns.userInfo["WKJavaScriptExceptionMessage"] as? String { return m.replacingOccurrences(of: "Error: ", with: "") }
        return error.localizedDescription
    }

    private var web: WKWebView { browser.webView }

    private func run(_ name: String, _ a: [String: JSONValue]) async throws -> MCPToolResult {
        switch name {
        case "client_browser_navigate":
            guard let raw = a.string("url"), let u = BrowserAddress.url(from: raw) else {
                throw Self.fail("Give an absolute http(s) URL, like https://example.com. Other schemes are not allowed.")
            }
            browser.load(u)
            try await waitForLoad(timeout: 25)
            return .text(try await status() + "\n\n" + snapshot(full: false, max: 6000))
        case "client_browser_snapshot":
            try requirePage()
            return .text(try await snapshot(full: a.bool("full") ?? false, max: min(max(a.int("max_chars") ?? 12000, 500), 100_000)))
        case "client_browser_click":
            try requirePage()
            let before = web.url
            let what = try await js("return __hermes.click(ref)", ["ref": try ref(a)])
            try await settle(previous: before)
            return .text("Clicked \(what).\n" + (try await status()) + (web.url != before ? "\nThe page changed; refs are stale, take a new snapshot." : ""))
        case "client_browser_type":
            try requirePage()
            guard let text = a.string("text") else { throw Self.fail("type needs text.") }
            let before = web.url
            let submit = a.bool("submit") ?? false
            let what = try await js("return __hermes.type(ref, text, clear, submit)",
                                    ["ref": try ref(a), "text": text, "clear": a.bool("clear") ?? true, "submit": submit])
            if submit { try await settle(previous: before) }
            return .text("Typed into \(what).\n" + (try await status()))
        case "client_browser_press_key":
            try requirePage()
            guard let key = a.string("key"), !key.isEmpty else { throw Self.fail("press_key needs key, e.g. Enter.") }
            let before = web.url
            let what = try await js("return __hermes.press(key)", ["key": key])
            try await settle(previous: before)
            return .text(what + "\n" + (try await status()))
        case "client_browser_scroll":
            try requirePage()
            var args: [String: Any] = ["direction": a.string("direction") ?? "down", "amount": NSNull(), "ref": NSNull()]
            if let n = a.int("amount") { args["amount"] = n }
            if let r = a.string("ref") { args["ref"] = r }
            return .text(try await js("return __hermes.scroll(direction, amount, ref)", args))
        case "client_browser_back", "client_browser_forward":
            let back = name == "client_browser_back"
            guard back ? web.canGoBack : web.canGoForward else { throw Self.fail("There is no page to go \(back ? "back" : "forward") to.") }
            _ = back ? web.goBack() : web.goForward()
            try await waitForLoad(timeout: 15, expectStart: true)
            return .text(try await status() + "\n\n" + snapshot(full: false, max: 6000))
        case "client_browser_get_text":
            try requirePage()
            return .text(try await js("return __hermes.text(n)", ["n": min(max(a.int("max_chars") ?? 20000, 500), 200_000)]))
        case "client_browser_screenshot":
            try requirePage()
            let png = try await screenshot()
            return MCPToolResult(content: [.text(try await status()), .image(png, mimeType: "image/png")])
        case "client_browser_wait":
            let seconds = min(max(a["seconds"]?.double ?? Double(a.int("seconds") ?? 5), 0.2), 20)
            if let text = a.string("text"), !text.isEmpty {
                try requirePage()
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if (try? await js("return String(__hermes.has(t))", ["t": text])) == "true" { return .text("Found \"\(text)\".\n" + (try await status())) }
                    try await Task.sleep(for: .milliseconds(250))
                }
                return .error("\"\(text)\" did not appear within \(Int(seconds)) s.\n" + (try await status()))
            }
            try await waitForLoad(timeout: seconds, expectStart: false)
            return .text(try await status())
        default:
            throw Self.fail("Unknown tool \(name).")
        }
    }

    private func ref(_ a: [String: JSONValue]) throws -> String {
        guard let r = a.string("ref"), !r.isEmpty else { throw Self.fail("Missing ref. Take a client_browser_snapshot and pass a ref like \"e12\".") }
        return r
    }

    private func requirePage() throws {
        guard browser.hasPage else { throw Self.fail("No page is open. Call client_browser_navigate first.") }
    }

    private func status() async throws -> String {
        var s = "Title: \(web.title ?? "")\nURL: \(web.url?.absoluteString ?? "(none)")"
        if let e = browser.loadError { s += "\nLoad error: \(e)" }
        if web.isLoading { s += "\n(still loading)" }
        return s
    }

    private func snapshot(full: Bool, max: Int) async throws -> String {
        try await js("return __hermes.snapshot(full, max)", ["full": full, "max": max])
    }

    /// Runs `body` in the isolated world with `args` as named locals; installs the helper if the page lost it.
    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> String {
        let src = "if (!window.__hermes) {\n\(BrowserScript.source)\n}\n\(body)"
        let v = try await web.callAsyncJavaScript(src, arguments: args, in: nil, contentWorld: BrowserScript.world)
        if let s = v as? String { return s }
        if let v { return "\(v)" }
        return ""
    }

    /// After a click/key: give the page a moment, and if it navigated, wait for the load.
    private func settle(previous: URL?) async throws {
        try await Task.sleep(for: .milliseconds(350))
        if web.isLoading || web.url != previous { try await waitForLoad(timeout: 15, expectStart: false) }
    }

    private func waitForLoad(timeout: Double, expectStart: Bool = true) async throws {
        if expectStart {
            // load() returns before isLoading flips; give it a beat so we don't return on the old page.
            for _ in 0..<10 where !web.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while web.isLoading && Date() < deadline {
            if browser.userHasControl { throw Self.fail("The user took over the browser.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let e = browser.loadError, !web.isLoading, web.url == nil || web.title?.isEmpty != false { throw Self.fail("Page failed to load: \(e)") }
    }

    private func screenshot() async throws -> Data {
        let cfg = WKSnapshotConfiguration()
        // Cap the width: a Retina panel is ~2x; models downscale anyway and big PNGs cost tokens and time.
        let w = web.bounds.width
        if w > 1280 { cfg.snapshotWidth = NSNumber(value: 1280) }
        let img = try await web.takeSnapshot(configuration: cfg)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw Self.fail("Couldn't encode the screenshot.") }
        return png
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
