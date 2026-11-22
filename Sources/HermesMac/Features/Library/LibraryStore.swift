import Foundation
import HermesKit
import Observation

/// State shared between the content (list) and detail columns of the non-chat sections.
@MainActor @Observable
final class LibraryStore {
    weak var app: AppModel?
    var client: HermesClient? { app?.client }

    // Skills
    var skills: [Skill] = []
    var skillSelection: String?
    var skillsLoading = false
    var skillFilter = ""
    /// Unsaved editor text per skill / job (key "new" = the New Job form). Lives here, not in the views, so
    /// switching skill, job or section never throws edits away (hermes-mac-fz5). Cleared on Save/Revert.
    var skillDrafts: [String: String] = [:]
    var jobDrafts: [String: HermesClient.JobDraft] = [:]

    /// Forget everything from the previous server (connection settings changed).
    func reset() {
        skills = []; skillSelection = nil; skillDrafts = [:]
        jobs = []; jobSelection = nil; creatingJob = false; jobDrafts = [:]
        toolsets = []; toolSelection = nil; memory = nil
    }

    // Jobs
    var jobs: [CronJob] = []
    var jobSelection: String?
    var jobsLoading = false
    var creatingJob = false
    var deliveryTargets: [DeliveryTarget] = []

    // Tools
    var toolsets: [Toolset] = []
    var toolSelection: String?

    // Memory
    var memory: MemoryState?
    var memorySelection: String? = "builtin"

    // Usage / logs
    var usageDays = 7
    var logFile = "agent"

    func loadSkills() async {
        guard let client, client.hasDashboard else { return }
        skillsLoading = true; defer { skillsLoading = false }
        do { skills = try await client.skills().sorted { ($0.category ?? "~", $0.name) < ($1.category ?? "~", $1.name) } }
        catch { app?.flash("Couldn't load skills: \(error.localizedDescription)") }
    }

    func loadJobs() async {
        guard let client else { return }
        jobsLoading = true; defer { jobsLoading = false }
        do {
            jobs = try await client.jobs().sorted { ($0.name ?? "") < ($1.name ?? "") }
            if client.hasDashboard, deliveryTargets.isEmpty {
                do { deliveryTargets = try await client.deliveryTargets() }
                catch { app?.report("Couldn't load delivery targets", error) } // picker would silently show Local only
            }
        } catch { app?.flash("Couldn't load jobs: \(error.localizedDescription)") }
    }

    func replace(_ j: CronJob) {
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.append(j) }
    }

    func loadToolsets() async {
        guard let client, client.hasDashboard else { return }
        do { toolsets = try await client.toolsets() } catch { app?.flash("Couldn't load tools: \(error.localizedDescription)") }
    }

    func loadMemory() async {
        guard let client, client.hasDashboard else { return }
        do { memory = try await client.memory() } catch { app?.flash("Couldn't load memory: \(error.localizedDescription)") }
    }
}
