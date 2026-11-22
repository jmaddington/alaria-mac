import Foundation

// AIDEV-NOTE: wire format for chat attachments (beads hermes-mac-ard / -6uj). Platform-neutral on purpose: no AppKit
// here, the iOS client compiles HermesKit too. Server facts (hermes-agent gateway/platforms/api_server.py, checked
// 2026-11-22): POST /api/sessions/{id}/chat/stream reads body "message" (or "input") as a string OR an OpenAI-style
// part list; only text + image_url/input_image parts are accepted ("file"/"input_file" -> 400
// unsupported_content_type), image URLs must be data:image/... or http(s). Limits: 10 MB request body, 64 KiB of
// text (silently truncated), 10 images per turn. The DB keeps user rows as TEXT: each image becomes "[screenshot]"
// plus an "[Image attached at: <server path>]" hint, so history can never return the pixels.

/// One OpenAI-style content part for a user turn.
public enum ContentPart: Hashable, Sendable {
    case text(String)
    /// A `data:image/...;base64,` URL (or http(s) URL).
    case imageURL(String)

    public var json: [String: Any] {
        switch self {
        case .text(let t): return ["type": "text", "text": t]
        case .imageURL(let u): return ["type": "image_url", "image_url": ["url": u]]
        }
    }
}

/// A text-like file inlined into the message as a fenced block (Hermes has no document/file input).
public struct InlineFile: Hashable, Sendable {
    public var name: String
    public var text: String
    public init(name: String, text: String) { self.name = name; self.text = text }
}

/// What a stored user message carried, recovered from Hermes' text-only DB projection.
public struct StoredUserContent: Hashable, Sendable {
    public var text: String
    public var imageCount: Int
    public var files: [InlineFile]
}

public enum ChatContent {
    public static let maxRequestBytes = 10_000_000
    /// Our own ceiling for the encoded message, leaving headroom under `maxRequestBytes` for JSON overhead.
    public static let maxPayloadBytes = 9_000_000
    public static let maxTextCharacters = 65_536
    public static let maxImages = 10
    /// Hermes substitutes this text when a turn has images but no text part (session_api_media.restore_api_images).
    static let serverDefaultImagePrompt = "What do you see in this image?"

    public static func dataURL(mime: String, data: Data) -> String { "data:\(mime);base64,\(data.base64EncodedString())" }

    /// Length of the base64 data URL for `data`; used to budget the request before encoding.
    public static func encodedSize(mime: String, bytes: Int) -> Int { "data:\(mime);base64,".utf8.count + (bytes + 2) / 3 * 4 }

    /// The fenced block a text file is inlined as. The fence is longer than any backtick run in the file so
    /// the block can't be closed early, and `parseStored` can find it again on history reload.
    public static func inline(_ f: InlineFile) -> String {
        var longest = 0, run = 0
        for ch in f.text { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let ext = (f.name as NSString).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let body = f.text.hasSuffix("\n") ? f.text : f.text + "\n"
        return "[Attached file: \(f.name)]\n\(fence)\(ext)\n\(body)\(fence)"
    }

    /// The text part: what the user typed, then each inlined file.
    public static func text(_ typed: String, files: [InlineFile]) -> String {
        ([typed.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } + files.map(inline)).joined(separator: "\n\n")
    }

    /// Parts for one user turn: one text part (typed text + inlined files) then the images. No text part at all when
    /// there is only images (Hermes then supplies its own prompt). Empty when there is nothing to send.
    public static func parts(text typed: String, files: [InlineFile], imageURLs: [String]) -> [ContentPart] {
        let t = text(typed, files: files)
        return (t.isEmpty ? [] : [.text(t)]) + imageURLs.map(ContentPart.imageURL)
    }

    /// The JSON value for the body's "message" field: a plain string when there are no images (the server
    /// collapses text-only part lists to a string anyway), else the part list.
    public static func messageValue(_ parts: [ContentPart]) -> Any {
        if parts.allSatisfy({ if case .text = $0 { return true }; return false }) {
            return parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
        }
        return parts.map(\.json)
    }

    /// Request body bytes for `POST .../chat/stream`.
    public static func body(_ parts: [ContentPart]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["message": messageValue(parts)])
    }

