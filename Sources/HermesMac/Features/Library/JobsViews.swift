import HermesKit
import SwiftUI

struct JobsList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var lib = model.library
        List(selection: $lib.jobSelection) {
            ForEach(lib.jobs) { j in JobRow(job: j).hoverRow().tag(Optional(j.id)) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if lib.jobs.isEmpty && !lib.jobsLoading {
                EmptyState(symbol: "clock.badge.checkmark", title: "Nothing scheduled",
                           message: "Scheduled jobs run a prompt for you on a timetable: a morning briefing, a weekly report.",
                           action: ("New Job", { lib.jobSelection = nil; lib.creatingJob = true }))
            }
        }
        .navigationTitle("Scheduled")
        .toolbar { ToolbarItem { Button { lib.jobSelection = nil; lib.creatingJob = true } label: { Label("New Job", systemImage: "plus") } } }
        .refreshable { await lib.loadJobs() }
        .task { await lib.loadJobs() }
        .onChange(of: lib.jobSelection) { if lib.jobSelection != nil { lib.creatingJob = false } }
    }
}

struct JobRow: View {
    var job: CronJob
    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name ?? "Untitled job").font(.body.weight(.medium)).lineLimit(1)
                Text(job.scheduleText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(trailing).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
    private var color: Color {
        if job.isPaused { return .secondary }
        if job.lastStatus == "error" || job.lastStatus == "failed" || (job.failureStreak ?? 0) > 0 { return .red }
        return .green
    }
    private var trailing: String {
        if job.isPaused { return "Paused" }
        return parseISO(job.nextRunAt)?.relative ?? ""
    }
}

struct JobDetail: View {
    @Environment(AppModel.self) private var model
    @ViewState private var draft = HermesClient.JobDraft()
    @ViewState private var loadedID: String?
    @ViewState private var runs: [CronRun] = []
    @ViewState private var saving = false
    @ViewState private var confirmDelete = false
    @ViewState private var skillPick = ""

    private var lib: LibraryStore { model.library }
    private var job: CronJob? { lib.jobs.first { $0.id == lib.jobSelection } }
    private var isNew: Bool { lib.creatingJob && job == nil }
    private var dirty: Bool { job.map { HermesClient.JobDraft($0) != draft } ?? !draft.name.isEmpty }

