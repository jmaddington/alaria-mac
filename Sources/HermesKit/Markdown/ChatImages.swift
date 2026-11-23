import Foundation

// AIDEV-NOTE: how Hermes puts pictures in a reply (hermes-agent @52b5271, bead hermes-mac-p81):
//  - The agent writes `MEDIA:/abs/path.png` for a file on the Hermes host. The API server rewrites those tags into
//    `![image](data:image/...;base64,...)` ONLY in the final reply (assistant.completed / run output), <= 5 MB each.
//    Streaming deltas and stored history (GET /api/sessions/{id}/messages) keep the raw `MEDIA:` tag, so those
//    are fetched from the dashboard's `GET /api/media?path=` (media roots only: images/, screenshots/, cache/).
//  - Remote images (image_gen on FAL returns a URL) arrive as `![alt](https://...)` or a bare URL line.
//  - tool.completed events carry no result payload, so image_gen output reaches us only via the reply text.
// Anything else (file://, other schemes, relative paths) is never loaded.

/// Where an image in a reply comes from, and so how (or whether) the client may load it.
public enum ImageRef: Hashable, Sendable {
    /// An http(s) URL anywhere on the internet. Loaded without credentials.
    case remote(URL)
    /// A `data:image/...;base64,` URL, decoded locally.
    case data(String)
    /// An absolute path on the Hermes host, fetched through the dashboard's authenticated `/api/media`.
    case server(String)
    /// Not loadable (file://, a relative path, another scheme); `reason` is shown instead.
    case blocked(String)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// True when `path` (or a URL's path) ends in an image extension the server will serve.
    public static func hasImageExtension(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// An absolute server path: POSIX `/x`, `~/x`, or Windows `C:\x` / `C:/x`.
    public static func isServerPath(_ s: String) -> Bool {
        if s.hasPrefix("/") && !s.hasPrefix("//") { return true }
        if s.hasPrefix("~/") { return true }
        let c = Array(s.prefix(3))
        return c.count == 3 && c[0].isLetter && c[1] == ":" && (c[2] == "/" || c[2] == "\\")
    }

    /// Classifies the target of `![alt](target)`.
    public static func classify(_ raw: String) -> ImageRef {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let lower = s.prefix(12).lowercased()
        if lower.hasPrefix("data:") {
            // The header's comma is near the front; scanning all of a multi-MB URL by Character is slow.
            return lower.hasPrefix("data:image/") && s.prefix(200).contains(",") ? .data(s) : .blocked("Only image data can be shown inline.")
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let u = URL(string: s), u.host() != nil { return .remote(u) }
            return .blocked("Invalid image address.")
        }
        if isServerPath(s) {
            return hasImageExtension(s) ? .server(s) : .blocked("Not an image file.")
        }
        if lower.hasPrefix("file:") { return .blocked("Local files aren't loaded from replies.") }
        return .blocked("Unsupported image address.")
    }

    /// The `mime` of a data URL, e.g. "image/png".
    public var dataMime: String? {
        guard case .data(let s) = self, let semi = s.firstIndex(where: { $0 == ";" || $0 == "," }) else { return nil }
        return String(s[s.index(s.startIndex, offsetBy: 5)..<semi]).lowercased()
    }
}

/// A piece of a markdown line once images are pulled out of it.
public enum ImageScanSegment: Hashable, Sendable {
    case text(String)
    case image(alt: String, ref: ImageRef)
}

public enum ImageScan {
    private static let wrapChars: Set<Character> = ["`", "\"", "'", "*", "_"]

    /// Cheap pre-check so ordinary lines (and multi-MB data URLs) skip the scanner's per-character work.
    public static func mightContainImage(_ line: String) -> Bool {
        line.contains("![") || hasMediaTag(line) || bareImageURL(line) != nil
    }

    /// `MEDIA:` / `media:`. Not `range(of:options:.caseInsensitive)`: that took 1.3 s on a 6 MB line (debug build).
    static func hasMediaTag(_ line: String) -> Bool { line.contains("MEDIA:") || line.contains("media:") }

    /// A line that is nothing but an http(s) URL to an image file (`https://x/y.png?sig=...`).
    public static func bareImageURL(_ line: String) -> URL? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let l = t.prefix(8).lowercased()
        guard l.hasPrefix("http://") || l.hasPrefix("https://"), !t.contains(where: \.isWhitespace),
              let u = URL(string: t), u.host() != nil, ImageRef.hasImageExtension(u.path) else { return nil }
        return u
    }

