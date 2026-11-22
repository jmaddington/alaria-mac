import Foundation

/// Line-based edits of the `mcp_servers:` block in Hermes' config.yaml (no YAML library on purpose: the edit must
/// leave every other byte of the user's file, comments included, untouched).
// AIDEV-NOTE: handles block-style `mcp_servers:` (the only style Hermes itself writes), `mcp_servers: {}` and
// `mcp_servers:` absent. Flow-style with entries (`mcp_servers: {a: ...}`) throws so the UI shows the snippet instead.
public enum MCPConfigYAML {
    public struct Unsupported: LocalizedError {
        public let errorDescription: String?
    }

    /// The entry Hermes needs for the app's browser MCP server.
    public static func entry(name: String = BrowserToolCatalog.serverName, port: UInt16, token: String) -> [String] {
        [
            "\(name):",
            "  url: \"http://127.0.0.1:\(port)/mcp\"",
            "  headers:",
            "    Authorization: \"Bearer \(token)\"",
            "  timeout: 120",
            "  connect_timeout: 10",
        ]
    }

    /// Full snippet as it would appear in a config with no other MCP servers.
    public static func snippet(port: UInt16, token: String) -> String {
        (["mcp_servers:"] + entry(port: port, token: token).map { "  " + $0 }).joined(separator: "\n") + "\n"
    }

    /// Adds or replaces `name` under `mcp_servers:`.
    public static func upsert(_ yaml: String, name: String = BrowserToolCatalog.serverName, entry: [String]) throws -> String {
        var lines = yaml.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let h = try headerIndex(lines) else {
            var out = lines
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append("mcp_servers:")
            out += entry.map { "  " + $0 }
            return out.joined(separator: "\n") + "\n"
        }
        if stripComment(lines[h]).trimmingCharacters(in: .whitespaces) != "mcp_servers:" { lines[h] = "mcp_servers:" } // {} / null
        let end = blockEnd(lines, after: h)
        let indent = childIndent(lines, h, end) ?? "  "
        let block = entry.map { indent + $0 }
        if let (k, m) = child(lines, name: name, indent: indent, from: h + 1, to: end) {
            lines.replaceSubrange(k..<m, with: block)
        } else {
            lines.insert(contentsOf: block, at: h + 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes `name` from `mcp_servers:` (no-op when absent). An emptied block becomes `mcp_servers: {}`.
    public static func remove(_ yaml: String, name: String = BrowserToolCatalog.serverName) throws -> String {
        var lines = yaml.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let h = try headerIndex(lines) else { return yaml }
        let end = blockEnd(lines, after: h)
        guard let indent = childIndent(lines, h, end), let (k, m) = child(lines, name: name, indent: indent, from: h + 1, to: end) else { return yaml }
        lines.removeSubrange(k..<m)
        if childIndent(lines, h, blockEnd(lines, after: h)) == nil { lines[h] = "mcp_servers: {}" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when `name` is configured (used by Settings to show "Added").
    public static func contains(_ yaml: String, name: String = BrowserToolCatalog.serverName) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        guard let h = try? headerIndex(lines) else { return false }
        let end = blockEnd(lines, after: h)
        guard let indent = childIndent(lines, h, end) else { return false }
        return child(lines, name: name, indent: indent, from: h + 1, to: end) != nil
    }

    // MARK: internals

    static func stripComment(_ s: String) -> String {
        // Good enough for the header line: no quotes are legal in `mcp_servers: {}`.
        s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
    }

    static func headerIndex(_ lines: [String]) throws -> Int? {
        for (i, l) in lines.enumerated() where l.hasPrefix("mcp_servers:") {
            let rest = stripComment(String(l.dropFirst("mcp_servers:".count))).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest == "{}" || rest == "null" || rest == "~" { return i }
            throw Unsupported(errorDescription: "config.yaml writes mcp_servers in flow style; add the snippet by hand.")
        }
        return nil
    }

    static func isContent(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("#")
    }
    static func indentOf(_ l: String) -> Int { l.prefix { $0 == " " }.count }

    /// First line after the header that is top-level content (column 0, not a comment), or lines.count.
    static func blockEnd(_ lines: [String], after h: Int) -> Int {
        var i = h + 1
        while i < lines.count { if isContent(lines[i]) && indentOf(lines[i]) == 0 { return i }; i += 1 }
        return lines.count
    }

    static func childIndent(_ lines: [String], _ h: Int, _ end: Int) -> String? {
        guard h + 1 < end else { return nil }
        return lines[(h + 1)..<end].first(where: isContent).map { String(repeating: " ", count: indentOf($0)) }
    }

    /// Range of the `name:` child (its key line through its last nested line).
    static func child(_ lines: [String], name: String, indent: String, from: Int, to end: Int) -> (Int, Int)? {
        let keys = ["\(name):", "\"\(name)\":", "'\(name)':"]
        guard let k = (from..<end).first(where: { i in
            let l = lines[i]
            guard indentOf(l) == indent.count else { return false }
            let t = l.dropFirst(indent.count)
            return keys.contains { t.hasPrefix($0) }
        }) else { return nil }
        var m = k + 1
        while m < end, !(isContent(lines[m]) && indentOf(lines[m]) <= indent.count) { m += 1 }
        // Leave trailing blank/comment lines with the next sibling.
        while m > k + 1, !isContent(lines[m - 1]) { m -= 1 }
        return (k, m)
    }
}
