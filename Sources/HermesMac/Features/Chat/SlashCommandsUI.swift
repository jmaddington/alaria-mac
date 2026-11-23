import AppKit
import HermesKit
import OSLog
import SwiftUI

private let slashLog = Logger(subsystem: "net.jmaddington.hermes", category: "slash")

// Composer "/" commands (bead hermes-mac-ptp): the catalog and parsing live in HermesKit/API/SlashCommands.swift.

// MARK: - Execution

/// Runs a slash command. Pluggable so another backend (e.g. the dashboard's /api/ws `slash.exec`) can be slotted in
/// ahead of the API one: `SlashRouter.executors` is tried in order and the first that `handles` a command runs it.
@MainActor protocol SlashExecutor {
    func handles(_ command: SlashCommand) -> Bool
    func run(_ command: SlashCommand, args: String, chats: ChatStore)
}

@MainActor enum SlashRouter {
    static var executors: [any SlashExecutor] = [APISlashExecutor()]

    /// Composer Return. True = the draft was a command (handled, or waiting for its argument); false = send as text.
    static func submit(_ draft: String, chats: ChatStore) -> Bool {
        switch SlashCatalog.action(for: draft) {
        case .sendText: return false
        case .needsArg(let c):
            chats.app?.flash("Type \(c.usage)")
            return true
        case .run(let c, let args):
            run(c, args: args, chats: chats)
            return true
        }
    }

    static func run(_ c: SlashCommand, args: String, chats: ChatStore) {
        guard let ex = executors.first(where: { $0.handles(c) }) else {
            chats.app?.flash("/\(c.name) isn't available on this server")
            return
        }
        chats.draft = ""
        slashLog.info("run /\(c.name, privacy: .public) [ALR-SLASH1]")
        ex.run(c, args: args, chats: chats)
    }
}

/// Every command mapped onto an existing API-server endpoint (or a purely local action). See the report table in
/// SlashCatalog: model/reasoning/fast -> POST /api/sessions/{id}/model; title/pin/archive -> PATCH /api/sessions/{id};
/// fork -> POST .../fork; delete -> DELETE; stop/steer/approve/deny -> /v1/runs/{run_id}/...; status -> GET session.
struct APISlashExecutor: SlashExecutor {
    func handles(_ command: SlashCommand) -> Bool { SlashCatalog.command(named: command.name) != nil }

    func run(_ c: SlashCommand, args: String, chats: ChatStore) {
        guard let app = chats.app else { return }
        let session = chats.selectedSession
        func needChat() -> HermesSession? {
            if session == nil { app.flash("/\(c.name) works in a chat that has started") }
            return session
        }
        switch c.name {
        case "model":
            guard !args.isEmpty else { app.flash("This chat uses \(chats.currentModel.choice?.label ?? "the server default"). Type /model <name>."); return }
            guard let cat = chats.models.catalog else { app.flash("Models are still loading"); return }
            let keep = chats.currentModel.choice
            if args.lowercased() == "default", let d = chats.models.defaultChoice {
                chats.setModel(ModelChoice(provider: d.provider, model: d.model, reasoningEffort: keep?.reasoningEffort, fast: keep?.fast ?? false))
            } else if let r = cat.resolve(args) {
                chats.setModel(ModelChoice(provider: r.provider, model: r.model, reasoningEffort: keep?.reasoningEffort, fast: keep?.fast ?? false))
            } else {
                app.flash("No single model matches “\(args)”")
            }
        case "reasoning":
            let a = args.lowercased()
            if a.isEmpty { app.flash("Reasoning: \(chats.currentModel.choice?.reasoningEffort ?? "default"). Type /reasoning <effort>."); return }
            if a == "default" || a == "auto" { chats.setModelOptions(effort: .some(nil)); return }
            let e = a == "off" ? "none" : a
            guard ModelChoice.efforts.contains(e) else { app.flash("Effort is one of: \(ModelChoice.efforts.joined(separator: ", "))"); return }
            chats.setModelOptions(effort: .some(e))
        case "fast":
            let a = args.lowercased()
            let on: Bool
            switch a {
            case "": on = !(chats.currentModel.choice?.fast ?? false)
            case "on", "true", "yes": on = true
            case "off", "false", "no": on = false
            default: app.flash("Type /fast on or /fast off"); return
            }
            chats.setModelOptions(fast: on)
        case "new":
            chats.newChat()
        case "retry":
            guard !chats.isStreaming else { app.flash("Wait for the reply to finish, or /stop it"); return }
            guard let last = chats.entries.last(where: { $0.role == .user }) else { app.flash("Nothing to retry yet"); return }
            // History rows can't return image pixels; only attachments still holding data go again.
            let atts = last.attachments.filter { $0.data != nil }
            if atts.count < last.attachments.count { app.flash("Re-sending the text; earlier attachments can't be re-sent") }
            chats.send(last.text, attachments: atts)
        case "stop":
            if chats.isStreaming { chats.stop() } else { app.flash("Nothing is running") }
        case "steer":
            guard let client = chats.client, let run = chats.runId else { app.flash("/steer works while Hermes is replying"); return }
            app.run("Steer") { try await client.steer(run, text: args); app.flash("Hermes will see that after its next step") }
        case "approve", "deny":
            guard let e = chats.entries.last(where: { $0.approval != nil }), let a = e.approval else { app.flash("No command is waiting for approval"); return }
            let choice = c.name == "deny" ? "deny" : (args.isEmpty ? "once" : args.lowercased())
            guard a.choices.contains(choice) else { app.flash("Choose one of: \(a.choices.joined(separator: ", "))"); return }
            chats.answer(a, choice, entry: e.id)
        case "title":
            guard let s = needChat() else { return }
            chats.rename(s, to: args)
        case "fork":
            guard let s = needChat() else { return }
            chats.fork(s)
        case "pin":
            guard let s = needChat() else { return }
            chats.togglePin(s)
        case "archive":
            guard let s = needChat() else { return }
            chats.archive(s)
        case "delete":
            guard let s = needChat() else { return }
            // Server delete has no undo: confirm like the chat list does.
            let alert = NSAlert()
            alert.messageText = "Delete “\(s.displayTitle)”?"
            alert.informativeText = "This removes the conversation from Hermes for good. Archive keeps it out of the way instead."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { chats.delete(s) }
        case "status":
            guard let s = needChat(), let client = chats.client else { return }
            app.run("Status") {
                let fresh = try await client.session(s.id)
                chats.addNote(Self.status(fresh, model: chats.currentModel))
            }
        case "voice":
            app.voice.start()
        case "help":
            chats.addNote(Self.help)
        default:
            app.flash("/\(c.name) isn't available on this server")
        }
    }