    /// Splits one line into text and images: `![alt](target)`, `MEDIA:<path>` tags (image extensions only; other
    /// files stay as text) and a line that is only an image URL. Returns `[.text(line)]` when there are none.
    // AIDEV-NOTE: linear scan, no regex: completed replies carry multi-MB base64 data URLs on one line.
    public static func split(_ line: String) -> [ImageScanSegment] {
        if let u = bareImageURL(line) { return [.image(alt: "", ref: .remote(u))] }
        guard line.contains("![") || hasMediaTag(line) else { return [.text(line)] }
        var out: [ImageScanSegment] = []
        var text = ""
        var i = line.startIndex
        func emitText() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(.text(t)) }
            text = ""
        }
        while i < line.endIndex {
            if line[i] == "!", let (alt, target, end) = markdownImage(line, at: i) {
                emitText(); out.append(.image(alt: alt, ref: ImageRef.classify(target))); i = end; continue
            }
            if line[i] == "M" || line[i] == "m", let (path, end) = mediaTag(line, at: i) {
                // Drop wrapping emphasis/quote characters that preceded the tag (`**MEDIA:/x.png**`).
                while let last = text.last, wrapChars.contains(last) { text.removeLast() }
                emitText(); out.append(.image(alt: "", ref: .server(path))); i = end
                while i < line.endIndex, wrapChars.contains(line[i]) || line[i] == "." { i = line.index(after: i) }
                continue
            }
            text.append(line[i]); i = line.index(after: i)
        }
        emitText()
        return out.isEmpty ? [.text("")] : out
    }

    /// `![alt](target "title")` starting at `i`: (alt, target, index after the closing paren).
    static func markdownImage(_ s: String, at i: String.Index) -> (String, String, String.Index)? {
        let open = s.index(after: i)
        guard open < s.endIndex, s[open] == "[" else { return nil }
        var j = s.index(after: open), depth = 0
        while j < s.endIndex {
            if s[j] == "[" { depth += 1 } else if s[j] == "]" { if depth == 0 { break }; depth -= 1 }
            j = s.index(after: j)
        }
        guard j < s.endIndex else { return nil }
        let alt = String(s[s.index(after: open)..<j])
        let paren = s.index(after: j)
        guard paren < s.endIndex, s[paren] == "(" else { return nil }
        var k = s.index(after: paren)
        while k < s.endIndex, s[k] == " " { k = s.index(after: k) }
        let targetStart: String.Index, targetEnd: String.Index
        if k < s.endIndex, s[k] == "<" {
            guard let close = s[k...].firstIndex(of: ">") else { return nil }
            targetStart = s.index(after: k); targetEnd = close; k = s.index(after: close)
        } else {
            // UTF-8 bytes, not Characters: grapheme iteration over a 6 MB data URL took over a second.
            // Stopping only on ASCII bytes keeps every index on a scalar boundary.
            targetStart = k
            let u = s.utf8
            var d = 0
            while k < s.endIndex {
                let b = u[k]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { break }
                if b == 0x28 { d += 1 } else if b == 0x29 { if d == 0 { break }; d -= 1 }
                k = u.index(after: k)
            }
            targetEnd = k
        }
        // Optional title, then the closing paren.
        guard let close = s[k...].firstIndex(of: ")") else { return nil }
        let target = String(s[targetStart..<targetEnd])
        guard !target.isEmpty else { return nil }
        return (alt, target, s.index(after: close))
    }

    /// `MEDIA:<path>` at `i` (case-insensitive, optional space, path bare / backticked / quoted) when the path is
    /// an absolute server path to an image. Bare paths end at whitespace, so paths with spaces need quotes.
    static func mediaTag(_ s: String, at i: String.Index) -> (String, String.Index)? {
        guard let end = s.index(i, offsetBy: 6, limitedBy: s.endIndex), s[i..<end].uppercased() == "MEDIA:" else { return nil }
        if i > s.startIndex {
            let prev = s[s.index(before: i)]
            if prev.isLetter || prev.isNumber { return nil } // "XMEDIA:" isn't a tag
        }
        var k = end
        while k < s.endIndex, s[k] == " " { k = s.index(after: k) }
        guard k < s.endIndex else { return nil }
        var path: String, after: String.Index
        if "`\"'".contains(s[k]) {
            let q = s[k]
            let start = s.index(after: k)
            guard let close = s[start...].firstIndex(of: q) else { return nil }
            path = String(s[start..<close]); after = s.index(after: close)
        } else {
            let stop = s[k...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
            path = String(s[k..<stop]); after = stop
            // Trailing punctuation belongs to the sentence, not the path.
            while let last = path.last, ".,;:)]}*_`\"'".contains(last) { path.removeLast(); after = s.index(before: after) }
        }
        guard ImageRef.isServerPath(path), ImageRef.hasImageExtension(path) else { return nil }
        return (path, after)
    }
}
