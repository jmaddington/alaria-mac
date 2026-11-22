import AppKit
import HermesKit
import SwiftUI

/// Settings › Browser: chat-link behavior and "Let Hermes use this browser" (MCP server + config.yaml entry).
struct BrowserSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("browser.openChatLinks") private var openChatLinks = true
    @AppStorage(BrowserAgent.enabledKey) private var agentEnabled = false
    @AppStorage(BrowserAgent.portKey) private var portSetting = Int(BrowserToolCatalog.defaultPort)
    @ViewState private var showToken = false
    @ViewState private var inConfig: Bool?
    @ViewState private var writing = false
    @ViewState private var portText = ""

    var body: some View {
        let agent = model.browser.agent
        Form {
            SwiftUI.Section {
                Toggle("Open links from chats in the browser panel", isOn: $openChatLinks)
            } footer: { Text("⌘-click a link to open it in your default browser instead.") }

            SwiftUI.Section {
                Toggle("Let Hermes use this browser", isOn: Binding(get: { agentEnabled }, set: { agent.setEnabled($0) }))
                LabeledContent("Status") { statusText(agent.state) }
                HStack {
                    TextField("Port", text: $portText, prompt: Text("\(BrowserToolCatalog.defaultPort)"))
                        .frame(maxWidth: 160)
                        .onSubmit(applyPort)
                    Button("Apply") { applyPort() }.disabled(UInt16(portText) == agent.port)
                }
                if agentEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("config.yaml").font(.caption).foregroundStyle(.secondary)
                        Text(showToken ? agent.configSnippet : agent.configSnippet.replacingOccurrences(of: agent.token, with: String(repeating: "•", count: 16)))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        HStack {
                            Button(showToken ? "Hide Token" : "Show Token") { showToken.toggle() }
                            Button("Copy Snippet") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(agent.configSnippet, forType: .string)
                                model.flash("Copied the config.yaml snippet")
                            }
                            Spacer()
                            Button("New Token") { agent.regenerateToken(); inConfig = nil }
                                .help("Invalidates the token Hermes has. Add to config.yaml again afterwards.")
                        }
                        HStack {
                            if let inConfig { Text(inConfig ? "✓ In config.yaml" : "Not in config.yaml yet").font(.caption).foregroundStyle(inConfig ? .green : .secondary) }
                            Spacer()
                            if inConfig == true {
                                Button("Remove from config.yaml") { Task { await write(add: false) } }.disabled(writing)
                            }
                            Button(inConfig == true ? "Update config.yaml" : "Add to config.yaml") { Task { await write(add: true) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(writing || model.client?.hasDashboard != true)
                        }
                    }
                }
            } header: { Text("Let Hermes use this browser") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hermes gets client_browser_* tools (navigate, snapshot, click, type, scroll, screenshot…) that drive the panel. It opens automatically so you can watch, and Take Over pauses Hermes. It uses the panel's sign-ins, so only allow this for a Hermes you trust.")
                    Text("The tools listen on 127.0.0.1 only, protected by a token kept in your Keychain. Hermes picks up a config.yaml change within about a minute, or after a gateway restart.")
                    if let host = remoteHermesHost {
                        Label("Hermes runs on \(host). It can only reach this browser when the gateway runs on this Mac.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if model.client?.hasDashboard != true { Text("Connect the dashboard to add the snippet automatically, or paste it into config.yaml yourself.") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = "\(agent.port)" }
        .task(id: agentEnabled) { await refreshInConfig() }
    }

    private var remoteHermesHost: String? {
        guard let h = URL(string: model.settings.apiURL)?.host()?.lowercased() else { return nil }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(h) ? nil : h
    }

    @ViewBuilder private func statusText(_ s: BrowserAgent.ServerState) -> some View {
        switch s {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .listening(let p): Text("Listening on 127.0.0.1:\(String(p))").foregroundStyle(.green)
        case .failed(let e): Text(e).foregroundStyle(.red)
        }
    }

    private func applyPort() {
        guard let p = UInt16(portText.trimmingCharacters(in: .whitespaces)), p >= 1024 else {
            model.flash("Port must be a number from 1024 to 65535"); portText = "\(model.browser.agent.port)"; return
        }
        portSetting = Int(p)
        inConfig = nil
        if agentEnabled { model.browser.agent.start() }
    }

    private func refreshInConfig() async {
        guard agentEnabled, let c = model.client, c.hasDashboard else { inConfig = nil; return }
        do {
            let yaml = try await c.rawConfig().yaml
            inConfig = yaml.contains(model.browser.agent.token) && yaml.contains("127.0.0.1:\(model.browser.agent.port)/mcp")
        } catch { model.report("Couldn't read config.yaml", error) }
    }

    /// GET raw config, edit only the hermes_mac entry, PUT it back.
    private func write(add: Bool) async {
        guard let c = model.client, c.hasDashboard else { return }
        writing = true; defer { writing = false }
        let agent = model.browser.agent
        if model.library.configDraft != nil {
            model.flash("Save or revert your unsaved edits in Settings › Config first.")
            return
        }
        do {
            let yaml = try await c.rawConfig().yaml
            let updated = add ? try MCPConfigYAML.upsert(yaml, entry: MCPConfigYAML.entry(port: agent.port, token: agent.token))
                              : try MCPConfigYAML.remove(yaml)
            if updated != yaml { try await c.saveRawConfig(updated) }
            await refreshInConfig()
            model.flash(add ? "Added hermes_mac to config.yaml. Hermes picks it up within a minute." : "Removed hermes_mac from config.yaml")
        } catch {
            model.report(add ? "Couldn't add the browser tool to config.yaml" : "Couldn't update config.yaml", error)
        }
    }
}
