import Foundation
import HermesKit

/// Composer live-Markdown spans (hermes-mac-9ey).
func runComposeChecks() {
    func kinds(_ t: String, _ k: MarkdownSpans.Kind) -> [String] {
        let ns = t as NSString
        return MarkdownSpans.spans(in: t).filter { $0.kind == k }.map { ns.substring(with: $0.range) }
    }
    check("compose: quote line and its marker") {
        expect(kinds("> hello there", .quote) == ["hello there"])
        expect(kinds("> hello there", .marker) == ["> "])
        expect(kinds("not > a quote", .quote).isEmpty)
    }
    check("compose: inline code, and emphasis doesn't apply inside it") {
        expect(kinds("run `ls *.swift*` now", .inlineCode) == ["ls *.swift*"])
        expect(kinds("run `ls *.swift*` now", .italic).isEmpty)
        expect(kinds("a ``x ` y`` b", .inlineCode) == ["x ` y"])
        expect(kinds("unclosed `tick", .inlineCode).isEmpty)
    }
    check("compose: fenced blocks") {
        let t = "before\n```swift\nlet a = *b*\n```\nafter **x**"
        expect(kinds(t, .fence) == ["```swift", "```"])
        expect(kinds(t, .codeBlock) == ["let a = *b*"])
        expect(kinds(t, .italic).isEmpty, "no emphasis in code blocks")
        expect(kinds(t, .bold) == ["x"])
        expect(kinds("```js```", .fence).isEmpty, "one-line ``` is inline code")
    }
    check("compose: emphasis rules") {
        expect(kinds("**bold** and __also__", .bold) == ["bold", "also"])
        expect(kinds("*it* and _it2_", .italic) == ["it", "it2"])
        expect(kinds("2 * 3 * 4", .italic).isEmpty)
        expect(kinds("snake_case_name", .italic).isEmpty)
        expect(kinds("~~gone~~", .strike) == ["gone"])
    }
    check("compose: list markers") {
        expect(kinds("- a\n2. b\n* c", .listMarker) == ["- ", "2. ", "* "])
        expect(kinds("-not a list", .listMarker).isEmpty)
    }
    check("compose: Return inside an open fence is a newline") {
        let t = "```\ncode"
        expect(MarkdownSpans.isInsideOpenFence(t, caret: (t as NSString).length))
        expect(MarkdownSpans.isInsideOpenFence("```swift", caret: 8), "caret on the opener line")
        let closed = "```\ncode\n```"
        expect(!MarkdownSpans.isInsideOpenFence(closed, caret: (closed as NSString).length))
        expect(!MarkdownSpans.isInsideOpenFence("plain", caret: 5))
    }
    check("compose: emoji and other UTF-16 surrogates keep ranges aligned") {
        expect(kinds("🙂 **hi** 🙂", .bold) == ["hi"])
    }
}
