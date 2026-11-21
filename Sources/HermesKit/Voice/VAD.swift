import Foundation

// AIDEV-NOTE: straight port of drive-mode public/vad.js (jmaddington/drive-mode). Do NOT "simplify" the floor:
// it is the 20th percentile of the last 4 s because a minimum-based floor never closed the mic on real noise.
// Feed it one RMS value per 20 ms frame of band-passed (300-3400 Hz) 16 kHz mono audio. Tests: VADTests.swift.
public struct VAD: Sendable {
    public enum Event: Equatable, Sendable { case start, end, discard }

    public var startDb: Double = 6, endDb: Double = 5, absDb: Double = -62
    public var startMs: Double = 160, endMs: Double = 1100, minMs: Double = 400, maxMs: Double = 30_000
    public var frameMs: Double = 20, histMs: Double = 4000, warmMs: Double = 500

    public private(set) var floor: Double = -200
    public private(set) var smooth: Double?
    public private(set) var active = false
    private var hist: [Double] = []
    private var above: Double = 0, below: Double = 0, dur: Double = 0, voiced: Double = 0

    public init() {}

    /// Returns .start / .end / .discard or nil for each frame.
    public mutating func frame(rms: Double) -> Event? {
        let db = 20 * log10(max(rms, 1e-7))
        let s = smooth.map { $0 + (db - $0) * 0.25 } ?? db // ~80 ms; raw frames jitter past any margin
        smooth = s
        hist.append(s)
        if Double(hist.count) > histMs / frameMs { hist.removeFirst() }
        if Double(hist.count) * frameMs < warmMs { return nil }
        floor = hist.sorted()[Int(Double(hist.count) * 0.2)]
        if !active {
            let hot = s > max(floor + startDb, absDb)
            above = hot ? above + frameMs : max(0, above - frameMs)
            if above >= startMs {
                active = true; dur = above; voiced = above; below = 0; above = 0
                return .start
            }
            return nil
        }
        dur += frameMs
        if s < max(floor + endDb, absDb - 3) { below += frameMs } else { below = 0; voiced += frameMs }
        if below >= endMs || dur >= maxMs {
            active = false; below = 0
            return voiced >= minMs ? .end : .discard
        }
        return nil
    }

    public mutating func reset() { active = false; above = 0; below = 0; dur = 0; voiced = 0 }
}

/// Speech-to-text output filter, ported from drive-mode server.py `is_noise`.
/// Speech models hallucinate the biasing prompt back from pure noise.
public func isNoiseTranscript(_ text: String, prompt: String) -> Bool {
    func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
    }
    let w = words(text)
    if w.isEmpty { return true }
    let p = Set(words(prompt))
    return w.count >= 5 && Double(w.filter(p.contains).count) / Double(w.count) > 0.8
}

/// Splits streamed reply text into speakable sentences (drive-mode `say` regex: `(?<=[.!?])\s+|\n+`)
/// and strips markdown so the voice doesn't read "asterisk".
public struct SentenceSplitter: Sendable {
    private var buffer = ""
    public init() {}

    /// Feed a delta; returns any complete sentences.
    public mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let r = nextBoundary(in: buffer) {
            let s = String(buffer[..<r.lowerBound])
            buffer = String(buffer[r.upperBound...])
            if let c = Self.clean(s) { out.append(c) }
        }
        return out
    }

    /// Whatever is left at end of stream.
    public mutating func flush() -> [String] {
        defer { buffer = "" }
        return Self.clean(buffer).map { [$0] } ?? []
    }

    private func nextBoundary(in s: String) -> Range<String.Index>? {
        // Sentence end followed by whitespace, or any newline run. Needs the trailing whitespace to have
        // arrived, so "3." in "3.5" mid-stream is never split early.
        s.range(of: #"(?<=[.!?])\s+|\n+"#, options: .regularExpression)
    }

    public static func clean(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[-•]\s+"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
