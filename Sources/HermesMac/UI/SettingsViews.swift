import AppKit
import AVFAudio
import HermesKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionPane().tabItem { Label("Connection", systemImage: "network") }
            VoicePane().tabItem { Label("Voice", systemImage: "waveform") }
            ModelPane().tabItem { Label("Model", systemImage: "cpu") }
            ConfigPane().tabItem { Label("Config", systemImage: "doc.text") }
        }
        .frame(width: 600)
    }
}

struct ConnectionForm: View {
    @Binding var draft: ConnectionSettings
    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("URL", text: $draft.apiURL, prompt: Text("http://127.0.0.1:8642"))
                SecureField("API key", text: $draft.apiKey, prompt: Text("API_SERVER_KEY"))
            } header: { Text("API Server") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chats, sessions and scheduled jobs. Runs inside `hermes gateway`; the key is API_SERVER_KEY.")
                    if Self.sendsKeyInClear(draft.apiURL) { Self.cleartextWarning }
                }
            }
            SwiftUI.Section {
                TextField("URL", text: $draft.dashboardURL, prompt: Text("http://127.0.0.1:9119"))
                SecureField("Session token", text: $draft.dashboardToken, prompt: Text("HERMES_DASHBOARD_SESSION_TOKEN"))
            } header: { Text("Dashboard (optional)") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unlocks skills editing, search, tools, memory, usage and logs. Start it with `hermes serve` or `hermes dashboard` and set HERMES_DASHBOARD_SESSION_TOKEN.")
                    if Self.sendsKeyInClear(draft.dashboardURL) { Self.cleartextWarning }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func sendsKeyInClear(_ s: String) -> Bool { ConnectionSecurity.sendsKeyInClear(s) }
    static var cleartextWarning: some View {
        Label("This sends your key unencrypted over the internet. Use https, or a Tailscale/LAN address.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    @MainActor static func test(_ s: ConnectionSettings) async -> String {
        if ConnectionSettings.validURL(s.apiURL) == nil { return "Enter the API server URL, like http://127.0.0.1:8642." }
        if !s.dashboardURL.isEmpty, ConnectionSettings.validURL(s.dashboardURL) == nil { return "Enter the dashboard URL, like http://127.0.0.1:9119." }
        guard let c = s.makeClient() else { return "Enter the API key." }
        do {
            let h = try await c.health()
            _ = try await c.sessions(limit: 1)
            let v = h.version.flatMap { $0 == "unknown" || $0.isEmpty ? nil : " v\($0)" } ?? ""
            var msg = "✓ API server\(v) reachable and key accepted."
            if c.hasDashboard {
                do { _ = try await c.dashboardStatus(); _ = try await c.skills(); msg += " Dashboard OK." }
                catch { return "API OK, but the dashboard failed: \(error.localizedDescription)" }
            }
            return msg
        } catch { return error.localizedDescription }
    }
}

struct ConnectionPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var draft = ConnectionSettings()
    @ViewState private var result: String?
    var body: some View {
        VStack(spacing: 0) {
            ConnectionForm(draft: $draft)
            HStack {
                if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("✓") ? .green : .red).lineLimit(2) }
                Spacer()
                Button("Test") { Task { result = await ConnectionForm.test(draft) } }
                Button("Save") { model.apply(draft); result = nil }.buttonStyle(.borderedProminent)
                    .disabled(draft == model.settings || ConnectionSettings.validURL(draft.apiURL) == nil
                              || (!draft.dashboardURL.isEmpty && ConnectionSettings.validURL(draft.dashboardURL) == nil))
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .onAppear { draft = model.settings }
    }
}

