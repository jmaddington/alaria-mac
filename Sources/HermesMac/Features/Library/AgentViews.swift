import Charts
import HermesKit
import SwiftUI

// MARK: - Tools

struct ToolsList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var lib = model.library
        Group {
            if model.client?.hasDashboard != true { NeedsDashboard(feature: "Tools") }
            else {
                List(selection: $lib.toolSelection) {
                    ForEach(lib.toolsets) { t in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(t.label ?? t.name).font(.body.weight(.medium))
                                    // AIDEV-NOTE: the server reports available == enabled for every toolset (checked 2026-11-22),
                                    // so there is no host-availability signal to show; only on/off (hermes-mac-eqx).
                                }
                                Text(t.description ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    .help(t.description ?? "")
                            }
                            Spacer()
                            Toggle(t.label ?? t.name, isOn: Binding(get: { t.enabled ?? false }, set: { v in
                                guard let c = model.client else { return }
                                model.run("Toolset") { try await c.setToolset(t.name, enabled: v); await lib.loadToolsets() }
                            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        .opacity(t.enabled == false ? 0.6 : 1)
                        .hoverRow().tag(Optional(t.name))
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .task { await lib.loadToolsets() }
            }
        }
        .navigationTitle("Tools")
    }
}

struct ToolDetail: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.library.toolsets.first(where: { $0.name == model.library.toolSelection }) {
            Form {
                SwiftUI.Section {
                    LabeledContent("Toolset") { Text(t.name).textSelection(.enabled) }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            StatusDot(color: t.enabled == true ? .green : .secondary)
                            Text(t.enabled == true ? "Enabled" : "Disabled")
                        }
                    }
                    if t.configured == false { Label("Needs setup on the Hermes host", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if t.available == false { Label("Not available on this host", systemImage: "nosign").foregroundStyle(.secondary) }
                } footer: { Text(t.description ?? "") }
                SwiftUI.Section({ let n = t.tools?.count ?? 0; return "\(n) tool\(n == 1 ? "" : "s")" }()) {
                    ForEach(t.tools ?? [], id: \.self) { name in
                        Label(name, systemImage: "function").font(.system(.body, design: .monospaced))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(t.label ?? t.name)
        } else {
            EmptyState(symbol: "wrench.and.screwdriver", title: "Select a toolset", message: "Toolsets are groups of tools Hermes can use. Turn them on or off from the list.")
        }
    }
}

// MARK: - Memory

struct MemoryList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var lib = model.library
        Group {
            if model.client?.hasDashboard != true { NeedsDashboard(feature: "Memory") }
            else {
                List(selection: $lib.memorySelection) {
                    SwiftUI.Section("Built-in") {
                        Label("Memory & Profile", systemImage: "brain.head.profile").hoverRow().tag(Optional("builtin"))
                    }
                    SwiftUI.Section("Providers") {
                        ForEach(lib.memory?.providers ?? []) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.providerName(p.name)).help(p.description ?? "")
                                    if p.available == false && lib.memory?.active != p.name {
                                        // Say why, not just "Unavailable" (hermes-mac-jhg).
                                        Text(Self.providerStatus(p.status))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                if lib.memory?.active == p.name { Pill(text: "Active", color: .green) }
                                else if p.available == false {
                                    Pill(text: "Unavailable").help(p.status ?? "Not installed or not configured on the Hermes host")
                                }
                            }
                            .hoverRow().tag(Optional(p.name))
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .task { await lib.loadMemory() }
                .onChange(of: lib.memorySelection, initial: true) { if lib.memorySelection == nil { lib.memorySelection = "builtin" } } // detail always matches a selected row
            }
        }
        .navigationTitle("Memory")
    }
    /// Server status codes -> sentences.
    static func providerStatus(_ code: String?) -> String {
        switch code {
        case "needs_config": "Needs setup on the Hermes host"
        case "unavailable", nil: "Not installed on the Hermes host"
        case let c?: c.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Provider ids are lowercase slugs; known ones get their real names (hermes-mac-jhg).
    static func providerName(_ id: String) -> String {
        let known = ["retaindb": "RetainDB", "byterover": "ByteRover", "mem0": "Mem0", "honcho": "Honcho",
                     "zep": "Zep", "letta": "Letta", "supermemory": "Supermemory"]
        return known[id.lowercased()] ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

}

struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirm: String?
    private var forgetTitle: String {
        switch confirm { case "memory": "Forget everything Hermes has remembered?"; case "user": "Forget your profile?"; default: "Forget all memories and your profile?" }
    }
    private var forgetButton: String {
        switch confirm { case "memory": "Forget Memories"; case "user": "Forget Profile"; default: "Forget Everything" }
    }

    var body: some View {
        let lib = model.library
        Group {
            if lib.memorySelection == "builtin" || lib.memorySelection == nil {
                Form {
                    SwiftUI.Section {
                        LabeledContent("Active provider") { Text(lib.memory?.active.flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "Built-in only") }
                        ForEach((lib.memory?.builtinFiles ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            LabeledContent(k == "user" ? "Profile entries" : "Memory entries") { Text("\(v)").monospacedDigit() }
                        }
                    } footer: { Text("Hermes keeps what it learns about you and your work in its memory. It grows on its own as you talk.") }
                    SwiftUI.Section {
                        Button("Forget Memories…", role: .destructive) { confirm = "memory" }
                        Button("Forget Profile…", role: .destructive) { confirm = "user" }
                        Button("Forget Everything…", role: .destructive) { confirm = "all" }
                    }
                }
                .formStyle(.grouped)
            } else if let p = lib.memory?.providers?.first(where: { $0.name == lib.memorySelection }) {
                Form {
                    SwiftUI.Section {
                        LabeledContent("Status") { Text(p.status?.capitalized ?? "—") }
                        LabeledContent("Configured") { Text(p.configured == true ? "Yes" : "No") }
                    } footer: { Text(p.description ?? "") }
                    SwiftUI.Section {
                        Button(lib.memory?.active == p.name ? "In Use" : "Use \(p.name.capitalized)") {
                            guard let c = model.client else { return }
                            model.run("Memory provider") { try await c.setMemoryProvider(p.name); await lib.loadMemory() }
                        }
                        .disabled(lib.memory?.active == p.name || p.available == false)
                    }
                }
                .formStyle(.grouped)
            } else { Color.clear }
        }
        .navigationTitle("Memory")
        // Name the scope being erased (hermes-mac-2cc).
        .confirmationDialog(forgetTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button(forgetButton, role: .destructive) {
                guard let t = confirm, let c = model.client else { return }
                model.run("Reset memory") { try await c.resetMemory(t); await lib.loadMemory(); model.flash("Done") }
            }
        } message: { Text("This can't be undone.") }
    }
}

// MARK: - Usage

struct UsagePeriods: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var lib = model.library
        Group {
            if model.client?.hasDashboard != true { NeedsDashboard(feature: "Usage") }
            else {
                List(selection: Binding(get: { Optional(lib.usageDays) }, set: { lib.usageDays = $0 ?? 7 })) {
                    ForEach([(7, "Last 7 Days"), (30, "Last 30 Days"), (90, "Last 90 Days"), (365, "Last Year")], id: \.0) { d, t in
                        Label(t, systemImage: "calendar").hoverRow().tag(Optional(d))
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Usage")
    }
}

struct UsageDetail: View {
    @Environment(AppModel.self) private var model
    @ViewState private var report: UsageReport?
    @ViewState private var usageError: String?
    private var periodStart: Date {
        Calendar.current.startOfDay(for: .now.addingTimeInterval(-Double(model.library.usageDays - 1) * 86_400))
    }
    static func dayDate(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s) ?? .now
    }
    var body: some View {
        Group {
            if model.client?.hasDashboard != true { Color.clear }
            else if let r = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Four across when there's room, otherwise 2x2 (labels were truncating at 940 pt) (hermes-mac-bax).
                        let tiles = [("Input tokens", (r.totals?.totalInput ?? 0).compact),
                                     ("Output tokens", (r.totals?.totalOutput ?? 0).compact),
                                     ("Reasoning", (r.totals?.totalReasoning ?? 0).compact),
                                     ("Est. cost", (r.totals?.totalEstimatedCost ?? 0).formatted(.currency(code: "USD")))]
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) { ForEach(tiles, id: \.0) { Stat(title: $0.0, value: $0.1).frame(minWidth: 150) } }
                            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                                GridRow { Stat(title: tiles[0].0, value: tiles[0].1); Stat(title: tiles[1].0, value: tiles[1].1) }
                                GridRow { Stat(title: tiles[2].0, value: tiles[2].1); Stat(title: tiles[3].0, value: tiles[3].1) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tokens per day").font(.headline)
                            // Real time axis over the whole period, so one active day is one slim bar, not the full width.
                            Chart(r.daily ?? []) { d in
                                let day = Self.dayDate(d.day)
                                BarMark(x: .value("Day", day, unit: .day), y: .value("Tokens", d.inputTokens ?? 0))
                                    .foregroundStyle(by: .value("Kind", "Input"))
                                BarMark(x: .value("Day", day, unit: .day), y: .value("Tokens", d.outputTokens ?? 0))
                                    .foregroundStyle(by: .value("Kind", "Output"))
                            }
                            .chartXScale(domain: periodStart...Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)))
                            .chartForegroundStyleScale(["Input": Theme.accent.opacity(0.55), "Output": Theme.accent])
                            .frame(height: 220)
                            .overlay { if (r.daily ?? []).isEmpty { Text("No activity in this period").foregroundStyle(.secondary) } }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("By model").font(.headline)
                            ForEach(r.byModel ?? []) { m in
                                HStack {
                                    Text(m.model).font(.body.weight(.medium))
                                    Spacer()
                                    Text("\((m.inputTokens ?? 0).compact) in · \((m.outputTokens ?? 0).compact) out · \(m.sessions ?? 0) \((m.sessions ?? 0) == 1 ? "chat" : "chats")")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            } else if let usageError {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load usage", message: usageError)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle("Usage")
        .task(id: model.library.usageDays) {
            guard let c = model.client, c.hasDashboard else { return }
            report = nil // never label 30 days over 7-day numbers while loading (hermes-mac-3r6)
            usageError = nil
            do { report = try await c.usage(days: model.library.usageDays) }
            catch { if !error.isCancellation { usageError = error.localizedDescription } }
        }
    }
}

struct Stat: View {
    var title: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Never wrap mid-number at narrow widths; shrink instead (hermes-mac-bax).
            Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(.quaternary.opacity(0.45)))
    }
}

// MARK: - Logs

struct LogFiles: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var lib = model.library
        Group {
            if model.client?.hasDashboard != true { NeedsDashboard(feature: "Logs") }
            else {
                List(selection: Binding(get: { Optional(lib.logFile) }, set: { lib.logFile = $0 ?? "agent" })) {
                    ForEach([("agent", "Agent", "cpu"), ("errors", "Errors", "exclamationmark.octagon"), ("gateway", "Gateway", "network")], id: \.0) { f, t, s in
                        Label(t, systemImage: s).hoverRow().tag(Optional(f))
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Logs")
    }
}

struct LogDetail: View {
    @Environment(AppModel.self) private var model
    @ViewState private var lines: [String] = []
    @ViewState private var filter = ""
    @ViewState private var live = true
    var body: some View {
        Group {
            if model.client?.hasDashboard != true { Color.clear }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(l.contains(" ERROR ") ? .red : l.contains(" WARNING ") ? .orange : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(16)
                    }
                    // Key on the content, not the count: at the 400-line window the count never changes (hermes-mac-fet).
                    .onChange(of: lines) { if live, !shown.isEmpty { proxy.scrollTo(shown.count - 1, anchor: .bottom) } }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    if !filter.isEmpty && shown.isEmpty && !lines.isEmpty {
                        EmptyState(symbol: "line.3.horizontal.decrease", title: "No matching lines",
                                       message: "Nothing in the last \(lines.count) lines matches “\(filter)”.", action: ("Clear Filter", { filter = "" }))
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .searchable(text: $filter, prompt: "Filter")
        .toolbar { ToolbarItem { Toggle(isOn: $live) { Label("Follow", systemImage: "arrow.down.to.line") }.help("Follow new lines") } }
        .task(id: model.library.logFile) {
            guard let c = model.client, c.hasDashboard else { return }
            lines = [] // never show the previous file's lines under the new file's name
            var failed = false
            while !Task.isCancelled {
                if live {
                    do { lines = try await c.logs(file: model.library.logFile, lines: 400); failed = false }
                    catch {
                        if Task.isCancelled { return }
                        if !failed { model.flash("Couldn't read logs: \(error.localizedDescription)") } // once, not every 3 s
                        failed = true
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private var shown: [String] { filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) } }
}
