# In-app browser + Hermes browser tool (bead hermes-mac-a1l)

## What it is
- **Panel**: one `WKWebView` in an `.inspector` column on the window's trailing edge (RootView). Toolbar globe
  button, View › Show Browser (⇧⌘B), View › Open Location… (⌘L). Chat links open here (Settings › Browser
  toggle; ⌘-click keeps the default browser). Only http(s) loads; other schemes are blocked, and downloads are
  refused. `target=_blank` loads in the same panel (no tabs).
- **Hermes tool**: the app serves an MCP server on `127.0.0.1:<port>/mcp` (default 47615) when Settings ›
  Browser › "Let Hermes use this browser" is on. Hermes connects to it as a normal `mcp_servers:` entry and sees
  `mcp_hermes_mac_client_browser_*` tools.

## Why MCP (not a Hermes plugin)
A plugin (`ctx.register_tool`) runs inside the Hermes process and would need its own channel back to the app
anyway. MCP over Streamable HTTP is already in Hermes (`tools/mcp_tool*.py`), needs zero server-side code,
hot-reloads (the gateway watches config.yaml and connects a new entry within about a minute), and supports
static `headers:` for a bearer token. The SDK's stdio transport is not an option (the app isn't spawned by
Hermes), and Hermes' MCP config has no Unix-socket transport, so TCP on loopback it is.

## Code map
| Layer | File | Notes |
|---|---|---|
| JSON-RPC + MCP lifecycle | `HermesKit/MCP/MCPServerCore.swift` | initialize (echoes 2024-11-05...2025-11-25, else newest), ping, tools/list, tools/call; notifications -> no body |
| HTTP parse + router | `HermesKit/MCP/MCPHTTP.swift` | POST-only JSON responses, no SSE, no session id; GET/HEAD/DELETE 405 |
| config.yaml edit | `HermesKit/MCP/MCPConfigYAML.swift` | line-based upsert/remove of `mcp_servers.hermes_mac`; keeps comments |
| Tool catalog, address parsing | `HermesKit/Browser/BrowserTools.swift` | names, schemas, readOnlyHint; scheme allowlist |
| Socket | `HermesMCPServer/MCPHTTPListener.swift` | Network.framework, 127.0.0.1, `acceptLocalOnly`, no endpoint reuse, one request per connection |
| Tools | `HermesMac/Features/Browser/BrowserAgent.swift` | MainActor, calls serialized FIFO, token in Keychain (`browserToolToken`) |
| Page JS | `HermesMac/Features/Browser/BrowserScript.swift` | runs in `WKContentWorld "hermes-agent"`; refs live in a WeakMap there |
| UI | `BrowserViews.swift`, `BrowserSettings.swift`, `BrowserModel.swift` | |

HermesKit stays pure Foundation (it also compiles on iOS); Network.framework is in its own target and WebKit is
in the app only.

## Tools
`client_browser_navigate(url)`, `_snapshot(full?, max_chars?)`, `_click(ref)`, `_type(ref, text, clear?, submit?)`,
`_press_key(key)`, `_scroll(direction?, amount?, ref?)`, `_back`, `_forward`, `_get_text(max_chars?)`,
`_screenshot` (PNG image content, width capped at 1280), `_wait(text?, seconds?)`. The shapes follow Hermes'
former built-in `browser_*` tools (ref-based, `full` snapshot). navigate/back/forward return a compact snapshot,
so a small model needs fewer round trips.

Snapshot format: `- link "Docs" [ref=e2] -> /docs`, `- textbox "Search" [ref=e4] value="..."`, landmarks indent
their children. Passwords show as `••••`. Refs are stable across snapshots of one document and expire on
navigation. Refs given as `e4`, `@e4`, `ref=e4` or `[e4]` are all accepted.

Limits: clicks and keys are synthetic DOM events (`isTrusted=false`), so a few sites ignore them. Enter in a form
calls `requestSubmit()`, and Tab moves focus by hand. Cross-origin iframes are listed but not entered.

## Control and safety
- The panel opens on any tool call. While Hermes is working it shows "Hermes is …" with Take Over and an accent
  border. Take Over stops the load and makes every tool call return isError "the user has taken control" until
  the user clicks Let Hermes Continue.
- Router gates, in order: path, Host must be loopback (DNS rebinding), any Origin must be loopback, bearer token
  (constant-time compare; an empty token never matches), then POST plus application/json. No CORS headers, so web
  pages, including the panel's own, can't call it.
- The panel uses the default persistent website data store, so Hermes acts with the user's in-panel sign-ins.
  This is the point of the feature, and the Settings copy says so.
- Page text goes to the model and is untrusted. The server `instructions` tell Hermes not to follow instructions
  found on a page.
- A remote Hermes (API URL not loopback) can't reach 127.0.0.1 on this Mac. Settings warns about this. Don't widen
  the bind address without adding TLS.

## Config entry (what "Add to config.yaml" writes)
```yaml
mcp_servers:
  hermes_mac:
    url: "http://127.0.0.1:47615/mcp"
    headers:
      Authorization: "Bearer hm_<64 hex>"
    timeout: 120
    connect_timeout: 10
```
The button refuses to run while Settings › Config has unsaved edits, so it never overwrites a draft. Flow-style
`mcp_servers: {a: ...}` makes the editor throw, so the user pastes the snippet by hand.

## Verifying without the GUI
- `swift run hermes-checks`: MCP core, router gates, YAML editor, address parsing, a real-socket round trip, and
  a check that a second bind of the same port fails.
- `HERMES_MCP_PYTHON=<hermes venv>/bin/python swift run hermes-checks` also runs `scripts/mcp-sdk-probe.py`
  (the official MCP Python SDK, which Hermes uses) against the listener.
- `swiftc -o /tmp/brw-js scripts/browser-js-check.swift && /tmp/brw-js Sources/HermesMac/Features/Browser/BrowserScript.swift`
  runs the page JS in an offscreen WKWebView (snapshot, refs, type, select, contenteditable, click, submit,
  scroll, text, world isolation).
- Logs: `subsystem == "net.jmaddington.hermes"`, grep `MCP-` (listener/protocol) and `BRW-` (panel/tools).