    /// Why this turn would be refused or truncated by Hermes, as a sentence for the user; nil when it's fine.
    public static func problem(with parts: [ContentPart]) -> String? {
        var images = 0, bytes = 0, chars = 0
        for p in parts {
            switch p {
            case .text(let t): chars += t.count; bytes += t.utf8.count
            case .imageURL(let u): images += 1; bytes += u.utf8.count
            }
        }
        if images > maxImages { return "Hermes accepts up to \(maxImages) images per message; this one has \(images)." }
        if chars > maxTextCharacters {
            return "The message and attached text total \(chars.formatted()) characters; Hermes reads at most \(maxTextCharacters.formatted()). Remove or trim a file."
        }
        if bytes > maxPayloadBytes {
            let mb = { (n: Int) in String(format: "%.1f MB", Double(n) / 1_000_000) }
            return "Attachments add up to \(mb(bytes)); Hermes accepts about \(mb(maxPayloadBytes)) per message. Remove one or send it separately."
        }
        return nil
    }

    // MARK: history

    private static let hintLine = try! NSRegularExpression(pattern: #"^\[Image attached(?: at)?: .+\]$"#)
    private static let markerLine = try! NSRegularExpression(pattern: #"^\[screenshot(?: detail=(?:low|high|auto))?\]$"#)
    private static let fileHeader = try! NSRegularExpression(pattern: #"^\[Attached file: (.+)\]$"#)
    private static let fenceOpen = try! NSRegularExpression(pattern: #"^(`{3,})[A-Za-z0-9]*$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// Splits a stored user row back into typed text, image count and inlined files. Image markers and server-path
    /// hints are dropped (their pixels aren't retrievable), as is Hermes' default prompt for image-only turns.
    public static func parseStored(_ content: String) -> StoredUserContent {
        let lines = content.components(separatedBy: "\n")
        var kept: [String] = [], files: [InlineFile] = []
        var hints = 0, markers = 0, i = 0
        while i < lines.count {
            let line = lines[i]
            if matches(hintLine, line) != nil { hints += 1; i += 1; continue }
            if matches(markerLine, line) != nil { markers += 1; i += 1; continue }
            if let h = matches(fileHeader, line), i + 1 < lines.count, let f = matches(fenceOpen, lines[i + 1]),
               let nameRange = Range(h.range(at: 1), in: line), let fenceRange = Range(f.range(at: 1), in: lines[i + 1]) {
                let fence = String(lines[i + 1][fenceRange])
                if let close = lines[(i + 2)...].firstIndex(of: fence) {
                    files.append(InlineFile(name: String(line[nameRange]), text: lines[(i + 2)..<close].joined(separator: "\n")))
                    i = close + 1
                    continue
                }
            }
            kept.append(line)
            i += 1
        }
        let images = max(hints, markers)
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if images > 0 && text == serverDefaultImagePrompt { text = "" }
        return StoredUserContent(text: text, imageCount: images, files: files)
    }

    /// Image URLs and text from a part list, for servers that return user content as parts rather than text.
    public static func split(_ parts: [ContentPart]) -> (text: String, imageURLs: [String]) {
        var texts: [String] = [], urls: [String] = []
        for p in parts {
            switch p {
            case .text(let t): texts.append(t)
            case .imageURL(let u): urls.append(u)
            }
        }
        return (texts.joined(separator: "\n"), urls)
    }

    /// Decodes a loosely-typed content array (`[{type:text,...},{type:image_url,...}]`) into parts.
    public static func parts(from value: JSONValue) -> [ContentPart]? {
        guard case .array(let items) = value else { return nil }
        return items.compactMap { item in
            switch item["type"]?.string?.lowercased() {
            case "text", "input_text", "output_text": return item["text"]?.string.map(ContentPart.text)
            case "image_url", "input_image":
                let u = item["image_url"]?["url"]?.string ?? item["image_url"]?.string
                return u.map(ContentPart.imageURL)
            default: return item.string.map(ContentPart.text)
            }
        }
    }

    /// `(mime, bytes)` of a base64 image data URL.
    public static func decodeDataURL(_ url: String) -> (mime: String, data: Data)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.lowercased().hasSuffix(";base64"), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return (String(header.dropLast(7)), data)
    }
}
