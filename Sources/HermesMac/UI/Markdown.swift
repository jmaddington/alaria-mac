import AppKit
import HermesKit
import SwiftUI

/// Block-level markdown for assistant replies. SwiftUI's AttributedString(markdown:) handles inline styling
/// only, so blocks (headings, lists, quotes, fenced code, rules, tables-as-monospace) are parsed here.
// AIDEV-NOTE: deliberately small; streaming text re-parses each delta, so keep parse() linear and allocation-light.
enum Markdown {
    static func parse(_ text: String) -> [MDBlock] { MarkdownParser.parse(text) }

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
                        itemBody(i)
                    }
                }
            }.padding(.leading, 4)
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + n).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        itemBody(i)
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
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in Text(Markdown.inline(c)).fontWeight(.semibold) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { k in Text(Markdown.inline(k < r.count ? r[k] : "")) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }

    @ViewBuilder func itemBody(_ i: MDListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Markdown.inline(i.text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(i.children.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(Markdown.inline(c)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
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
