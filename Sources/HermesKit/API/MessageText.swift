import Foundation

/// Display cleanup for text Hermes stores in messages. Pure Foundation (shared with the iOS app).
public enum MessageText {
    /// Hermes prefixes a scheduled job's prompt with internal blocks ("[IMPORTANT: You are running as a scheduled
    /// cron job. ...]" and "[CURRENT RUN TIME: ...]"). They're plumbing, not what the user wrote: strip them for display.
    // AIDEV-NOTE: found by the iOS port's testers 2026-11-22; keep the stored text untouched (display only).
    public static func display(_ text: String) -> String {
        var s = Substring(unwrapSteer(text))
        let preambles = ["[IMPORTANT: You are running as a scheduled cron job", "[CURRENT RUN TIME:"]
        while true {
            let trimmed = s.drop { $0.isWhitespace }
            guard preambles.contains(where: { trimmed.hasPrefix($0) }) else { return String(trimmed) }
            // The block ends at the first "]" that closes a line; fall back to the first "]".
            if let close = trimmed.range(of: "]\n") ?? trimmed.range(of: "]") { s = trimmed[close.upperBound...] }
            else { return "" } // truncated (e.g. a list preview cut mid-preamble): nothing the user wrote is visible
        }
    }

    static let steerOpen = "[OUT-OF-BAND USER MESSAGE"
    static let steerClose = "[/OUT-OF-BAND USER MESSAGE]"

    /// A message sent while a run is in progress ("steer") is stored wrapped for the model:
    /// "[OUT-OF-BAND USER MESSAGE — a direct message from the user, ...]\n<text>\n[/OUT-OF-BAND USER MESSAGE]".
    /// Show only what the user wrote. Several blocks and surrounding text are allowed; an unclosed block (a list
    /// preview cut short) keeps whatever follows its header; a stray closing marker is removed.
    // AIDEV-NOTE: same rule as hermes-agent's desktop app (apps/desktop/e2e/core/oracle.ts STEER_RE) and the
    // Linux/Android ports. Display only: the stored text is never changed.
    static func unwrapSteer(_ text: String) -> String {
        guard text.contains(steerOpen) || text.contains(steerClose) else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: steerOpen) {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            // The header ends at its first "]"; none means the preview was cut mid-header.
            guard let headerEnd = afterOpen.firstIndex(of: "]") else { rest = ""; break }
            let body = afterOpen[afterOpen.index(after: headerEnd)...]
            if let close = body.range(of: steerClose) {
                out += body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                rest = body[close.upperBound...]
            } else {
                out += body.trimmingCharacters(in: .whitespacesAndNewlines)
                rest = ""
            }
        }
        out += rest
        return out.replacingOccurrences(of: steerClose, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text Hermes uses for a turn that was stopped: live ("Operation interrupted: waiting for model response (12s
    /// elapsed).") or as stored in history ("Your request was not processed. Send it again...").
    public static func isInterruption(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("Operation interrupted:") || t.hasPrefix("Your request was not processed.")
    }
}
