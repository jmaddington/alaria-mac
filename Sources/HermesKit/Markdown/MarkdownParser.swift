import Foundation

/// Block-level markdown for assistant replies (pure Foundation so hermes-checks can test it).
public enum MDBlock: Hashable, Sendable {
    case heading(Int, String)
    case paragraph(String)
    case bullet([MDListItem])
    case numbered(start: Int, [MDListItem])
    case quote(String)
    case code(lang: String, body: String)
    case rule
    case table(header: [String], rows: [[String]])
    /// A picture pulled out of a paragraph line: `![alt](url)`, a `MEDIA:/path` tag or a bare image URL (ChatImages.swift).
    case image(alt: String, ref: ImageRef)
}

/// A list item; indented sub-items are kept one level deep (enough for chat replies).
public struct MDListItem: Hashable, Sendable {
    public var text: String
    public var children: [String] = []
    public init(text: String, children: [String] = []) { self.text = text; self.children = children }
}

public enum MarkdownParser {
    // AIDEV-NOTE: rewritten 2026-11-22 for review beads hermes-mac-iww/-bgk. Rules: a blank line inside a list doesn't
    // end it if another item follows; numbered lists keep their first number; indented items nest; a fence closes only
    // on the same char with >= length; tables need no blank line before them and render as a grid.
    public static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = [], quote: [String] = [], tableRows: [[String]] = []
        var items: [MDListItem] = [], ordered = false, start = 1
        var pendingBlank = false
        var fence: (char: Character, len: Int, lang: String, body: [String])? = nil

        func flushList() {
            if !items.isEmpty { blocks.append(ordered ? .numbered(start: start, items) : .bullet(items)); items = [] }
            pendingBlank = false
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let header = tableRows[0]
            let body = tableRows.dropFirst().filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty } }
            blocks.append(.table(header: header, rows: Array(body)))
            tableRows = []
        }
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            flushTable()
            flushList()
        }
        func listMarker(_ t: Substring) -> (ordered: Bool, number: Int, rest: String)? {
            for m in ["- ", "* ", "+ ", "• "] where t.hasPrefix(m) { return (false, 0, String(t.dropFirst(2))) }
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
            return (true, Int(digits) ?? 1, String(after.dropFirst(2)))
        }

        // Byte-level line split and tab check: replies can carry multi-MB data-URL images on one line (ChatImages.swift).
        for rawBytes in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let raw = String(Substring(rawBytes))
            let expanded = raw.utf8.contains(0x09) ? raw.replacingOccurrences(of: "\t", with: "    ") : raw
            let indent = expanded.prefix { $0 == " " }.count
            let line = expanded.trimmingCharacters(in: .whitespaces)

            if var f = fence {
                let run = line.prefix { $0 == f.char }
                if run.count >= f.len, line.dropFirst(run.count).allSatisfy(\.isWhitespace) {
                    blocks.append(.code(lang: f.lang, body: f.body.joined(separator: "\n"))); fence = nil
                } else { f.body.append(raw); fence = f }
                continue
            }
            if let c = line.first, c == "`" || c == "~" {
                let run = line.prefix { $0 == c }
                if run.count >= 3 {
                    flush()
                    fence = (c, run.count, String(line.dropFirst(run.count)).trimmingCharacters(in: .whitespaces), [])
                    continue
                }
            }
            if line.isEmpty {
                if !items.isEmpty { pendingBlank = true } else { flush() }
                continue
            }
            if line.hasPrefix("|") {
                if tableRows.isEmpty { flush() }
                tableRows.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            if !tableRows.isEmpty { flushTable() }
            if line.utf8.count >= 3, line.utf8.count <= 200, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }),
               Set(line.filter { $0 != " " }).count == 1 {
                flush(); blocks.append(.rule); continue
            }
            if line.hasPrefix("#"), let h = line.firstIndex(where: { $0 != "#" }), line[h] == " " {
                flush(); blocks.append(.heading(line.distance(from: line.startIndex, to: h), String(line[line.index(after: h)...])))
                continue
            }
            if let m = listMarker(Substring(line)) {
                if indent >= 2, !items.isEmpty {
                    // Nested item: attach to the current top-level item.
                    items[items.count - 1].children.append(m.ordered ? "\(m.number). \(m.rest)" : m.rest)
                    pendingBlank = false
                    continue
                }
                if !items.isEmpty && ordered != m.ordered { flushList() }
                if items.isEmpty {
                    if !para.isEmpty || !quote.isEmpty { flush() }
                    ordered = m.ordered; start = m.number
                }
                if ImageScan.mightContainImage(m.rest) {
                    // "1. MEDIA:/x.png": the item keeps its text, the picture follows the list (which resumes after it).
                    let segs = ImageScan.split(m.rest)
                    let text = segs.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: " ")
                    items.append(MDListItem(text: text))
                    flushList()
                    for case .image(let alt, let ref) in segs { blocks.append(.image(alt: alt, ref: ref)) }
                    continue
                }
                items.append(MDListItem(text: m.rest)); pendingBlank = false
                continue
            }
            if !items.isEmpty {
                if indent >= 2 {
                    // Continuation of the last item (or its last child).
                    let last = items.count - 1
                    if items[last].children.isEmpty { items[last].text += " " + line }
                    else { items[last].children[items[last].children.count - 1] += " " + line }
                    pendingBlank = false
                    continue
                }
                flushList()
            }
            if line.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !quote.isEmpty { flush() }
            if ImageScan.mightContainImage(line) {
                // Images become their own blocks; the text around them stays in the paragraph flow.
                for seg in ImageScan.split(line) {
                    switch seg {
                    case .text(let t): if !t.isEmpty { para.append(t) }
                    case .image(let alt, let ref): flush(); blocks.append(.image(alt: alt, ref: ref))
                    }
                }
                continue
            }
            para.append(line)
        }
        if let f = fence { flush(); blocks.append(.code(lang: f.lang, body: f.body.joined(separator: "\n"))) }
        flush()
        return blocks
    }

}
