import AppKit
import SwiftUI

/// Block-level markdown for assistant replies. SwiftUI's AttributedString(markdown:) handles inline styling
/// only, so blocks (headings, lists, quotes, fenced code, rules, tables-as-monospace) are parsed here.
// AIDEV-NOTE: deliberately small; streaming text re-parses each delta, so keep parse() linear and allocation-light.
enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case quote(String)
    case code(lang: String, body: String)
    case rule
    case table(String)
}

enum Markdown {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = [], bullets: [String] = [], numbers: [String] = [], quote: [String] = [], table: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") { blocks.append(.code(lang: lang, body: code!.joined(separator: "\n"))); code = nil }
                else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") { flush(); lang = String(line.dropFirst(3)); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") { if para.isEmpty && bullets.isEmpty { table.append(line); continue } }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { flush(); blocks.append(.rule); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flush(); blocks.append(.heading(line.distance(from: line.startIndex, to: h), String(line[line.index(after: h)...]))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if !numbers.isEmpty || !para.isEmpty || !quote.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2))); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                if !bullets.isEmpty || !para.isEmpty || !quote.isEmpty { flush() }
                numbers.append(String(line[line.index(dot, offsetBy: 2)...])); continue
            }
            if line.hasPrefix(">") { if !para.isEmpty { flush() }; quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            if !bullets.isEmpty && raw.hasPrefix("  ") { bullets[bullets.count - 1] += " " + line; continue }
            if !bullets.isEmpty || !numbers.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            para.append(line)
        }
        if let code { blocks.append(.code(lang: lang, body: code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Inline styling for model output. Links are untrusted: only http(s) and mailto survive; anything else
    /// (file://, app URL schemes) is rendered as plain text so a click can't launch it.
    // AIDEV-NOTE: security; keep the scheme allowlist (security review 2026-11-21).
    static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in a.runs {
            guard let url = run.link else { continue }
            if !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { a[run.range].link = nil }
        }
        return a
    }
}

struct MarkdownView: View {
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(Markdown.inline(t))
                .font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .paragraph(let t):
            Text(Markdown.inline(t)).lineSpacing(3.5).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(.secondary).frame(width: 4.5, height: 4.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(Markdown.inline(i)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.leading, 4)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n + 1).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        Text(Markdown.inline(i)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let t):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                Text(Markdown.inline(t)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let body):
            CodeBlock(lang: lang, code: body)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.system(.callout, design: .monospaced)).padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
    }
}

struct CodeBlock: View {
    var lang: String
    var code: String
    @ViewState private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).lineSpacing(2.5).padding(14).textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}
