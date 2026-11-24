import Foundation

/// Live Markdown styling for the message composer (hermes-mac-9ey): which ranges of the draft are quotes, code,
/// emphasis or syntax markers. The text itself stays Markdown (that's what gets sent); the composer only restyles it.
/// Ranges are NSRange (UTF-16) so NSTextView / UITextView can apply them directly. Platform-neutral on purpose.
// AIDEV-NOTE: a line-based approximation of CommonMark, tuned for typing (Buzz's composer behaves the same way):
// fences ``` / ~~~, "> " quotes, list markers, `code`, **bold** / __bold__, *italic* / _italic_, ~~strike~~.
// No headings: "#tag" in chat is usually not a heading. Keep it cheap: the composer reruns it on every edit.
public enum MarkdownSpans {
    public enum Kind: Equatable, Sendable {
        case quote          // a whole "> " line (text after the marker)
        case fence          // a ``` / ~~~ line, opener or closer
        case codeBlock      // a line inside a fenced block
        case inlineCode     // text between backticks
        case bold, italic, strike
        case listMarker     // "- ", "1. "
        case marker         // syntax characters to fade: "> ", backticks, ** _ ~~
    }
    public struct Span: Equatable, Sendable {
        public var kind: Kind
        public var range: NSRange
        public init(_ kind: Kind, _ range: NSRange) { self.kind = kind; self.range = range }
    }

    /// Drafts longer than this aren't styled (keeps typing fast on a huge paste).
    public static let maxLength = 50_000

    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= maxLength else { return [] }
        var out: [Span] = []
        var inFence = false
        var fenceChar: Character = "`"
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let s = ns.substring(with: line)
            let trimmed = s.drop { $0 == " " }
            if let f = fenceOpener(trimmed), !inFence || f == fenceChar {
                out.append(Span(.fence, line))
                if inFence { inFence = false } else { inFence = true; fenceChar = f }
                return
            }
            if inFence { out.append(Span(.codeBlock, line)); return }
            var body = line // what inline styling scans
            let lead = s.count - trimmed.count
            if lead <= 3, trimmed.hasPrefix(">") {
                let markerLen = trimmed.dropFirst().hasPrefix(" ") ? 2 : 1
                let m = NSRange(location: line.location + lead, length: markerLen)
                out.append(Span(.marker, m))
                body = NSRange(location: m.upperBound, length: line.upperBound - m.upperBound)
                out.append(Span(.quote, body))
            } else if let n = listMarkerLength(trimmed) {
                out.append(Span(.listMarker, NSRange(location: line.location + lead, length: n)))
            }
            out += inline(ns, in: body)
        }
        return out
    }

    /// True when the caret sits inside a fenced code block (an odd number of fence lines start before its line,
    /// counting the caret's own line if that's an opener): there, Return should start a new line, not send.
    public static func isInsideOpenFence(_ text: String, caret: Int) -> Bool {
        let ns = text as NSString
        let caret = min(max(caret, 0), ns.length)
        var open = false
        var fenceChar: Character = "`"
        var stop = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, halt in
            if line.location > caret { stop = true; halt.pointee = true; return }
            let trimmed = ns.substring(with: line).drop { $0 == " " }
            if let f = fenceOpener(trimmed), !open || f == fenceChar {
                // A closer on the caret's own line ends the block: Return after it sends.
                if open { open = false } else { open = true; fenceChar = f }
            }
        }
        _ = stop
        return open
    }

    // MARK: - pieces

    /// "```", "```swift", "~~~" -> the fence character; nil otherwise.
    static func fenceOpener(_ s: Substring) -> Character? {
        for f: Character in ["`", "~"] where s.hasPrefix(String(repeating: f, count: 3)) {
            // An info string can't contain the fence char for backtick fences (CommonMark); "```x```" is inline code.
            let rest = s.drop { $0 == f }
            if f == "`" && rest.contains("`") { return nil }
            return f
        }
        return nil
    }

    static func listMarkerLength(_ s: Substring) -> Int? {
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " { return 2 }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = s.dropFirst(digits.count)
        guard let p = rest.first, p == "." || p == ")", rest.dropFirst().first == " " else { return nil }
        return digits.count + 2
    }

    /// Inline code first (it wins over emphasis), then emphasis outside code.
    static func inline(_ ns: NSString, in r: NSRange) -> [Span] {
        guard r.length > 0 else { return [] }
        var out: [Span] = []
        var code: [NSRange] = []
        // Backtick runs pair with the next run of the same length on the line.
        var i = r.location
        let end = r.upperBound
        let tick: unichar = 96 // `
        while i < end {
            guard ns.character(at: i) == tick else { i += 1; continue }
            var n = 0
            while i + n < end, ns.character(at: i + n) == tick { n += 1 }
            var j = i + n, closed = false
            while j < end {
                guard ns.character(at: j) == tick else { j += 1; continue }
                var m = 0
                while j + m < end, ns.character(at: j + m) == tick { m += 1 }
                if m == n {
                    out.append(Span(.marker, NSRange(location: i, length: n)))
                    out.append(Span(.marker, NSRange(location: j, length: m)))
                    if j > i + n { out.append(Span(.inlineCode, NSRange(location: i + n, length: j - i - n))) }
                    code.append(NSRange(location: i, length: j + m - i))
                    i = j + m; closed = true; break
                }
                j += m
            }
            if !closed { i += n }
        }
        for (kind, pattern, markerLen) in emphasis {
            for m in pattern.matches(in: ns as String, range: r) {
                let whole = m.range
                guard !code.contains(where: { NSIntersectionRange($0, whole).length > 0 }) else { continue }
                out.append(Span(.marker, NSRange(location: whole.location, length: markerLen)))
                out.append(Span(.marker, NSRange(location: whole.upperBound - markerLen, length: markerLen)))
                out.append(Span(kind, NSRange(location: whole.location + markerLen, length: whole.length - 2 * markerLen)))
            }
        }
        return out
    }

    // Content must start and end with a non-space (so "2 * 3 * 4" isn't italic); "_" only at word edges.
    private static let emphasis: [(Kind, NSRegularExpression, Int)] = [
        (.bold, try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), 2),
        (.bold, try! NSRegularExpression(pattern: #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#), 2),
        (.strike, try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#), 2),
        (.italic, try! NSRegularExpression(pattern: #"(?<![\*\w])\*(?=[^\s\*])([^\*]+?)(?<=[^\s\*])\*(?![\*\w])"#), 1),
        (.italic, try! NSRegularExpression(pattern: #"(?<![_\w])_(?=[^\s_])([^_]+?)(?<=[^\s_])_(?![_\w])"#), 1),
    ]
}
