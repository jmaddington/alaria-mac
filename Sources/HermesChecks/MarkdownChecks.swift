import HermesKit

/// Markdown block parser regressions (review beads hermes-mac-iww, hermes-mac-bgk).
func runMarkdownChecks() {
    check("markdown: loose numbered list stays one list") {
        let b = MarkdownParser.parse("1. alpha\n\n2. beta\n\n3. gamma")
        expect(b == [.numbered(start: 1, [MDListItem(text: "alpha"), MDListItem(text: "beta"), MDListItem(text: "gamma")])], "\(b)")
    }
    check("markdown: numbered list keeps its start number") {
        expect(MarkdownParser.parse("3. three\n4. four") == [.numbered(start: 3, [MDListItem(text: "three"), MDListItem(text: "four")])])
    }
    check("markdown: nested bullet attaches to its item") {
        let b = MarkdownParser.parse("1. a\n   - sub\n2. b")
        expect(b == [.numbered(start: 1, [MDListItem(text: "a", children: ["sub"]), MDListItem(text: "b")])], "\(b)")
        let c = MarkdownParser.parse("- a\n  - nested\n- b")
        expect(c == [.bullet([MDListItem(text: "a", children: ["nested"]), MDListItem(text: "b")])], "\(c)")
    }
    check("markdown: fence closes only on a matching fence") {
        let b = MarkdownParser.parse("````md\n```js\ny\n```\n````")
        expect(b == [.code(lang: "md", body: "```js\ny\n```")], "\(b)")
        expect(MarkdownParser.parse("~~~\nx\n~~~") == [.code(lang: "", body: "x")])
    }
    check("markdown: table right after a paragraph, separator row dropped") {
        let b = MarkdownParser.parse("text\n| a | b |\n|---|:-:|\n| 1 | 2 |")
        expect(b == [.paragraph("text"), .table(header: ["a", "b"], rows: [["1", "2"]])], "\(b)")
    }
    check("markdown: list ends at a plain paragraph after a blank line") {
        let b = MarkdownParser.parse("- a\n\nafter")
        expect(b == [.bullet([MDListItem(text: "a")]), .paragraph("after")], "\(b)")
    }
}

/// Voice sentence splitting for chat-style replies (hermes-mac-8fd).
func runSplitterChecks() {
    func split(_ text: String) -> [String] { var s = SentenceSplitter(); return s.feed(text) + s.flush() }
    check("splitter: abbreviations don't split") {
        let r = split("Dr. Smith said e.g. this works. Next one.")
        expect(r == ["Dr. Smith said e.g. this works.", "Next one."], "\(r)")
    }
    check("splitter: numbered list items, markers stripped") {
        let r = split("Steps:\n1. First item\n2. Second item")
        expect(r == ["Steps:", "First item", "Second item"], "\(r)")
    }
    check("splitter: code fences are not read aloud") {
        let r = split("Here you go.\n```python\nmy_var = a * b\n```\nDone.")
        expect(r == ["Here you go.", SentenceSplitter.codeNotice, "Done."], "\(r)")
    }
    check("splitter: snake_case kept, emphasis underscores dropped") {
        let r = split("Set _my_var_ to __on__ now.")
        expect(r == ["Set my_var to on now."], "\(r)")
    }
    check("splitter: decimals mid-stream are not split") {
        var s = SentenceSplitter()
        let a = s.feed("Pi is about 3.")
        let b = s.feed("14 today. ")
        expect(a.isEmpty && b == ["Pi is about 3.14 today."], "\(a) \(b)")
    }
}
