import AppKit
import WebKit

// Headless check of BrowserScript's JS in an offscreen WKWebView (never shown, no Dock icon).
//   swiftc -o /tmp/brw-js scripts/browser-js-check.swift && /tmp/brw-js Sources/HermesMac/Features/Browser/BrowserScript.swift
let src = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let js = String(src[src.range(of: "#\"\"\"\n")!.upperBound..<src.range(of: "\"\"\"#")!.lowerBound])
let world = WKContentWorld.world(name: "hermes-agent")

let html = """
<html><head><title>Test Page</title></head><body>
<nav aria-label="Top"><a href="/home">Home</a> <a href="https://x.test/docs">Docs</a></nav>
<main><h1>Hello <a href="#s">anchor</a></h1><p>Some paragraph text here.</p>
<form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent='submitted:'+document.getElementById('q').value">
<label for="q">Search</label><input id="q" placeholder="Find"><input type="password" id="pw" value="secret">
<select id="s"><option value="a">Apple</option><option value="b">Banana</option></select>
<button type="submit">Go</button></form>
<div id="hidden" style="display:none"><button>Invisible</button></div>
<div id="out"></div><div contenteditable="true" id="ce">edit me</div>
<button onclick="this.textContent='clicked!'">Press</button>
<div style="height:3000px"></div></main>
<script>window.__hermes = "page tried to spoof";</script></body></html>
"""

@MainActor func run() async {
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
    w.loadHTMLString(html, baseURL: URL(string: "https://test.local/")!)
    while w.isLoading || w.url == nil { try? await Task.sleep(for: .milliseconds(50)) }
    try? await Task.sleep(for: .milliseconds(200))
    func call(_ body: String, _ args: [String: Any] = [:]) async -> String {
        do {
            let v = try await w.callAsyncJavaScript("if (!window.__hermes) {\n\(js)\n}\n" + body, arguments: args, in: nil, contentWorld: world)
            return "\(v ?? "nil")"
        } catch { return "ERR \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error)" }
    }
    func page(_ expr: String) async -> String { "\((try? await w.evaluateJavaScript(expr)) ?? "nil")" }
    var fails = 0
    func expect(_ ok: Bool, _ m: String) { if !ok { fails += 1; print("FAIL", m) } }

    let snap = await call("return __hermes.snapshot(false, 12000)")
    print(snap)
    expect(snap.contains("navigation \"Top\""), "landmark")
    expect(snap.contains("link \"Docs\" [ref=") && snap.contains("-> https://x.test/docs"), "link")
    expect(snap.contains("heading \"Hello anchor\" [level=1]") && snap.contains("link \"anchor\""), "heading + inner link")
    expect(snap.contains("textbox \"Search\" [ref="), "label name")
    expect(snap.contains("value=\"••••\"") && !snap.contains("secret"), "password masked")
    expect(!snap.contains("Invisible"), "hidden skipped")
    expect(!snap.contains("Some paragraph"), "compact omits text")
    let fullSnap = await call("return __hermes.snapshot(true, 12000)")
    expect(fullSnap.contains("text: Some paragraph text here."), "full has text")
    expect(await page("typeof window.__hermes") == "string", "page world can't see our helper (isolated)")

    func refOf(_ s: String, _ label: String) -> String {
        let line = s.split(separator: "\n").first { $0.contains(label) } ?? ""
        guard let r = line.range(of: #"ref=(e\d+)"#, options: .regularExpression) else { return "none" }
        return String(line[r].dropFirst(4))
    }
    let q = refOf(snap, "textbox \"Search\""), sel = refOf(snap, "combobox"), press = refOf(snap, "button \"Press\""), ce = refOf(snap, "edit me")
    // Refs are stable across snapshots of the same document.
    let snap2 = await call("return __hermes.snapshot(false, 12000)")
    expect(refOf(snap2, "textbox \"Search\"") == q, "stable refs")

    print(await call("return __hermes.type(ref, text, true, false)", ["ref": q, "text": "kittens"]))
    expect(await page("document.getElementById('q').value") == "kittens", "typed value")
    print(await call("return __hermes.type(ref, text, true, false)", ["ref": sel, "text": "banana"]))
    expect(await page("document.getElementById('s').value") == "b", "select by text")
    _ = await call("return __hermes.type(ref, text, true, false)", ["ref": ce, "text": "new text"])
    expect(await page("document.getElementById('ce').innerText") == "new text", "contenteditable")
    print(await call("return __hermes.click(ref)", ["ref": press]))
    expect(await page("document.querySelector('button[onclick]').textContent") == "clicked!", "click")
    print(await call("return __hermes.type(ref, text, true, true)", ["ref": "@" + q, "text": "dogs"]))
    try? await Task.sleep(for: .milliseconds(100))
    expect(await page("document.getElementById('out').textContent") == "submitted:dogs", "submit via Enter")
    let bad = await call("return __hermes.click(ref)", ["ref": "e999"])
    expect(bad.contains("No element for ref"), "stale ref message: \(bad)")
    let sc = await call("return __hermes.scroll(direction, amount, ref)", ["direction": "down", "amount": NSNull(), "ref": NSNull()])
    print(sc); expect(sc.hasPrefix("Scrolled down"), "scroll")
    let txt = await call("return __hermes.text(n)", ["n": 50])
    expect(txt.contains("Page: Test Page") && txt.contains("truncated"), "get_text")
    expect(await call("return String(__hermes.has(t))", ["t": "submitted:dogs"]) == "true", "has")
    // Page JS reloading the helper is impossible from the page world; snapshot after navigation gets fresh refs.
    print(fails == 0 ? "JS HARNESS OK" : "JS HARNESS FAILED \(fails)")
    exit(fails == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar, no window
Task { @MainActor in await run() }
app.run()
