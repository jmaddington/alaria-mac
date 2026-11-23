import Foundation
import HermesKit

/// Reply-image parsing (bead hermes-mac-p81): markdown images, MEDIA: tags, bare URLs, history paths, and the
/// dashboard /api/media route.
func runImageChecks() {
    let png = "data:image/png;base64,iVBORw0KGgo="
    check("images: markdown data URL becomes its own block") {
        let b = MarkdownParser.parse("Here it is:\n\n![image](\(png))")
        expect(b == [.paragraph("Here it is:"), .image(alt: "image", ref: .data(png))], "\(b)")
    }
    check("images: text around an inline image stays in paragraphs") {
        let b = MarkdownParser.parse("before ![a cat](https://x.example/cat.jpg \"title\") after")
        expect(b == [.paragraph("before"), .image(alt: "a cat", ref: .remote(URL(string: "https://x.example/cat.jpg")!)), .paragraph("after")], "\(b)")
    }
    check("images: MEDIA tags (bare, quoted, emphasised, trailing period) are server images") {
        expect(MarkdownParser.parse("MEDIA:/h/.hermes/cache/images/a.png") == [.image(alt: "", ref: .server("/h/.hermes/cache/images/a.png"))])
        let b = MarkdownParser.parse("Done: MEDIA: `/h/my pics/b.jpeg`.")
        expect(b == [.paragraph("Done:"), .image(alt: "", ref: .server("/h/my pics/b.jpeg"))], "\(b)")
        let c = MarkdownParser.parse("**MEDIA:/x/c.webp**.")
        expect(c == [.image(alt: "", ref: .server("/x/c.webp"))], "\(c)")
        expect(MarkdownParser.parse("media:C:\\out\\d.png") == [.image(alt: "", ref: .server("C:\\out\\d.png"))])
    }
    check("images: non-image MEDIA tags and partial streamed paths stay text") {
        expect(MarkdownParser.parse("MEDIA:/x/song.mp3") == [.paragraph("MEDIA:/x/song.mp3")])
        expect(MarkdownParser.parse("MEDIA:/x/ima") == [.paragraph("MEDIA:/x/ima")])
        expect(MarkdownParser.parse("SOCIALMEDIA:/x/a.png") == [.paragraph("SOCIALMEDIA:/x/a.png")])
    }
    check("images: an image in a list item follows the item; numbering resumes") {
        let b = MarkdownParser.parse("1. First: MEDIA:/x/a.png\n2. Second")
        expect(b == [.numbered(start: 1, [MDListItem(text: "First:")]), .image(alt: "", ref: .server("/x/a.png")),
                     .numbered(start: 2, [MDListItem(text: "Second")])], "\(b)")
    }
    check("images: a bare image URL line, but not a URL inside a sentence") {
        let u = "https://v3.fal.media/files/x/out.png?sig=1"
        expect(MarkdownParser.parse(u) == [.image(alt: "", ref: .remote(URL(string: u)!))])
        expect(MarkdownParser.parse("see https://x.example/a.png now") == [.paragraph("see https://x.example/a.png now")])
        expect(MarkdownParser.parse("https://x.example/page") == [.paragraph("https://x.example/page")])
    }
    check("images: file://, other schemes, relative paths and non-image data are blocked") {
        for t in ["file:///etc/a.png", "javascript:alert(1)", "pic.png", "data:text/html;base64,PGI+", "/etc/passwd"] {
            if case .blocked = ImageRef.classify(t) {} else { expect(false, "\(t) -> \(ImageRef.classify(t))") }
        }
        expect(ImageRef.classify("/srv/x.PNG") == .server("/srv/x.PNG"))
        expect(ImageRef.classify(png).dataMime == "image/png")
    }
    check("images: code blocks and links are untouched") {
        expect(MarkdownParser.parse("```\n![x](https://a.example/b.png)\n```") == [.code(lang: "", body: "![x](https://a.example/b.png)")])
        expect(MarkdownParser.parse("[link](https://a.example/b.png)") == [.paragraph("[link](https://a.example/b.png)")])
    }
    check("images: a multi-MB data URL line parses quickly") {
        let big = "![image](data:image/png;base64," + String(repeating: "A", count: 6_000_000) + ")"
        let t0 = Date()
        let b = MarkdownParser.parse("Result:\n" + big)
        let took = Date().timeIntervalSince(t0)
        expect(b.count == 2, "\(b.count)")
        expect(took < 2, "took \(took) s")
    }
    check("images: history user row keeps the server path of each image") {
        let s = ChatContent.parseStored("look\n\n[Image attached at: /h/cache/documents/native-inputs/ab/api_1.png]\n[screenshot]")
        expect(s.text == "look" && s.imageCount == 1 && s.imagePaths == ["/h/cache/documents/native-inputs/ab/api_1.png"], "\(s)")
    }
    check("images: voice doesn't read image markup or MEDIA paths") {
        expect(SentenceSplitter.clean("Here: ![a chart](data:image/png;base64,AAAA)") == "Here:")
        expect(SentenceSplitter.clean("MEDIA:/h/cache/images/a.png") == nil)
    }

    guard let client = devClient() else { return }
    var done = false
    Task {
        await asyncCheck("live: dashboard /api/media refuses paths outside the media roots") {
            do {
                _ = try await client.media(path: "/etc/not-media.png")
                expect(false, "no error")
            } catch let e as HermesError {
                expect(e.status == 403, "\(e.status) \(e.message)")
            }
        }
        done = true
    }
    waitPumpingRunLoop(timeout: 30) { done }
}
