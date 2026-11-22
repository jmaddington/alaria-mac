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

/// Cleartext-key warning heuristics (hermes-mac-fkh, hermes-mac-zli).
func runSecurityChecks() {
    check("cleartext warning: private and tailnet hosts are fine") {
        for u in ["http://127.0.0.1:8642", "http://localhost:8642", "http://10.1.2.3:8642", "http://192.168.1.5",
                  "http://100.101.102.103", "http://mac.local", "http://box.tail1234.ts.net", "http://hermes",
                  "http://[::1]:8642", "http://[fe80::1]:8642", "http://[fd12::1]:8642", "https://hermes.example.com"] {
            expect(!ConnectionSecurity.sendsKeyInClear(u), u)
        }
    }
    check("cleartext warning: public names, IPs and IPv6 warn") {
        for u in ["http://hermes.example.com:8642", "http://10.0.0.1.evil.com:8642", "http://127.0.0.1.nip.io",
                  "http://8.8.8.8", "http://[2001:4860:4860::8888]:8642"] {
            expect(ConnectionSecurity.sendsKeyInClear(u), u)
        }
    }
}

/// Google Cloud TTS wire format (hermes-mac-h2i).
func runGoogleTTSChecks() {
    check("google tts: request body and language code") {
        let v = GoogleVoice(apiKey: "k", voice: "en-GB-Chirp3-HD-Kore", speakingRate: 1.2)
        expect(GoogleVoice.languageCode(of: "en-GB-Chirp3-HD-Kore") == "en-GB")
        let b = v.requestBody("Hi.")
        expect((b["voice"] as? [String: Any])?["name"] as? String == "en-GB-Chirp3-HD-Kore")
        expect((b["audioConfig"] as? [String: Any])?["audioEncoding"] as? String == "LINEAR16")
        expect((b["audioConfig"] as? [String: Any])?["speakingRate"] as? Double == 1.2)
        expect((GoogleVoice(apiKey: "k").requestBody("x")["audioConfig"] as? [String: Any])?["speakingRate"] == nil, "rate 1.0 omitted")
    }
}

/// Message display cleanup (cron preamble, stopped turns) - reported by the iOS port 2026-11-22.
func runMessageTextChecks() {
    check("message text: cron preamble stripped for display") {
        let stored = "[IMPORTANT: You are running as a scheduled cron job. Deliver the result to: local.]\n\n[CURRENT RUN TIME: 2026-11-22 09:00 EST]\n\nSummarize my day"
        expect(MessageText.display(stored) == "Summarize my day", MessageText.display(stored))
        expect(MessageText.display("Normal [bracket] text") == "Normal [bracket] text")
    }
    check("message text: interruption markers") {
        expect(MessageText.isInterruption("Operation interrupted: waiting for model response (12s elapsed)."))
        expect(MessageText.isInterruption("Your request was not processed. Send it again to retry."))
        expect(!MessageText.isInterruption("The operation was a success."))
    }
}