    var body: some View {
        Group {
            if job != nil || isNew { form }
            else {
                EmptyState(symbol: "clock", title: "Select a job",
                           message: "Choose a scheduled job to edit it, or create a new one.",
                           action: ("New Job", { lib.creatingJob = true }))
            }
        }
        .navigationTitle(isNew ? "New Job" : job?.name ?? "Scheduled")
        .onChange(of: job?.id, initial: true) { reset() }
        .onChange(of: lib.creatingJob) { if lib.creatingJob { draft = lib.jobDrafts["new"] ?? .init(); loadedID = nil } }
        .onChange(of: draft) { stash() }
        .confirmationDialog("Delete \(job?.name ?? "this job")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let j = job, let c = model.client else { return }
                model.run("Delete") { try await c.deleteJob(j.id); lib.jobSelection = nil; await lib.loadJobs() }
            }
        }
    }

    private var form: some View {
        Form {
            SwiftUI.Section {
                TextField("Name", text: $draft.name, prompt: Text("Morning briefing"))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Schedule", text: $draft.schedule, prompt: Text("weekdays at 9am"))
                    Text("Plain English or cron: “every 2h”, “every monday 9am”, “in 30m”, “0 9 * * *”, or an ISO date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let j = job, j.schedule?.expr != nil || j.schedule?.kind != nil {
                    LabeledContent("Runs") { Text([j.schedule?.kind, j.schedule?.expr].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary) }
                }
            }
            SwiftUI.Section("Prompt") {
                TextEditor(text: $draft.prompt) // capped so a long prompt scrolls inside instead of growing the form
                    .font(.body).frame(minHeight: 140, maxHeight: 320)
                    .scrollContentBackground(.hidden)
            }
            SwiftUI.Section("Options") {
                Picker("Deliver to", selection: $draft.deliver) {
                    ForEach(targets, id: \.id) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Skills") {
                    HStack {
                        FlowLayout(spacing: 5) {
                            ForEach(draft.skills, id: \.self) { s in
                                HStack(spacing: 3) {
                                    Text(s).font(.caption)
                                    Button { draft.skills.removeAll { $0 == s } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(s)")
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Theme.accentSoft))
                            }
                        }
                        Menu("Add") {
                            ForEach(lib.skills.filter { !draft.skills.contains($0.name) }) { s in Button(s.name) { draft.skills.append(s.name) } }
                        }.fixedSize().disabled(lib.skills.isEmpty)
                    }
                }
                Picker("Repeat", selection: Binding(get: { draft.repeatTimes ?? 0 }, set: { draft.repeatTimes = $0 == 0 ? nil : $0 })) {
                    Text("Forever").tag(0)
                    // Include the job's own count so an unusual value (e.g. 4) isn't a blank, invalid selection (hermes-mac-coe).
                    ForEach(Array(Set([1, 2, 3, 5, 10, 25] + [draft.repeatTimes ?? 1])).sorted(), id: \.self) {
                        Text("\($0) time\($0 == 1 ? "" : "s")").tag($0)
                    }
                }
                TextField("Time zone", text: Binding(get: { draft.timezone ?? "" }, set: { draft.timezone = $0 }), prompt: Text("Hermes default"))
            }
            if let j = job {
                SwiftUI.Section("Status") {
                    LabeledContent("State") { Text(j.isPaused ? "Paused" : "Scheduled").foregroundStyle(j.isPaused ? .secondary : .primary) }
                    if let r = j.pausedReason, j.isPaused { LabeledContent("Reason") { Text(r).foregroundStyle(.secondary) } }
                    LabeledContent("Next run") { Text(j.isPaused ? "Paused" : date(j.nextRunAt)) }
                    LabeledContent("Last run") { Text(date(j.lastRunAt)) }
                    if let s = j.lastStatus { LabeledContent("Last result") { Text(s.capitalized).foregroundStyle(s == "ok" || s == "success" ? .green : .orange) } }
                    if let e = j.lastError { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if let c = j.repeat?.completed, c > 0 { LabeledContent("Completed runs") { Text("\(c)") } }
                }
                if !runs.isEmpty {
                    SwiftUI.Section("History") {
                        ForEach(runs, id: \.stableID) { r in
                            HStack {
                                StatusDot(color: r.status == "ok" || r.status == "success" || r.status == "completed" ? .green : .orange)
                                Text(r.startedAt?.description ?? "—").font(.callout.monospacedDigit())
                                Spacer()
                                Text(r.status?.capitalized ?? "").foregroundStyle(.secondary)
                            }
                            .help(r.error ?? r.output ?? "")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            if let j = job {
                ToolbarItem { Button { act("Run") { try await $0.runJobNow(j.id) } } label: { Label("Run Now", systemImage: "play.fill") }.help("Run now") }
                ToolbarItem {
                    Button { act(j.isPaused ? "Resume" : "Pause") { j.isPaused ? try await $0.resumeJob(j.id) : try await $0.pauseJob(j.id) } } label: {
                        Label(j.isPaused ? "Resume" : "Pause", systemImage: j.isPaused ? "play.circle" : "pause.circle")
                    }.help(j.isPaused ? "Resume" : "Pause")
                }
                ToolbarItem { Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.help("Delete") }
            }
            ToolbarItem {
                Button("Revert") { draft = job.map { HermesClient.JobDraft($0) } ?? .init() }.disabled(!dirty)
            }
            ToolbarItem {
                Button(isNew ? "Create" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s")
                    .disabled(!dirty || saving || draft.name.isEmpty || draft.schedule.isEmpty)
            }
        }
        .task(id: job?.id) { await loadRuns() }
    }

    private var targets: [DeliveryTarget] {
        var t = lib.deliveryTargets.isEmpty ? [DeliveryTarget(id: "local", name: "Local (save only)")] : lib.deliveryTargets
        if !t.contains(where: { $0.id == draft.deliver }) { t.append(DeliveryTarget(id: draft.deliver, name: draft.deliver)) }
        return t
    }

    private func date(_ s: String?) -> String {
        guard let d = parseISO(s) else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened) + "  (" + d.relative + ")"
    }

    private func reset() {
        guard let j = job else { return }
        if loadedID != j.id { draft = lib.jobDrafts[j.id] ?? .init(j); loadedID = j.id; runs = [] }
    }

    /// Keep unsaved form edits per job across navigation (hermes-mac-fz5).
    private func stash() {
        let key = isNew ? "new" : loadedID
        guard let key else { return }
        lib.jobDrafts[key] = dirty ? draft : nil
    }

    private func loadRuns() async {
        guard let j = job, let c = model.client, c.hasDashboard else { return }
        do { runs = try await c.jobRuns(j.id) } catch { model.report("Couldn't load run history", error) }
    }

    private func act(_ what: String, _ f: @escaping (HermesClient) async throws -> CronJob) {
        guard let c = model.client else { return }
        model.run(what) { let j = try await f(c); lib.replace(j); if what == "Run" { model.flash("Started \(j.name ?? "job")") } }
    }

    private func save() async {
        guard let c = model.client else { return }
        saving = true; defer { saving = false }
        do {
            if let j = job {
                let u = try await c.updateJob(j.id, draft, from: HermesClient.JobDraft(j))
                lib.replace(u); lib.jobDrafts[j.id] = nil; draft = .init(u)
                model.flash("Saved")
            } else {
                let n = try await c.createJob(draft)
                lib.replace(n)
                lib.jobDrafts["new"] = nil
                lib.creatingJob = false
                lib.jobSelection = n.id
            }
        } catch { model.flash("Couldn't save: \(error.localizedDescription)") }
    }
}