    static func status(_ s: HermesSession, model: (choice: ModelChoice?, isDefault: Bool)) -> String {
        var lines = ["**\(s.displayTitle)**", ""]
        if let c = model.choice {
            lines.append("- Model: `\(c.model)`\(c.provider.map { " (\($0))" } ?? "")\(model.isDefault ? ", server default" : "")")
            lines.append("- Reasoning: \(c.reasoningEffort ?? "default")\(c.fast ? ", fast mode" : "")")
        }
        lines.append("- Messages: \(s.messageCount ?? 0), tool calls: \(s.toolCallCount ?? 0)")
        let tokens = [("in", s.inputTokens), ("out", s.outputTokens), ("reasoning", s.reasoningTokens)]
            .compactMap { n, v in v.map { "\($0.formatted()) \(n)" } }
        if !tokens.isEmpty { lines.append("- Tokens: " + tokens.joined(separator: ", ")) }
        if let cost = s.estimatedCostUsd { lines.append("- Estimated cost: " + cost.formatted(.currency(code: "USD"))) }
        return lines.joined(separator: "\n")
    }

    static var help: String {
        var lines = ["**Commands** (type / in the message box)", ""]
        for c in SlashCatalog.all {
            let aka = c.aliases.isEmpty ? "" : " (also " + c.aliases.map { "/\($0)" }.joined(separator: ", ") + ")"
            lines.append("- `\(c.usage)`\(aka): \(c.summary)")
        }
        lines.append("")
        lines.append("Not available from the app (Hermes has no API for them yet): "
                     + SlashCatalog.unsupported.map { "/\($0)" }.joined(separator: ", ")
                     + ". Anything else starting with / is sent to Hermes as a normal message.")
        return lines.joined(separator: "\n")
    }
}

extension ChatStore {
    /// A local, unsaved note in the conversation (command output); it disappears when the chat reloads.
    func addNote(_ markdown: String) {
        entries.append(ChatEntry(id: "note-\(UUID().uuidString)", role: .system, text: markdown, date: .now))
    }
}

// MARK: - Composer menu

extension View {
    /// Composer hook: lists commands while the draft starts with "/", then argument values (models, efforts).
    /// ↑/↓ move, Return picks, Tab completes, Esc dismisses. Unmatched "/text" is sent as a normal message.
    func slashCommands(focused: Bool) -> some View { modifier(SlashCommandLayer(focused: focused)) }
}

/// One row of the "/" menu.
struct SlashItem: Identifiable, Equatable {
    var command: SlashCommand
    var value: String?        // nil = the command itself; else an argument value to run it with
    var title: String
    var detail: String
    var current = false
    var id: String { "\(command.name)|\(value ?? "")" }
}

