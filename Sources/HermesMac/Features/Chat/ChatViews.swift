import HermesKit
import SwiftUI

// MARK: - Session list (content column)

struct SessionList: View {
    @Environment(AppModel.self) private var model
    @ViewState private var renaming: HermesSession?
    @ViewState private var deleting: HermesSession?
    @ViewState private var newTitle = ""

    private var chats: ChatStore { model.chats }

    var body: some View {
        @Bindable var chats = model.chats
        let selection = Binding<String?>(get: { chats.selection }, set: { chats.select($0) })
        List(selection: selection) {
            if !chats.searchText.isEmpty && model.client?.hasDashboard == true {
                SwiftUI.Section("Matches") {
                    ForEach(chats.searchHits) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title ?? "Untitled").font(.body.weight(.medium)).lineLimit(1)
                            Text(hit.snippet?.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: "") ?? "")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .hoverRow().tag(Optional(hit.sessionId))
                    }
                    if chats.searchHits.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                }
            } else {
                ForEach(groups, id: \.title) { g in
                    SwiftUI.Section(g.title) {
                        ForEach(g.items) { s in
                            SessionRow(session: s).hoverRow().tag(Optional(s.id)).contextMenu { menu(for: s) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if chats.sessions.isEmpty && !chats.loadingSessions && chats.searchText.isEmpty {
                EmptyState(symbol: "bubble.left.and.bubble.right", title: "No chats yet", message: "Start a conversation and it will appear here.")
            }
        }
        .searchable(text: $chats.searchText, placement: .sidebar, prompt: model.client?.hasDashboard == true ? "Search all chats" : "Filter chats")
        .task(id: chats.searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            await chats.runSearch()
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem { Button { chats.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }.help("New Chat (⌘N)") }
        }
        .refreshable { await chats.reload() }
        // Server-side delete has no undo, so confirm (Messages does the same).
        .confirmationDialog("Delete “\(deleting?.title ?? "this chat")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { chats.delete(d) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the conversation from Hermes for good. Archive keeps it out of the way instead.") }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let r = renaming { chats.rename(r, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder private func menu(for s: HermesSession) -> some View {
        Button("Rename…") { newTitle = s.title ?? ""; renaming = s }
        Button(s.pinned == true ? "Unpin" : "Pin") { chats.togglePin(s) }
        Button("Duplicate") { chats.fork(s) }
        Divider()
        Button("Archive") { chats.archive(s) }
        Button("Delete…", role: .destructive) { deleting = s }
    }

    private var groups: [(title: String, items: [HermesSession])] {
        let q = chats.searchText.lowercased()
        let all = chats.sessions.filter { $0.archived != true && (q.isEmpty || $0.displayTitle.lowercased().contains(q)) }
        let cal = Calendar.current
        var buckets: [(String, [HermesSession])] = [("Pinned", []), ("Today", []), ("Yesterday", []), ("Previous 7 Days", []), ("Earlier", [])]
        for s in all {
            let d = s.activityDate
            let i = s.pinned == true ? 0 : cal.isDateInToday(d) ? 1 : cal.isDateInYesterday(d) ? 2
                : d > .now.addingTimeInterval(-7 * 86400) ? 3 : 4
            buckets[i].1.append(s)
        }
        return buckets.filter { !$0.1.isEmpty }.map { ($0.0, $0.1) }
    }
}

struct SessionRow: View {
    var session: HermesSession
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.activityDate.relative).font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if let src = session.source, src != "api_server", src != "desktop" { Pill(text: src) }
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
    private var detail: String {
        if let p = session.preview, !p.isEmpty, p != session.title { return p }
        let n = session.messageCount ?? 0
        return n == 0 ? "Empty" : "\(n) message\(n == 1 ? "" : "s")"
    }
}

// MARK: - Conversation (detail column)

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var followTail = true
    private var chats: ChatStore { model.chats }

    var body: some View {
        VStack(spacing: 0) {
            if let err = chats.messagesError, chats.entries.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load this chat", message: err)
                    Button("Try Again") { chats.retryMessages() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chats.entries.isEmpty && !chats.loadingMessages {
                Greeting()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(chats.entries) { e in EntryView(entry: e).id(e.id) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: Theme.readingWidth)
                        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollContentBackground(.hidden)
                    // Follow streaming text only while the reader is at the bottom; scrolling up to read
                    // earlier text must not be yanked back on every delta (hermes-mac-kiu).
                    .onScrollGeometryChange(for: Bool.self) { g in
                        g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                    } action: { _, atBottom in followTail = atBottom }
                    .onChange(of: chats.entries.last?.text) { if followTail { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: chats.entries.count) { followTail = true; withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Composer()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(chats.selectedSession?.displayTitle ?? "New Chat")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.voice.start() } label: { Label("Voice", systemImage: "waveform") }
                    .help("Voice mode (⌥⌘V)")
            }
        }
    }

    private var subtitle: String {
        guard let s = chats.selectedSession else { return "" }
        return [s.model, s.messageCount.map { "\($0) messages" }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct Greeting: View {
    @Environment(AppModel.self) private var model
    private let ideas = [
        ("sun.horizon", "Plan my day", "Look at my calendar and tasks and plan my day."),
        ("magnifyingglass", "Research something", "Research the best options for "),
        ("clock.arrow.circlepath", "Schedule a job", "Every weekday at 8am, send me a short briefing of "),
        ("sparkles", "Teach a skill", "Create a new skill that "),
    ]
    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            HermesMark(size: 56)
            Text(greeting).font(.system(size: 30, weight: .semibold, design: .default))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)], spacing: 12) {
                ForEach(ideas, id: \.1) { idea in
                    Button { model.chats.draft = idea.2 } label: {
                        HStack(spacing: 10) {
                            Image(systemName: idea.0).font(.body).foregroundStyle(Theme.accent).frame(width: 22)
                            Text(idea.1).font(.callout.weight(.medium))
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 580)
            Spacer()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? "Good morning." : h < 18 ? "Good afternoon." : "Good evening."
    }
}

struct EntryView: View {
    @Environment(AppModel.self) private var model
    var entry: ChatEntry
    @ViewState private var showThinking = false

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accentSoft))
            }
        default:
            VStack(alignment: .leading, spacing: 12) {
                if !entry.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(entry.thinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Label(entry.streaming && entry.text.isEmpty ? "Thinking…" : "Thought process", systemImage: "brain")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .disclosureGroupStyle(QuietDisclosure())
                }
                if !entry.tools.isEmpty { ToolChips(tools: entry.tools) }
                if let a = entry.approval { ApprovalCard(request: a, busy: entry.answeringApproval) { model.chats.answer(a, $0, entry: entry.id) } }
                if !entry.text.isEmpty { MarkdownView(text: entry.text) }
                else if entry.streaming && entry.thinking.isEmpty && entry.tools.isEmpty { TypingIndicator() }
                if let err = entry.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QuietDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.25)) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 5) {
                    configuration.label
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct ToolChips: View {
    var tools: [ToolActivity]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tools) { t in
                HStack(spacing: 6) {
                    switch t.state {
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                    Text(t.name.replacingOccurrences(of: "_", with: " ")).font(.caption.weight(.medium))
                    if let p = t.preview, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(t.name.replacingOccurrences(of: "_", with: " ")), \(t.state == .running ? "running" : t.state == .done ? "done" : "failed")")
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
                .help(t.preview ?? t.name)
            }
        }
    }
}

struct ApprovalCard: View {
    var request: ApprovalRequest
    var busy = false
    var choose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hermes wants to run a command", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            if let d = request.description { Text(d).font(.callout) }
            if let c = request.command {
                Text(c).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.06)))
            }
            HStack {
                if request.choices.contains("deny") { Button("Deny", role: .destructive) { choose("deny") } }
                Spacer()
                if request.choices.contains("always") { Button("Always Allow") { choose("always") } }
                if request.choices.contains("session") { Button("Allow for Chat") { choose("session") } }
                // AIDEV-NOTE: security; no keyboard shortcut on approval buttons. Return sends in the composer and must
                // never approve an agent command (security review 2026-11-21).
                if request.choices.contains("once") { Button("Allow Once") { choose("once") }.buttonStyle(.borderedProminent) }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy) // one answer in flight at a time
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(.orange.opacity(0.35)))
    }
}

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 4 - Double(i) * 0.7)))
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Hermes is typing")
    }
}

// MARK: - Composer

struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chats = model.chats
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Hermes", text: $chats.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send) // Return sends; ⌥Return inserts a newline (native vertical TextField behavior)
                .padding(.vertical, 6)
            if chats.isStreaming {
                Button(action: chats.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain).help("Stop (⌘.)").accessibilityLabel("Stop responding")
            } else if chats.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { model.voice.start() } label: {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).help("Voice mode (⌥⌘V)").accessibilityLabel("Start voice mode")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).help("Send").accessibilityLabel("Send message")
            }
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: Theme.readingWidth + 40)
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6)
        .disabled(model.client == nil)
        .onAppear { focused = true }
        .onChange(of: chats.selection) { focused = true }
    }

    private func send() { model.chats.send(model.chats.draft) }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, w), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
