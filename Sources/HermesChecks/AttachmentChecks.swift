import Foundation
import HermesKit

/// Content-part encoding for chat attachments (beads hermes-mac-ard / -6uj), plus live checks that hit only the
/// server's request validation (rejected before any model turn starts, so they're cheap on the shared dev model).
func runAttachmentChecks() {
    // 1x1 transparent PNG.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    check("content parts: text-only is a plain string message") {
        let parts = ChatContent.parts(text: "  hi  ", files: [], imageURLs: [])
        expect(parts == [.text("hi")])
        let obj = try JSONSerialization.jsonObject(with: ChatContent.body(parts)) as? [String: Any]
        expect(obj?["message"] as? String == "hi", "\(String(describing: obj))")
    }
    check("content parts: images become image_url parts after the text") {
        let url = ChatContent.dataURL(mime: "image/png", data: png)
        expect(url.hasPrefix("data:image/png;base64,iVBOR"))
        expect(ChatContent.encodedSize(mime: "image/png", bytes: png.count) == url.utf8.count, "size estimate")
        let parts = ChatContent.parts(text: "what is this", files: [], imageURLs: [url])
        let obj = try JSONSerialization.jsonObject(with: ChatContent.body(parts)) as? [String: Any]
        let msg = obj?["message"] as? [[String: Any]]
        expect(msg?.count == 2)
        expect(msg?[0]["type"] as? String == "text" && msg?[0]["text"] as? String == "what is this")
        expect(msg?[1]["type"] as? String == "image_url")
        expect((msg?[1]["image_url"] as? [String: Any])?["url"] as? String == url)
        let back = ChatContent.decodeDataURL(url)
        expect(back?.mime == "image/png" && back?.data == png, "data URL round trip")
    }
    check("content parts: image-only sends no empty text part") {
        let parts = ChatContent.parts(text: " \n", files: [], imageURLs: ["data:image/png;base64,AA=="])
        expect(parts == [.imageURL("data:image/png;base64,AA==")], "\(parts)")
        expect(ChatContent.parts(text: "", files: [], imageURLs: []).isEmpty)
    }
    check("inline files: fenced, fence outgrows backticks, round-trips through parseStored") {
        let f = InlineFile(name: "notes.md", text: "# Title\n```swift\nlet x = 1\n```\n")
        let block = ChatContent.inline(f)
        expect(block.hasPrefix("[Attached file: notes.md]\n````md\n"), block)
        expect(block.hasSuffix("\n````"), block)
        let text = ChatContent.text("Summarize this", files: [f, InlineFile(name: "a.json", text: "{}")])
        let stored = ChatContent.parseStored(text)
        expect(stored.text == "Summarize this", stored.text)
        expect(stored.files.map(\.name) == ["notes.md", "a.json"], "\(stored.files)")
        expect(stored.files.first?.text == "# Title\n```swift\nlet x = 1\n```", stored.files.first?.text ?? "nil")
        expect(stored.imageCount == 0)
    }
    check("history: Hermes' stored image markers become an image count") {
        // Shape written by session_api_media.restore_api_images + session_rules.turns._durable_content.
        let row = "look at this\n\n[Image attached at: /h/native-inputs/ab/api_ab.png]\n[Image attached at: /h/native-inputs/cd/api_cd.png]\n[screenshot]\n[screenshot]"
        let s = ChatContent.parseStored(row)
        expect(s.text == "look at this" && s.imageCount == 2, "\(s)")
        let imageOnly = ChatContent.parseStored("What do you see in this image?\n\n[Image attached at: /x.png]\n[screenshot detail=low]")
        expect(imageOnly.text.isEmpty && imageOnly.imageCount == 1, "\(imageOnly)")
        let plain = ChatContent.parseStored("[screenshot] is a word here, and [Attached file: x] unclosed")
        expect(plain.imageCount == 0 && plain.files.isEmpty && plain.text.hasPrefix("[screenshot]"), "\(plain)")
        let unclosed = ChatContent.parseStored("[Attached file: x.txt]\n```txt\nno close")
        expect(unclosed.files.isEmpty && unclosed.text.contains("no close"), "unclosed fence kept as text")
    }
    check("limits: images, text, bytes") {
        let many = (0..<11).map { _ in ContentPart.imageURL("data:image/png;base64,AA==") }
        expect(ChatContent.problem(with: many)?.contains("10 images") == true)
        expect(ChatContent.problem(with: [.text(String(repeating: "a", count: 70_000))])?.contains("characters") == true)
        let big = "data:image/jpeg;base64," + String(repeating: "A", count: 9_100_000)
        expect(ChatContent.problem(with: [.imageURL(big)])?.contains("MB") == true)
        expect(ChatContent.problem(with: [.text("ok"), .imageURL("data:image/png;base64,AA==")]) == nil)
    }
    check("history decode: string content and part-list content") {
        let json = #"""
        [{"id":1,"role":"user","content":"hi"},
         {"id":2,"role":"user","content":[{"type":"text","text":"see"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]},
         {"id":3,"role":"assistant","content":null}]
        """#
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let msgs = try dec.decode([HermesMessage].self, from: Data(json.utf8))
        expect(msgs[0].content == "hi" && msgs[0].contentParts == nil)
        expect(msgs[1].content == "see" && msgs[1].contentParts?.count == 2, "\(msgs[1])")
        expect(msgs[2].content == nil)
    }

    guard let client = devClient() else { return }
    var done = false
    Task {
        await liveAttachmentChecks(client, png: png)
        done = true
    }
    waitPumpingRunLoop(timeout: 120) { done }
}

private func liveAttachmentChecks(_ c: HermesClient, png: Data) async {
    // Both requests are refused by request validation / the body-size middleware before any agent run starts.
    await asyncCheck("live: server parses our part list (non-image data URL -> 400 unsupported_content_type)") {
        let s = try await c.createSession(title: "checks attachments")
        do {
            for try await _ in c.chatStream(session: s.id, parts: [.text("x"), .imageURL("data:text/plain;base64,aGk=")]) {}
            expect(false, "no error")
        } catch let e as HermesError {
            expect(e.status == 400 && e.message.contains("image data URLs"), "\(e.status) \(e.message)")
        }
        let big = ChatContent.dataURL(mime: "image/png", data: png + Data(count: ChatContent.maxRequestBytes))
        do {
            for try await _ in c.chatStream(session: s.id, parts: [.text("x"), .imageURL(big)]) {}
            expect(false, "no error for oversize body")
        } catch let e as HermesError {
            expect(e.status == 413, "oversize body: \(e.status) \(e.message)")
        }
        try await c.deleteSession(s.id)
    }
    // A real image turn runs the (slow, shared) model, so it rides the existing opt-in.
    if ProcessInfo.processInfo.environment["HERMES_CHECK_CHAT"] == "1" {
        await asyncCheck("live chat with an image: stored row carries the image marker") {
            let s = try await c.createSession(title: "checks image chat")
            let parts = ChatContent.parts(text: "Reply with exactly: pong", files: [], imageURLs: [ChatContent.dataURL(mime: "image/png", data: png)])
            var started = false
            for try await e in c.chatStream(session: s.id, parts: parts) { if case .started = e { started = true } }
            expect(started)
            let msgs = try await c.messages(s.id)
            let user = msgs.first { $0.role == "user" }
            let parsed = ChatContent.parseStored(user?.content ?? "")
            expect(parsed.imageCount == 1 && parsed.text == "Reply with exactly: pong", "stored: \(user?.content ?? "nil")")
            try await c.deleteSession(s.id)
        }
    }
}