struct VoicePane: View {
    @AppStorage("voice.stt") private var stt = VoiceSTT.apple.rawValue
    @AppStorage("voice.tts") private var tts = VoiceTTS.system.rawValue
    @AppStorage("voice.systemVoice") private var systemVoice = ""
    @AppStorage("voice.openaiVoice") private var openaiVoice = "onyx"
    @AppStorage("voice.localURL") private var localURL = "http://127.0.0.1:8880/v1/audio/speech"
    @AppStorage("voice.localModel") private var localModel = "mlx-community/Kokoro-82M-bf16"
    @AppStorage("voice.localVoice") private var localVoice = "af_heart"
    @AppStorage("voice.speed") private var speed: Double = 1.0
    @AppStorage("voice.googleVoice") private var googleVoice = "en-US-Chirp3-HD-Aoede"
    @ViewState private var googleKey = Keychain.get("googleKey") ?? ""
    @ViewState private var googleVoices: [String] = []
    /// Shown before the voices list loads (or without a key): the Chirp 3 HD set.
    static let chirpVoices = ["Aoede", "Kore", "Leda", "Zephyr", "Puck", "Charon", "Fenrir", "Orus"].map { "en-US-Chirp3-HD-\($0)" }
    @AppStorage("voice.sttModel") private var sttModel = "gpt-transcribe"
    @AppStorage("voice.sttPrompt") private var sttPrompt = ""
    @AppStorage("voice.bargeIn") private var bargeIn = true
    @AppStorage("voice.rate") private var rate: Double = 0.52
    @ViewState private var key = Keychain.get("openaiKey") ?? ""
    @ViewState private var previewing = false
    @ViewState private var previewError: String?
    /// Kokoro-82M's American/British English voices (id, label). Other OpenAI-compatible servers: type any id.
    static let kokoroVoices = [("af_heart", "Heart (US)"), ("af_bella", "Bella (US)"), ("af_nicole", "Nicole (US)"),
                               ("af_sky", "Sky (US)"), ("am_michael", "Michael (US)"), ("am_fenrir", "Fenrir (US)"),
                               ("am_puck", "Puck (US)"), ("bf_emma", "Emma (UK)"), ("bm_george", "George (UK)"),
                               ("bm_fable", "Fable (UK)")]

