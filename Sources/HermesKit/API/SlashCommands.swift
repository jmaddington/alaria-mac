import Foundation

// Composer "/" commands (bead hermes-mac-ptp). Pure parsing + the catalog; the app runs them (SlashExecutor).
//
// AIDEV-NOTE: the Hermes API server does NOT execute slash commands: "/model" sent as a chat message just goes to
// the LLM as text (probed 2026-11-22). Every command here is a client-side action on a real endpoint; TUI commands
// with no endpoint are listed in `SlashCatalog.unsupported` instead. Unknown "/x" text is sent as a normal message.

public struct SlashCommand: Hashable, Sendable, Identifiable {
    public enum Arg: Hashable, Sendable {
        case none
        case optional(String)   // placeholder shown in the menu, e.g. "effort"
        case required(String)
    }
    public var name: String
    public var aliases: [String]
    public var summary: String
    public var arg: Arg
    /// Fixed argument values offered as a second-level list (the app adds dynamic ones, e.g. models).
    public var choices: [String]
    public var id: String { name }

    public init(_ name: String, aliases: [String] = [], _ summary: String, arg: Arg = .none, choices: [String] = []) {
        self.name = name; self.aliases = aliases; self.summary = summary; self.arg = arg; self.choices = choices
    }

    public var takesArg: Bool { if case .none = arg { return false }; return true }
    public var needsArg: Bool { if case .required = arg { return true }; return false }
    /// "/title <name>" or "/reasoning [effort]".
    public var usage: String {
        switch arg {
        case .none: return "/\(name)"
        case .optional(let p): return "/\(name) [\(p)]"
        case .required(let p): return "/\(name) <\(p)>"
        }
    }
}

/// A draft split as "/name args". `name` is lowercased; args keep their case and inner spacing.
public struct SlashInput: Equatable, Sendable {
    public var name: String
    public var args: String
    /// True while the user is still typing the name (no space yet): the menu lists commands, not arguments.
    public var editingName: Bool

    public init(name: String, args: String, editingName: Bool) { self.name = name; self.args = args; self.editingName = editingName }

    /// nil unless the draft starts with "/" followed by a command-like word. "/" alone parses (empty name).
    /// Paths ("/usr/bin"), "//" and multi-line drafts are not commands.
    public static func parse(_ draft: String) -> SlashInput? {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return nil }
        let body = draft.dropFirst()
        let nameEnd = body.firstIndex(where: { $0 == " " }) ?? body.endIndex
        let name = body[..<nameEnd]
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let rest = body[nameEnd...]
        return SlashInput(name: name.lowercased(), args: rest.trimmingCharacters(in: .whitespaces), editingName: rest.isEmpty)
    }
}

public enum SlashCatalog {
    public static let all: [SlashCommand] = [
        SlashCommand("model", "Switch this chat's model", arg: .optional("model")),
        SlashCommand("reasoning", "Set reasoning effort for this chat", arg: .optional("effort"), choices: ModelChoice.efforts),
        SlashCommand("fast", "Toggle fast mode (priority processing) for this chat", arg: .optional("on|off"), choices: ["on", "off"]),
        SlashCommand("new", aliases: ["clear"], "Start a new chat"),
        SlashCommand("retry", "Send your last message again"),
        SlashCommand("stop", "Stop the current reply"),
        SlashCommand("steer", "Nudge the running reply after its next tool call", arg: .required("message")),
        SlashCommand("approve", "Approve the pending command", arg: .optional("once|session|always"), choices: ["once", "session", "always"]),
        SlashCommand("deny", "Deny the pending command"),
        SlashCommand("title", aliases: ["rename"], "Rename this chat", arg: .required("title")),
        SlashCommand("fork", aliases: ["branch", "duplicate"], "Duplicate this chat into a new one"),
        SlashCommand("pin", aliases: ["unpin"], "Pin or unpin this chat"),
        SlashCommand("archive", "Archive this chat"),
        SlashCommand("delete", "Delete this chat (asks first)"),
        SlashCommand("status", aliases: ["usage"], "Show this chat's model, messages, tokens and cost"),
        SlashCommand("voice", "Start voice mode"),
        SlashCommand("help", aliases: ["commands"], "List these commands"),
    ]

    /// TUI commands with no API-server endpoint (checked against api_server.py routes 2026-11-22).
    // AIDEV-NOTE: a future dashboard /api/ws (tui_gateway slash.exec) executor may cover some of these.
    public static let unsupported = ["compress", "undo", "rewind", "yolo", "queue", "bg", "btw", "goal", "personality",
                                     "verbose", "rollback", "diff", "save", "skills", "tools", "cron", "memory"]

    /// Exact name or alias.
    public static func command(named name: String) -> SlashCommand? {
        all.first { $0.name == name || $0.aliases.contains(name) }
    }

    /// Commands for the menu while the name is being typed: prefix matches on name/alias first, then substring.
    public static func suggestions(_ partial: String) -> [SlashCommand] {
        let q = partial.lowercased()
        guard !q.isEmpty else { return all }
        let prefix = all.filter { c in c.name.hasPrefix(q) || c.aliases.contains { $0.hasPrefix(q) } }
        let contains = all.filter { c in !prefix.contains(c) && c.name.contains(q) }
        return prefix + contains
    }

    /// Argument values filtered by what's typed (prefix first, then substring), case-insensitively.
    public static func filter(_ values: [String], by typed: String) -> [String] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return values }
        let prefix = values.filter { $0.lowercased().hasPrefix(q) }
        return prefix + values.filter { !prefix.contains($0) && $0.lowercased().contains(q) }
    }

    /// What Return does with a draft (when no menu row is picked): run a known command, or send the text.
    public enum Action: Equatable, Sendable {
        case run(SlashCommand, args: String)
        case needsArg(SlashCommand)  // "/title" with no title: keep the draft, ask for the argument
        case sendText                // not a command (or an unknown one): a normal message
    }
    public static func action(for draft: String) -> Action {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = SlashInput.parse(t), let cmd = command(named: input.name) else { return .sendText }
        if cmd.needsArg && input.args.isEmpty { return .needsArg(cmd) }
        if !cmd.takesArg && !input.args.isEmpty { return .sendText } // "/new york trip ideas" is a message
        return .run(cmd, args: input.args)
    }
}