struct SlashCommandLayer: ViewModifier {
    @Environment(AppModel.self) private var model
    var focused: Bool
    @ViewState private var keys = MentionKeys() // same ↑/↓/Return monitor as @mentions (ProfileViews.swift)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                layer
                    .padding(.leading, 36)
                    .alignmentGuide(.top) { $0[.bottom] - 2 } // sit just above the composer
            }
            .onChange(of: focused) { keys.focused = focused }
            .onAppear { keys.focused = focused }
    }

    private var chats: ChatStore { model.chats }

    private var items: [SlashItem] {
        let d = chats.draft
        guard keys.dismissedFor != d, let input = SlashInput.parse(d) else { return [] }
        if input.editingName {
            return SlashCatalog.suggestions(input.name).map { SlashItem(command: $0, value: nil, title: $0.usage, detail: $0.summary) }
        }
        guard let c = SlashCatalog.command(named: input.name) else { return [] }
        return Array(argumentItems(c, typed: input.args).prefix(12))
    }

    /// Second-level rows: models for /model, fixed choices for the others.
    private func argumentItems(_ c: SlashCommand, typed: String) -> [SlashItem] {
        let cur = chats.currentModel.choice
        if c.name == "model" {
            guard let cat = chats.models.catalog else { return [] }
            let all = cat.usable.flatMap { p in p.modelIDs.map { (p, $0) } }
            let ids = SlashCatalog.filter(all.map(\.1), by: typed)
            var seen = Set<String>()
            return ids.compactMap { id in
                guard seen.insert(id).inserted, let p = all.first(where: { $0.1 == id })?.0 else { return nil }
                return SlashItem(command: c, value: "\(p.slug)::\(id)", title: ModelChoice.shortName(id),
                                 detail: "\(p.name ?? p.slug)\(id == cat.model ? " · default" : "")", current: cur?.model == id)
            }
        }
        return SlashCatalog.filter(c.choices, by: typed).map { v in
            let on = c.name == "reasoning" ? cur?.reasoningEffort == v : c.name == "fast" ? (cur?.fast ?? false) == (v == "on") : false
            return SlashItem(command: c, value: v, title: v, detail: c.summary, current: on)
        }
    }

    @ViewBuilder private var layer: some View {
        let list = items
        if !list.isEmpty {
            menu(list)
                .onAppear { keys.highlight = 0; keys.install(handle) }
                .onDisappear { keys.remove() }
                .onChange(of: list.map(\.id)) { keys.highlight = 0 }
        }
    }

    private func menu(_ list: [SlashItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        Button { pick(item) } label: { row(item, selected: i == keys.highlight) }
                            .buttonStyle(.plain)
                            .onHover { if $0 { keys.highlight = i } }
                            .id(item.id)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: keys.highlight) { if list.indices.contains(keys.highlight) { proxy.scrollTo(list[keys.highlight].id) } }
        }
        .frame(width: 380, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private func row(_ item: SlashItem, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if item.current { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
            if selected { Image(systemName: "return").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
        .accessibilityLabel("\(item.title), \(item.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A command that takes an argument opens its value list ("/model "); otherwise it runs. A value row runs.
    private func pick(_ item: SlashItem) {
        if let v = item.value { SlashRouter.run(item.command, args: v, chats: chats); return }
        if item.command.takesArg { chats.draft = "/\(item.command.name) "; return }
        SlashRouter.run(item.command, args: "", chats: chats)
    }

    private func complete(_ item: SlashItem) {
        chats.draft = item.value.map { "/\(item.command.name) \($0)" } ?? "/\(item.command.name)\(item.command.takesArg ? " " : "")"
    }

    /// Key monitor: only while the composer has focus and the menu is showing. Returns true = consumed.
    private func handle(_ e: NSEvent) -> Bool {
        guard keys.focused else { return false }
        let list = items
        guard !list.isEmpty else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let item = list[min(keys.highlight, list.count - 1)]
        switch e.keyCode {
        case 126: keys.highlight = max(0, keys.highlight - 1); return true              // up
        case 125: keys.highlight = min(list.count - 1, keys.highlight + 1); return true // down
        case 36, 76:                                                                     // return, enter
            guard mods.isEmpty else { return false } // Option-Return still inserts a newline
            pick(item); return true // the highlighted row wins; Esc first to send "/text" as a plain message
        case 48: guard mods.isEmpty else { return false }; complete(item); return true // tab
        case 53: keys.dismissedFor = chats.draft; keys.remove(); return true            // esc
        default: return false
        }
    }
}