    var body: some View {
        Form {
            SwiftUI.Section("Listening") {
                Picker("Transcription", selection: $stt) { ForEach(VoiceSTT.allCases) { Text($0.label).tag($0.rawValue) } }
                if stt == VoiceSTT.openai.rawValue { TextField("Model", text: $sttModel) }
                TextField("Vocabulary hint", text: $sttPrompt, prompt: Text("Names and jargon to expect"), axis: .vertical).lineLimit(1...3)
                Toggle("Interrupt by speaking", isOn: $bargeIn)
            }
            SwiftUI.Section("Speaking") {
                Picker("Voice engine", selection: $tts) { ForEach(VoiceTTS.allCases) { Text($0.label).tag($0.rawValue) } }
                if tts == VoiceTTS.system.rawValue {
                    Picker("Voice", selection: $systemVoice) {
                        Text("Best available").tag("")
                        ForEach(SystemVoice.voices(), id: \.identifier) { v in
                            Text("\(v.name)  \(quality(v))").tag(v.identifier)
                        }
                    }
                    Slider(value: $rate, in: 0.4...0.62) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    Button(previewing ? "Playing…" : "Preview") { Task { await preview() } }.disabled(previewing)
                } else if tts == VoiceTTS.local.rawValue {
                    TextField("Server", text: $localURL, prompt: Text("http://127.0.0.1:8880/v1/audio/speech"))
                    TextField("Model", text: $localModel)
                    Picker("Voice", selection: $localVoice) {
                        ForEach(Self.kokoroVoices, id: \.0) { Text($0.1).tag($0.0) }
                        if !Self.kokoroVoices.contains(where: { $0.0 == localVoice }) { Text(localVoice).tag(localVoice) }
                    }
                    Slider(value: $speed, in: 0.8...1.4, step: 0.05) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    Button(previewing ? "Playing…" : "Preview") { Task { await preview() } }.disabled(previewing)
                    if let previewError { Text(previewError).font(.caption).foregroundStyle(.red) }
                } else if tts == VoiceTTS.google.rawValue {
                    SecureField("Google Cloud API key", text: $googleKey, prompt: Text(googleKey.isEmpty ? "AIza…" : "Saved in Keychain"))
                        .onChange(of: googleKey) { Keychain.set("googleKey", googleKey); Task { await loadGoogleVoices() } }
                    Picker("Voice", selection: $googleVoice) {
                        ForEach(googleVoices.isEmpty ? Self.chirpVoices : googleVoices, id: \.self) { Text(Self.googleLabel($0)).tag($0) }
                        if !(googleVoices.isEmpty ? Self.chirpVoices : googleVoices).contains(googleVoice) { Text(Self.googleLabel(googleVoice)).tag(googleVoice) }
                    }
                    Slider(value: $speed, in: 0.8...1.4, step: 0.05) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    Button(previewing ? "Playing…" : "Preview") { Task { await preview() } }.disabled(previewing || googleKey.isEmpty)
                    if let previewError { Text(previewError).font(.caption).foregroundStyle(.red) }
                    Text("Uses Google Cloud Text-to-Speech (Chirp 3 HD voices). Create a key restricted to the Text-to-Speech API in Google Cloud Console.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Voice", selection: $openaiVoice) {
                        ForEach(["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Slider(value: $speed, in: 0.8...1.4, step: 0.05) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    Button(previewing ? "Playing…" : "Preview") { Task { await preview() } }.disabled(previewing || key.isEmpty)
                    if let previewError { Text(previewError).font(.caption).foregroundStyle(.red) }
                }
            }
            SwiftUI.Section {
                SecureField("OpenAI API key", text: $key, prompt: Text(key.isEmpty ? "sk-…" : "Saved in Keychain")) // hermes-mac-ich
                    .onChange(of: key) { Keychain.set("openaiKey", key) }
            } footer: {
                Text("Only needed for OpenAI transcription or voices; stored in your Keychain. On-device options keep audio on this Mac.\nLocal server: any OpenAI-compatible speech server running on your Mac or network, such as Kokoro.\nTip: download Premium voices in System Settings › Accessibility › Spoken Content.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
        .task(id: tts) { if tts == VoiceTTS.google.rawValue { await loadGoogleVoices() } }
    }

    /// "en-US-Chirp3-HD-Aoede" -> "Aoede (Chirp 3 HD)".
    static func googleLabel(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count >= 3 else { return name }
        let kind = parts.dropFirst(2).dropLast().joined(separator: " ").replacingOccurrences(of: "Chirp3 HD", with: "Chirp 3 HD")
        return "\(parts.last!) (\(kind))"
    }

    private func loadGoogleVoices() async {
        guard !googleKey.isEmpty else { googleVoices = []; return }
        do { googleVoices = try await GoogleVoice.voices(apiKey: googleKey) } catch { googleVoices = [] }
    }

    private func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality { case .premium: "· Premium"; case .enhanced: "· Enhanced"; default: "" }
    }

    private func preview() async {
        previewing = true; defer { previewing = false }
        let audio = VoiceAudio()
        do {
            try audio.startPlaybackOnly()
            let line = "Hi, I'm Hermes. How can I help?"
            let buf: AVAudioPCMBuffer
            switch VoiceTTS(rawValue: tts) ?? .system {
            case .local: buf = try await VoicePrefs.localVoice().render(line)
            case .openai: buf = try await OpenAIVoice(apiKey: key, voice: openaiVoice, speed: speed).render(line)
            case .google: buf = try await GoogleVoice(apiKey: googleKey, voice: googleVoice, speakingRate: speed).render(line)
            case .system: buf = try await SystemVoice(voiceIdentifier: systemVoice.isEmpty ? nil : systemVoice, rate: Float(rate)).render(line)
            }
            previewError = nil
            await audio.play(buf)
        } catch { previewError = error.localizedDescription }
        audio.stop()
    }
}

struct ModelPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var info: ModelInfo?
    @ViewState private var providers: [ProviderOption] = []
    @ViewState private var provider = ""
    @ViewState private var modelID = ""
    var body: some View {
        Form {
            SwiftUI.Section("Current") {
                LabeledContent("Model") { Text(info?.model ?? "—").textSelection(.enabled) }
                LabeledContent("Provider") { Text(info?.provider.map { p in providers.first { $0.slug == p }?.name ?? p } ?? "—") }
                if let c = info?.effectiveContextLength { LabeledContent("Context") { Text("\(c.compact) tokens") } }
            }
            SwiftUI.Section {
                Picker("Provider", selection: $provider) {
                    ForEach(providers.filter { $0.authenticated == true || $0.isCurrent == true || !$0.modelIDs.isEmpty }) { Text($0.name ?? $0.slug).tag($0.slug) }
                }
                // A new provider never keeps the old provider's model id (hermes-mac-mg9).
                .onChange(of: provider) { old, new in
                    guard !old.isEmpty, old != new else { return }
                    modelID = providers.first { $0.slug == new }?.modelIDs.first ?? ""
                }
                let ids = providers.first { $0.slug == provider }?.modelIDs ?? []
                if ids.isEmpty { TextField("Model", text: $modelID) }
                else { Picker("Model", selection: $modelID) { ForEach(ids, id: \.self) { Text($0).tag($0) } } }
                Button("Switch Model") {
                    guard let c = model.client else { return }
                    model.run("Switch model") { try await c.setModel(provider: provider, model: modelID); info = try await c.modelInfo(); model.flash("Now using \(modelID)") }
                }
                .disabled(provider.isEmpty || modelID.isEmpty || model.client?.hasDashboard != true)
            } header: { Text("Change") } footer: { Text("Changes the default model for new turns. Requires the dashboard connection.") }
        }
        .formStyle(.grouped)
        .task {
            guard let c = model.client else { return }
            do {
                info = try await c.modelInfo()
                providers = try await c.modelOptions()
            } catch { model.report("Couldn't load models", error) }
            modelID = info?.model ?? ""
            provider = providers.first { $0.isCurrent == true }?.slug ?? info?.provider ?? ""
        }
    }
}

struct ConfigPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var yaml = ""
    @ViewState private var original = ""
    @ViewState private var path: String?
    /// Editing (and Save) only after a successful load: an empty buffer saved over config.yaml wipes it (hermes-mac-vp6).
    @ViewState private var loaded = false
    @ViewState private var loadError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.client?.hasDashboard != true {
                Text("Connect the dashboard to edit config.yaml.").foregroundStyle(.secondary).padding()
            } else if let loadError {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load config.yaml", message: loadError, action: ("Try Again", { Task { await load() } })).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(path ?? "config.yaml").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextEditor(text: Binding(get: { yaml }, set: { yaml = $0; model.library.configDraft = $0 == original ? nil : $0 })).font(Font(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))) // NSTextView ignores .monospaced design
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .frame(minHeight: 380)
                HStack {
                    Text("Some changes need a gateway restart to take effect.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { yaml = original; model.library.configDraft = nil }.disabled(yaml == original)
                    Button("Save") {
                        guard let c = model.client else { return }
                        model.run("Save config") { try await c.saveRawConfig(yaml); original = yaml; model.library.configDraft = nil; model.flash("Saved config.yaml") }
                    }.buttonStyle(.borderedProminent).disabled(yaml == original)
                }
            }
        }
        .padding(20)
        .task(id: model.client?.hasDashboard) { await load() }
    }

    private func load() async {
        guard let c = model.client, c.hasDashboard else { return }
        loadError = nil
        do {
            let r = try await c.rawConfig()
            original = r.yaml; path = r.path; loaded = true
            yaml = model.library.configDraft ?? r.yaml // resume unsaved edits
        } catch { loadError = error.localizedDescription }
    }
}
