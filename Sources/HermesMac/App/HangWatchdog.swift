import AppKit
import os

private let wdLog = Logger(subsystem: "net.jmaddington.hermes", category: "watchdog")

/// Catches freezes on machines we can't watch: when the main thread stops answering, or spins at full CPU (a SwiftUI
/// update loop keeps answering pings but still locks the UI), it runs /usr/bin/sample on this process once and saves
/// the report in ~/Library/Logs/Alaria. The next launch offers to show it. Nothing leaves the Mac.
// AIDEV-NOTE: sampling yourself works under the hardened runtime without entitlements (tested 2026-11-25).
// Watches only the MAIN thread's CPU so voice mode's audio threads can't trip it.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Alaria")
    }

    private let pingTimeout: TimeInterval = 4   // main thread silent this long = hung
    private let busyFraction = 0.85             // main thread CPU share counted as spinning
    private let busyLimit: TimeInterval = 30    // spinning this long = stuck in a loop
    private let maxSamples = 2                  // per launch
    private var mainPort: mach_port_t = 0
    private var started = false

    /// Call on the main thread (it records the main thread's port).
    func start() {
        guard !started, Thread.isMainThread, Bundle.main.bundleURL.pathExtension == "app" else { return }
        started = true
        mainPort = mach_thread_self()
        prune()
        let t = Thread { [self] in loop() }
        t.name = "alaria.watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    private func loop() {
        var samples = 0, busy: TimeInterval = 0
        var lastWall = ProcessInfo.processInfo.systemUptime, lastCPU = mainCPU()
        while samples < maxSamples {
            Thread.sleep(forTimeInterval: 5)
            let ping = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { ping.signal() }
            let hung = ping.wait(timeout: .now() + pingTimeout) == .timedOut

            let wall = ProcessInfo.processInfo.systemUptime, cpu = mainCPU()
            let share = (cpu - lastCPU) / max(wall - lastWall, 0.001)
            lastWall = wall; lastCPU = cpu
            busy = share >= busyFraction ? busy + 5 + (hung ? pingTimeout : 0) : 0

            guard hung || busy >= busyLimit else { continue }
            let reason = hung ? "hang" : "spin"
            wdLog.error("main thread \(reason, privacy: .public) (cpu share \(share, format: .fixed(precision: 2))); sampling [ALR-WD-DETECT]")
            sample(reason)
            samples += 1; busy = 0
            if hung { ping.wait() } // one report per freeze: wait until main answers again
            lastWall = ProcessInfo.processInfo.systemUptime; lastCPU = mainCPU()
        }
    }

    /// Seconds of CPU the main thread has used.
    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let u = info.user_time, s = info.system_time
        return Double(u.seconds + s.seconds) + Double(u.microseconds + s.microseconds) / 1_000_000
    }

    private func sample(_ reason: String) {
        let fm = FileManager.default
        do { try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true) }
        catch { wdLog.error("can't create log folder: \(error.localizedDescription, privacy: .public) [ALR-WD-DIR]"); return }
        let stamp = Self.stampFormatter.string(from: Date())
        let file = Self.folder.appendingPathComponent("Alaria-\(reason)-\(stamp).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "3", "-mayDie", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            wdLog.error("saved \(file.lastPathComponent, privacy: .public), sample exit \(p.terminationStatus) [ALR-WD-SAVED]")
        } catch {
            wdLog.error("sample failed: \(error.localizedDescription, privacy: .public) [ALR-WD-SAMPLE-ERR]")
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
    }()

    /// Keeps the newest 10 reports.
    private func prune() {
        let old = reports().dropFirst(10)
        for u in old { try? FileManager.default.removeItem(at: u) }
    }

    /// Saved reports, newest first.
    func reports() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        return all.filter { $0.lastPathComponent.hasPrefix("Alaria-") }.sorted { date($0) > date($1) }
    }

    /// On launch: if a report appeared since the last one we told the user about, offer to show it.
    @MainActor func offerNewReports() {
        let key = "watchdogLastShownReport"
        guard let newest = reports().first, UserDefaults.standard.string(forKey: key) != newest.lastPathComponent else { return }
        UserDefaults.standard.set(newest.lastPathComponent, forKey: key)
        let a = NSAlert()
        a.messageText = "Alaria got stuck last time"
        a.informativeText = "It saved a diagnostic report (\(newest.lastPathComponent)). It lists only where the app's code was busy, not your chats. Send it to whoever is fixing Alaria."
        a.addButton(withTitle: "Show in Finder")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([newest]) }
    }

    /// Debug hook: HERMES_WATCHDOG_TEST=hang|spin blocks or spins the main thread once, 3 s after launch.
    @MainActor func runSelfTestIfAsked() {
        guard let mode = ProcessInfo.processInfo.environment["HERMES_WATCHDOG_TEST"], ["hang", "spin"].contains(mode) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            wdLog.notice("self-test \(mode, privacy: .public) [ALR-WD-TEST]")
            if mode == "hang" { Thread.sleep(forTimeInterval: 30); return }
            // spin: stay busy but keep answering pings, like a SwiftUI update loop
            let end = Date().addingTimeInterval(45)
            func step() {
                let t = Date().addingTimeInterval(0.2); while Date() < t {}
                if Date() < end { DispatchQueue.main.async { step() } }
            }
            step()
        }
    }
}
