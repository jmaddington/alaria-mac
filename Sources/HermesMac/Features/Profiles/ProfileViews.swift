import AppKit
import HermesKit
import SwiftUI

// Profile chrome: sidebar switcher, composer @mention layer, key sheet, Settings › Profiles.
// State and routing rules live in ProfileStore / ProfileRouting.

// MARK: - Avatar

/// A profile's initial on a stable per-name tint, so "work" looks the same everywhere it appears.
struct ProfileAvatar: View {
    var name: String
    var size: CGFloat = 20
    static func tint(_ name: String) -> Color {
        let h = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.82)
    }
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.tint(name).gradient))
            .accessibilityHidden(true)
    }
}

/// "@work" as a compact token, used in the composer hint and the Settings list.
struct ProfileToken: View {
    var name: String
    var label: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            ProfileAvatar(name: name, size: 14)
            Text("@\(label ?? name)").font(.caption.weight(.semibold))
        }
        .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
        .background(Capsule().fill(ProfileAvatar.tint(name).opacity(0.16)))
    }
}

// MARK: - Sidebar switcher

struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.tab") private var settingsTab = "connection"

    var body: some View {
        let ps = model.profiles
        if !ps.profiles.isEmpty {
            Menu {
                SwiftUI.Section("Profiles") {
                    ForEach(ps.profiles) { p in
                        Button { Task { await ps.switchTo(p.name) } } label: {
                            if p.name == ps.current { Image(systemName: "checkmark") }
                            Text(p.label)
                            Text(ps.isServed(p.name) ? (p.model ?? "No model set") : "Not served by this gateway")
                        }
                        .disabled(!ps.isServed(p.name) || ps.switching != nil)
                    }
                }
                Divider()
                Button("Manage Profiles…") { settingsTab = "profiles"; openSettings() }
            } label: {
                HStack(spacing: 8) {
                    ProfileAvatar(name: ps.current, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Profile").font(.caption2).foregroundStyle(.secondary)
                        Text(ps.label(ps.current)).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if ps.switching != nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .help("Switch Hermes profile. Each profile has its own model, skills, memory and chats. Type @name in a message to start a chat in another profile.")
            .accessibilityLabel("Profile: \(ps.label(ps.current))")
        }
    }
}

// MARK: - Composer @mentions

/// Composer hook: `.profileMentions(focused:)`. Shows profile suggestions while the draft ends in "@partial"
/// (↑/↓ to move, Return or Tab to pick, Esc to dismiss), otherwise a hint saying where a mention will send.
extension View {
    func profileMentions(focused: Bool) -> some View { modifier(ProfileMentionLayer(focused: focused)) }
}

/// Observable so Esc (dismissedFor) and ↑/↓ (highlight) re-render the list; the monitor itself is not state.
@MainActor @Observable final class MentionKeys {
    var highlight = 0
    var dismissedFor: String?
    @ObservationIgnored var focused = false
    @ObservationIgnored private var monitor: Any?

    func install(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        remove()
        // AIDEV-NOTE: a local monitor, because the multi-line TextField's field editor eats ↑/↓/Return/Tab before
        // SwiftUI .onKeyPress sees them. Installed only while the suggestion list is on screen.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) } ? nil : e
        }
    }
    func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

struct ProfileMentionLayer: ViewModifier {
    @Environment(AppModel.self) private var model
    var focused: Bool
    @ViewState private var keys = MentionKeys()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                layer
                    .padding(.leading, 36)
                    .alignmentGuide(.top) { $0[.bottom] - 2 } // sit just above the composer
                    .animation(.smooth(duration: 0.18), value: model.chats.draft.isEmpty)
            }
            .onChange(of: focused) { keys.focused = focused }
            .onAppear { keys.focused = focused }
    }

    private var query: String? {
        let d = model.chats.draft
        guard model.profiles.isMulti, keys.dismissedFor != d else { return nil }
        return ProfileMention.completionQuery(in: d)
    }
    private var items: [HermesProfile] {
        guard let q = query else { return [] }
        return Array(ProfileMention.suggestions(q, in: model.profiles.profiles).prefix(6))
    }

    @ViewBuilder private var layer: some View {
        let list = items
        if !list.isEmpty {
            suggestions(list)
                .onAppear { setHighlight(0); keys.install(handle) }
                .onDisappear { keys.remove() }
                .onChange(of: query) { setHighlight(0) }
        } else {
            hint
        }
    }

    private func suggestions(_ list: [HermesProfile]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Send to profile").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                Button { pick(p) } label: { suggestionRow(p, selected: i == keys.highlight) }
                    .buttonStyle(.plain)
                    .onHover { if $0 { setHighlight(i) } }
            }
        }
        .padding(4)
        .frame(width: 320, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile suggestions")
    }

    private func suggestionRow(_ p: HermesProfile, selected: Bool) -> some View {
        let ps = model.profiles
        let served = ps.isServed(p.name)
        return HStack(spacing: 9) {
            ProfileAvatar(name: p.name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("@\(p.name)").font(.callout.weight(.semibold))
                    if p.name == ps.current { Text("current").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(subtitle(p, served: served)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "return").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
        .opacity(served ? 1 : 0.55)
        .contentShape(Rectangle())
        .accessibilityLabel("\(p.label)\(served ? "" : ", not served")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func subtitle(_ p: HermesProfile, served: Bool) -> String {
        if !served { return "Not served by this gateway" }
        if let d = p.description, !d.isEmpty { return d }
        return p.model ?? "No model set"
    }

    @ViewBuilder private var hint: some View {
        let ps = model.profiles
        switch ps.route(for: model.chats.draft, inChat: model.chats.selection != nil) {
        case .none: EmptyView()
        case .here(let name):
            hintBox { ProfileToken(name: name); Text("This profile").foregroundStyle(.secondary) }
        case .newChat(let name, let fromChat):
            hintBox {
                ProfileToken(name: name)
                Text(fromChat ? "Starts a new chat in \(ps.label(name)). This chat stays in \(ps.label(ps.current))."
                              : "Sends to \(ps.label(name)) as a new chat.")
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let name):
            hintBox {
                ProfileToken(name: name)
                Label("Not served by this gateway", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func hintBox<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func setHighlight(_ i: Int) { keys.highlight = i }

    private func pick(_ p: HermesProfile) {
        model.chats.draft = ProfileMention.complete(model.chats.draft, with: p.name)
    }

    /// Key monitor: only while the composer has focus and suggestions are showing. Returns true = consumed.
    private func handle(_ e: NSEvent) -> Bool {
        guard keys.focused else { return false }
        let list = items
        guard !list.isEmpty else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 126: setHighlight(max(0, keys.highlight - 1)); return true              // up
        case 125: setHighlight(min(list.count - 1, keys.highlight + 1)); return true // down
        case 36, 76, 48:                                                              // return, enter, tab
            guard mods.isEmpty else { return false } // Option-Return still inserts a newline
            pick(list[min(keys.highlight, list.count - 1)]); return true
        case 53: keys.dismissedFor = model.chats.draft; keys.remove(); return true   // esc
        default: return false
        }
    }
}

/// A user message with its leading/first @profile mention tinted, in history too (the text is sent verbatim).
enum MentionStyle {
    @MainActor static func attributed(_ text: String, _ ps: ProfileStore) -> AttributedString {
        var a = AttributedString(text)
        guard ps.isMulti, let m = ProfileMention.find(in: text, profiles: ps.profiles.map(\.name)),
              let r = Range(m.range, in: a) else { return a }
        a[r].foregroundColor = ProfileAvatar.tint(m.profile)
        a[r].font = .body.weight(.semibold)
        return a
    }
}

// MARK: - Key sheet

private struct ProfileKeyRequest: Identifiable { let id: String }

extension View {
    /// RootView hook: presents the "this profile needs its own key" sheet when a switch gets a 401.
    func profileSheets(_ model: AppModel) -> some View {
        sheet(item: Binding(get: { model.profiles.keyPrompt.map(ProfileKeyRequest.init) },
                            set: { if $0 == nil { model.profiles.keyPrompt = nil } })) { req in
            ProfileKeySheet(name: req.id).environment(model)
        }
    }
}

struct ProfileKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var name: String
    @ViewState private var manualKey = ""
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        let ps = model.profiles
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProfileAvatar(name: name, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("“\(ps.label(name))” needs its own API key").font(.title3.weight(.semibold))
                    Text("Each Hermes profile has its own API_SERVER_KEY, so your main key can't open this one.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a key for this profile").font(.headline)
                    Text("Writes a new random key into the profile's .env through the dashboard and saves it in your Keychain. Takes effect right away.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Create Key and Switch") { run { try await ps.provisionKey(for: name) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or use the key it already has").font(.headline)
                    HStack {
                        SecureField("API_SERVER_KEY from the profile's .env", text: $manualKey)
                        Button("Save") {
                            run { guard ps.saveKey(manualKey.trimmingCharacters(in: .whitespacesAndNewlines), for: name) else {
                                throw HermesError(status: 0, message: "Couldn't save the key to your Keychain") } }
                        }.disabled(manualKey.trimmingCharacters(in: .whitespaces).count < 16)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { ps.pendingMessage = nil; ps.keyPrompt = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .disabled(busy)
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await body()
                await model.profiles.retryAfterKey(name) // closes the sheet (keyPrompt = nil), or reopens on another 401
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings › Profiles

struct ProfilesPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var creating = false
    @ViewState private var deleting: HermesProfile?
    @ViewState private var editing: HermesProfile?
    @ViewState private var descriptionDraft = ""

    var body: some View {
        let ps = model.profiles
        VStack(spacing: 0) {
            if model.client?.hasDashboard != true {
                EmptyState(symbol: "person.2", title: "Profiles need the dashboard",
                           message: "Connect the Hermes dashboard in Connection to list, switch and create profiles.")
            } else {
                List {
                    ForEach(ps.profiles) { p in row(p).padding(.vertical, 4) }
                }
                .listStyle(.inset)
                .overlay { if ps.profiles.isEmpty { ProgressView() } }
            }
            Divider()
            HStack {
                Text("Each profile is a separate Hermes home: its own model, skills, memory, jobs and chats. Type @name in a message to start a chat in another profile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("New Profile…") { creating = true }.disabled(model.client?.hasDashboard != true)
            }
            .padding(12)
        }
        .frame(height: 440)
        .task { await ps.load() }
        .sheet(isPresented: $creating) { NewProfileSheet().environment(model) }
        .confirmationDialog("Delete the profile “\(deleting?.label ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                if let d = deleting { model.run("Delete profile") { try await ps.delete(d.name) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This deletes its home folder on the server: config, skills, memory, jobs and every chat in it. It can't be undone.") }
        .alert("Description", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("What this profile is for", text: $descriptionDraft)
            Button("Save") {
                if let e = editing { let t = descriptionDraft; model.run("Save description") { try await ps.setDescription(e.name, t) } }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private func row(_ p: HermesProfile) -> some View {
        let ps = model.profiles
        let served = ps.isServed(p.name)
        return HStack(alignment: .top, spacing: 12) {
            ProfileAvatar(name: p.name, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.label).font(.body.weight(.semibold))
                    if p.name == ps.current { Pill(text: "Current", color: Theme.accent) }
                    if !served { Pill(text: "Not served", color: .orange) }
                }
                Text([p.model, p.provider].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "No model set")
                    .font(.callout).foregroundStyle(.secondary)
                if let d = p.description, !d.isEmpty { Text(d).font(.callout).lineLimit(2) }
                Text(keyStatus(p)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if p.name != ps.current && served {
                Button("Switch") { Task { await ps.switchTo(p.name) } }.disabled(ps.switching != nil)
            }
            Menu {
                if p.name != ps.own { Button("Set API Key…") { ps.keyPrompt = p.name } }
                Button("Edit Description…") { descriptionDraft = p.description ?? ""; editing = p }
                if p.name != ps.own && p.isDefault != true {
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = p }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(p.label)")
        }
    }

    private func keyStatus(_ p: HermesProfile) -> String {
        let ps = model.profiles
        if p.name == ps.own { return "The gateway's own profile · uses your main API key" }
        return ps.storedKey(p.name) != nil ? "Its own API key is saved in your Keychain" : "No API key saved yet · you'll be asked when you switch"
    }
}

struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var details = ""
    @ViewState private var cloneCurrent = true
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        let ps = model.profiles
        let n = HermesProfile.normalize(name)
        let exists = ps.profiles.contains { $0.name == n }
        VStack(alignment: .leading, spacing: 0) {
            Text("New Profile").font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("work"))
                TextField("Description", text: $details, prompt: Text("What this profile is for"))
                Toggle("Copy settings, skills and persona from “\(ps.label(ps.current))”", isOn: $cloneCurrent)
            }
            .formStyle(.grouped)
            Group {
                if !n.isEmpty && !HermesProfile.isValidNewName(n) {
                    Text("Use lowercase letters, numbers, - or _, starting with a letter or number. “default” and “hermes” are taken.")
                } else if exists {
                    Text("A profile named “\(n)” already exists.")
                } else {
                    Text("Talaria also gives the profile its own API key so you can chat with it right away.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).padding(.horizontal, 20).padding(.top, 6) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    busy = true; error = nil
                    Task {
                        defer { busy = false }
                        do { try await ps.create(n, description: details.trimmingCharacters(in: .whitespaces), cloneCurrent: cloneCurrent); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!HermesProfile.isValidNewName(n) || exists || busy)
            }
            .padding(20)
        }
        .frame(width: 460)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
