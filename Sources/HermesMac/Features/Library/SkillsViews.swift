import AppKit
import HermesKit
import SwiftUI

struct SkillsList: View {
    @Environment(AppModel.self) private var model
    @ViewState private var creating = false

    var body: some View {
        @Bindable var lib = model.library
        Group {
            if model.client?.hasDashboard != true { NeedsDashboard(feature: "Skills") }
            else {
                List(selection: $lib.skillSelection) {
                    ForEach(categories, id: \.self) { cat in
                        SwiftUI.Section(Self.title(cat)) {
                            ForEach(filtered.filter { Self.cat($0) == cat }) { s in
                                SkillRow(skill: s).hoverRow().tag(Optional(s.name))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .searchable(text: $lib.skillFilter, placement: .sidebar, prompt: "Filter skills")
                .overlay { if lib.skills.isEmpty && lib.skillsLoading { ProgressView() } }
                .refreshable { await lib.loadSkills() }
            }
        }
        .navigationTitle("Skills")
        .navigationSubtitle(lib.skills.isEmpty ? "" : "\(lib.skills.count) installed")
        .toolbar { ToolbarItem { Button { creating = true } label: { Label("New Skill", systemImage: "plus") }.disabled(model.client?.hasDashboard != true) } }
        .sheet(isPresented: $creating) { NewSkillSheet().environment(model) }
        .task { if lib.skills.isEmpty { await lib.loadSkills() } }
    }

    private var filtered: [Skill] {
        let q = model.library.skillFilter.lowercased()
        return model.library.skills.filter { q.isEmpty || $0.name.contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }
    /// Uncategorised skills group under "Other", which always sorts last.
    private var categories: [String] {
        Array(Set(filtered.map(Self.cat))).sorted { ($0 == "other" ? 1 : 0, $0) < ($1 == "other" ? 1 : 0, $1) }
    }
    static func cat(_ s: Skill) -> String { (s.category ?? "").isEmpty ? "other" : s.category!.lowercased() }
    static func title(_ c: String) -> String {
        c.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { ["ai", "ml", "api", "mcp", "ui", "cli", "llm"].contains($0.lowercased()) ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }
}

struct SkillRow: View {
    var skill: Skill
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(skill.name).font(.body.weight(.medium)).lineLimit(1)
                    if skill.locked == true { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(skill.description ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .opacity(skill.enabled == false ? 0.5 : 1)
        .padding(.vertical, 2)
    }
}

struct SkillDetail: View {
    @Environment(AppModel.self) private var model
    @ViewState private var content = ""
    @ViewState private var original = ""
    @ViewState private var path: String?
    /// Server paths are long and absolute; show from the skills root down ("skills/apple/notes/SKILL.md").
    static func shortPath(_ p: String) -> String {
        if let r = p.range(of: "/skills/", options: .backwards) { return "skills/" + p[r.upperBound...] }
        return (p as NSString).abbreviatingWithTildeInPath
    }
    @ViewState private var loading = false
    /// Name of the skill whose text is in the editor. nil while loading or after a failed load.
    // AIDEV-NOTE: data-loss guard (hermes-mac-ilw): Save must only ever write text loaded for that same skill.
    @ViewState private var loadedName: String?
    @ViewState private var loadError: String?
    @ViewState private var saving = false
    @ViewState private var preview = false
    @ViewState private var confirmUninstall = false

    private var skill: Skill? { model.library.skills.first { $0.name == model.library.skillSelection } }
    private var dirty: Bool { loadedName != nil && loadedName == skill?.name && content != original }

    var body: some View {
        Group {
            if model.client?.hasDashboard != true { Color.clear }
            else if let skill {
                VStack(spacing: 0) {
                    header(skill)
                    Divider()
                    if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let loadError {
                        VStack(spacing: 12) {
                            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open \(skill.name)", message: loadError)
                            Button("Try Again") { Task { await load(skill.name) } }
                        }
                    } else if loadedName != skill.name {
                        Color.clear
                    } else if preview {
                        ScrollView { MarkdownView(text: stripFrontMatter(content)).frame(maxWidth: Theme.readingWidth).padding(32).frame(maxWidth: .infinity) }
                    } else {
                        TextEditor(text: Binding(get: { content }, set: { v in
                            content = v
                            model.library.skillDrafts[skill.name] = v == original ? nil : v
                        }))
                            .font(Font(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .disabled(skill.locked == true)
                            // NSTextView-backed editors report the full text height as ideal; cap it so a long SKILL.md
                            // can't push the whole window layout up under the title bar (hermes-mac-x0h).
                            .frame(minHeight: 0, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .task(id: skill.name) { await load(skill.name) }
            } else {
                EmptyState(symbol: "sparkles.rectangle.stack", title: "Select a skill",
                           message: "Skills teach Hermes how to do things. Choose one to read or edit its SKILL.md.")
            }
        }
        .navigationTitle(skill?.name ?? "Skills")
        .toolbar {
            if skill != nil {
                ToolbarItem {
                    Picker("Mode", selection: $preview) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(false).help("Edit")
                        Image(systemName: "doc.richtext").tag(true).help("Preview")
                    }.pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button("Revert") { content = original; if let n = skill?.name { model.library.skillDrafts[n] = nil } }.disabled(!dirty)
                }
                ToolbarItem {
                    Button { Task { await save() } } label: { Text(saving ? "Saving…" : "Save") }
                        .buttonStyle(.borderedProminent).disabled(!dirty || saving).keyboardShortcut("s")
                }
            }
        }
        .confirmationDialog("Uninstall \(skill?.name ?? "")?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                guard let s = skill, let client = model.client else { return }
                model.run("Uninstall") { try await client.uninstallSkill(s.name); model.library.skillSelection = nil; await model.library.loadSkills() }
            }
        } message: { Text("This removes the skill from Hermes.") }
    }

    private func header(_ s: Skill) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(s.name).font(.title2.weight(.semibold))
                    if let p = s.provenance { Pill(text: p, color: p == "agent" ? .purple : p == "hub" ? .blue : .secondary) }
                    if dirty { Pill(text: "Edited", color: .orange) }
                }
                Text(s.description ?? "").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let path { Text(Self.shortPath(path)).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Enabled", isOn: Binding(get: { s.enabled ?? true }, set: { v in
                    guard let c = model.client else { return }
                    model.run("Enable") { try await c.setSkill(s.name, enabled: v); await model.library.loadSkills() }
                })).toggleStyle(.switch).controlSize(.small)
                Toggle("Locked", isOn: Binding(get: { s.locked ?? false }, set: { v in
                    guard let c = model.client else { return }
                    model.run("Lock") { try await c.setSkill(s.name, locked: v); await model.library.loadSkills() }
                })).toggleStyle(.switch).controlSize(.small)
                if s.provenance == "hub" { Button("Uninstall…", role: .destructive) { confirmUninstall = true }.controlSize(.small) }
            }
        }
        .padding(20)
    }

    private func load(_ name: String) async {
        guard let client = model.client else { return }
        // Drop the previous skill's text first, so it can never be shown or saved under this name.
        loadedName = nil; loadError = nil; content = ""; original = ""; path = nil
        loading = true
        do {
            let c = try await client.skillContent(name)
            guard model.library.skillSelection == name, !Task.isCancelled else { return } // superseded by a newer selection
            original = c.content; path = c.path; loadedName = name
            content = model.library.skillDrafts[name] ?? c.content // resume unsaved edits
        } catch is CancellationError {
            return
        } catch {
            guard model.library.skillSelection == name else { return }
            loadError = error.localizedDescription
        }
        if model.library.skillSelection == name { loading = false }
    }

    private func save() async {
        guard let client = model.client, let s = skill, loadedName == s.name else { return }
        saving = true; defer { saving = false }
        do {
            try await client.saveSkill(s.name, content: content)
            original = content
            model.library.skillDrafts[s.name] = nil
            model.flash("Saved \(s.name)")
            await model.library.loadSkills()
        } catch { model.flash("Save failed: \(error.localizedDescription)") }
    }

    private func stripFrontMatter(_ s: String) -> String {
        guard s.hasPrefix("---"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) else { return s }
        return String(s[end.upperBound...])
    }
}

struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var category = ""
    @ViewState private var summary = ""
    @ViewState private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Skill").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. weekly-review"))
                TextField("Category", text: $category, prompt: Text("Optional"))
                TextField("What it does", text: $summary, prompt: Text("One sentence Hermes uses to decide when to load it"), axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            Text("Hermes reads the description to decide when to use this skill. You can write the full instructions next.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { Task { await create() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(slug.isEmpty || summary.isEmpty || saving)
            }
        }
        .padding(24).frame(width: 480)
    }

    private var slug: String {
        name.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func create() async {
        guard let client = model.client else { return }
        saving = true; defer { saving = false }
        let body = """
        ---
        name: \(slug)
        description: "\(summary.replacingOccurrences(of: "\"", with: "'"))"
        version: 1.0.0
        ---

        # \(name)

        ## When to use

        ## Steps

        """
        do {
            try await client.createSkill(slug, content: body, category: category.isEmpty ? nil : category)
            await model.library.loadSkills()
            model.library.skillSelection = slug
            dismiss()
        } catch { model.flash("Couldn't create skill: \(error.localizedDescription)") }
    }
}
