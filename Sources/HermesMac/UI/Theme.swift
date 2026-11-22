import AppKit
import SwiftUI

/// CommandLineTools ships without the SwiftUI macro plugin; this resolves to the classic `State` property
/// wrapper instead of the macOS 27 `@State` macro. Same reason there are no #Preview / @Entry macros.
// AIDEV-NOTE: always write `@ViewState`, never `@State`, or the CLT build breaks.
typealias ViewState = SwiftUI.State

enum Theme {
    /// Hermes' accent: a deep, calm indigo. Used sparingly - selection, the user's bubble, the orb.
    static let accent = Color(red: 0.36, green: 0.39, blue: 0.96)
    static let accentSoft = Color(red: 0.36, green: 0.39, blue: 0.96).opacity(0.12)
    static let readingWidth: CGFloat = 720
    static let corner: CGFloat = 14
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).blur(radius: 1.5))
    }
}

/// A quiet, centered placeholder. Every empty pane says what it is and what to do, never just "No data".
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            if let action { Button(action.label, action: action.run).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).textCase(.uppercase).tracking(0.4)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Shown in dashboard-only panes when the dashboard isn't connected.
struct NeedsDashboard: View {
    @Environment(\.openSettings) private var openSettings
    var feature: String
    var body: some View {
        EmptyState(symbol: "server.rack", title: "\(feature) lives on the dashboard",
                   message: "Connect your Hermes dashboard (hermes dashboard or hermes serve) in Settings to manage \(feature.lowercased()) here.",
                   action: ("Open Settings", { openSettings() }))
    }
}

extension Date {
    var relative: String {
        // Server and client clocks drift; anything within a minute (or "in the future") is just "now".
        if timeIntervalSinceNow > -60 { return "now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

extension Int {
    var compact: String { formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
}
