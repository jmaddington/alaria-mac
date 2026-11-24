import AppKit
import HermesKit
import SwiftUI

/// The message box: an NSTextView that keeps the draft as plain Markdown and styles it live as you type
/// ("> " quotes get a bar, `code` and ``` blocks get a code font and background, **bold** / *italic* / ~~strike~~,
/// markers faded). What's sent is exactly the Markdown typed. Bead hermes-mac-9ey; parsing is HermesKit MarkdownSpans.
// AIDEV-NOTE: keys. Return sends (or newline in "Send with Cmd+Return" mode, and always inside an open ``` block);
// Shift/Option+Return insert a newline. The / menu, @mentions and image paste use window-level NSEvent monitors,
// which run before this view's keyDown, and Cmd+Return / busy shortcuts are SwiftUI keyboardShortcuts
// (performKeyEquivalent), so none of them are handled here.
// AIDEV-NOTE: styling only ever changes attributes, never characters, and skips while IME marked text is open.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// Mirrors first-responder state (the / and @ menus and image paste key off it).
    @Binding var focused: Bool
    @Binding var height: CGFloat
    /// Bump to put the caret in the box (on appear, on chat switch).
    var focusRequest: Int
    var onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    static let maxLines: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerNSTextView(usingTextLayoutManager: false) // TextKit 1: the bar/background drawing uses it
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false // they break `code` and ```
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.typingAttributes = Coordinator.base
        tv.setAccessibilityLabel("Message Hermes")
        tv.postsFrameChangedNotifications = true

        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.documentView = tv
        context.coordinator.textView = tv
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: tv)
        tv.string = text
        context.coordinator.restyle()
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        tv.isEditable = isEnabled
        tv.isSelectable = true
        if tv.string != text, !tv.hasMarkedText() {
            // Changed from outside (sent, slash/mention completion, chat switch): replace and put the caret at the end.
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            c.restyle()
        }
        if focusRequest != c.lastFocusRequest {
            c.lastFocusRequest = focusRequest
            DispatchQueue.main.async { if let w = tv.window, w.firstResponder !== tv { w.makeFirstResponder(tv) } }
        }
    }

    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var lastFocusRequest = Int.min

        init(_ p: ComposerTextView) { parent = p }

        static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        static let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        static let paragraph: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineSpacing = 2; return p }()
        static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                                                          .paragraphStyle: paragraph]

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            restyle()
        }

        func submit() { parent.onSubmit() }
        func focusChanged(_ on: Bool) {
            guard parent.focused != on else { return }
            DispatchQueue.main.async { self.parent.focused = on }
        }

        @objc func frameChanged() { measure() }

        /// Re-applies Markdown styling to the whole draft (drafts are short; MarkdownSpans caps the length).
        func restyle() {
            guard let tv = textView, let storage = tv.textStorage, !tv.hasMarkedText() else { measure(); return }
            let full = NSRange(location: 0, length: storage.length)
            let order: [MarkdownSpans.Kind] = [.quote, .codeBlock, .fence, .inlineCode, .bold, .italic, .strike, .listMarker, .marker]
            let spans = MarkdownSpans.spans(in: storage.string)
                .sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
            let ns = storage.string as NSString
            storage.beginEditing()
            storage.setAttributes(Self.base, range: full)
            for s in spans where s.range.upperBound <= storage.length {
                switch s.kind {
                case .quote:
                    let para = ns.paragraphRange(for: s.range)
                    let p = NSMutableParagraphStyle(); p.lineSpacing = 2; p.firstLineHeadIndent = 12; p.headIndent = 12
                    storage.addAttributes([.paragraphStyle: p, .composerQuote: true], range: para)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: s.range)
                case .codeBlock, .fence:
                    let para = ns.paragraphRange(for: s.range)
                    let p = NSMutableParagraphStyle(); p.lineSpacing = 2; p.firstLineHeadIndent = 8; p.headIndent = 8
                    storage.addAttributes([.paragraphStyle: p, .composerCode: true, .font: Self.mono], range: para)
                    if s.kind == .fence { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: s.range) }
                case .inlineCode:
                    storage.addAttributes([.font: Self.mono, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08)], range: s.range)
                case .bold: addTrait(.boldFontMask, storage, s.range)
                case .italic: addTrait(.italicFontMask, storage, s.range)
                case .strike: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: s.range)
                case .listMarker: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: s.range)
                case .marker: storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: s.range)
                }
            }
            storage.endEditing()
            tv.typingAttributes = Self.base
            tv.needsDisplay = true
            measure()
        }

        private func addTrait(_ t: NSFontTraitMask, _ storage: NSTextStorage, _ r: NSRange) {
            storage.enumerateAttribute(.font, in: r) { v, sub, _ in
                let f = (v as? NSFont) ?? Self.font
                storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: t), range: sub)
            }
        }

        /// Grows the box with its text, 1 to maxLines lines, then scrolls.
        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = lm.defaultLineHeight(for: Self.font) + 2
            let used = lm.usedRect(for: tc).height
            let inset = tv.textContainerInset.height * 2
            let h = min(max(used, line), line * ComposerTextView.maxLines) + inset
            if abs(h - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

extension NSAttributedString.Key {
    static let composerQuote = NSAttributedString.Key("alaria.composerQuote")
    static let composerCode = NSAttributedString.Key("alaria.composerCode")
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    override func keyDown(with e: NSEvent) {
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        guard isReturn, !hasMarkedText() else { super.keyDown(with: e); return }
        let mods = e.modifierFlags.intersection([.shift, .option, .command, .control])
        if mods == [.shift] || mods == [.option] { insertNewline(nil); return }
        if mods.isEmpty {
            let inFence = MarkdownSpans.isInsideOpenFence(string, caret: selectedRange().location)
            if SendKey.current == .commandReturn || inFence { insertNewline(nil); return }
            coordinator?.submit()
            return
        }
        super.keyDown(with: e)
    }

    /// Escape in an NSTextView opens the word-completion popup; in a chat box it should do nothing (the / and @
    /// menus catch their own Escape first). Pass it up the chain in case something above wants it.
    override func cancelOperation(_ sender: Any?) { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        return ok
    }

    /// Only text drops land in the box; files and images fall through to the conversation's attachment drop target.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Quote bars and code-block backgrounds, drawn behind the text line by line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let width = tc.size.width
        func lines(_ key: NSAttributedString.Key, _ draw: @escaping (NSRect) -> Void) {
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                guard v != nil else { return }
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                lm.enumerateLineFragments(forGlyphRange: g) { frag, _, _, _, _ in
                    draw(frag.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        lines(.composerCode) { f in NSRect(x: f.minX, y: f.minY, width: width, height: f.height).fill() }
        Theme.accentNS.withAlphaComponent(0.7).setFill()
        lines(.composerQuote) { f in NSBezierPath(roundedRect: NSRect(x: f.minX, y: f.minY + 1, width: 3, height: f.height - 2), xRadius: 1.5, yRadius: 1.5).fill() }
    }
}
