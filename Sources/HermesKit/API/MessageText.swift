import Foundation

/// Display cleanup for text Hermes stores in messages. Pure Foundation (shared with the iOS app).
public enum MessageText {
    /// Hermes prefixes a scheduled job's prompt with internal blocks ("[IMPORTANT: You are running as a scheduled
    /// cron job. ...]" and "[CURRENT RUN TIME: ...]"). They're plumbing, not what the user wrote: strip them for display.
    // AIDEV-NOTE: found by the iOS port's testers 2026-11-22; keep the stored text untouched (display only).
    public static func display(_ text: String) -> String {
        var s = Substring(text)
        let preambles = ["[IMPORTANT: You are running as a scheduled cron job", "[CURRENT RUN TIME:"]
        while true {
            let trimmed = s.drop { $0.isWhitespace }
            guard preambles.contains(where: { trimmed.hasPrefix($0) }) else { return String(trimmed) }
            // The block ends at the first "]" that closes a line; fall back to the first "]".
            if let close = trimmed.range(of: "]\n") ?? trimmed.range(of: "]") { s = trimmed[close.upperBound...] }
            else { return "" } // truncated (e.g. a list preview cut mid-preamble): nothing the user wrote is visible
        }
    }

    /// Text Hermes uses for a turn that was stopped: live ("Operation interrupted: waiting for model response (12s
    /// elapsed).") or as stored in history ("Your request was not processed. Send it again...").
    public static func isInterruption(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("Operation interrupted:") || t.hasPrefix("Your request was not processed.")
    }
}
