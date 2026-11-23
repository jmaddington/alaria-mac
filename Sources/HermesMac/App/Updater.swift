import AppKit
import Observation
import Sparkle

/// Sparkle auto-update (hermes-mac-d3k). The feed is `appcast.xml` attached to the latest GitHub Release
/// (SUFeedURL in Info.plist, written by scripts/make-appcast.sh); updates must verify against SUPublicEDKey.
// AIDEV-NOTE: only starts inside a real .app with a feed; `swift run HermesMac` has no bundle and Sparkle would error.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private(set) var isRunning = false
    private(set) var canCheck = false
    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    var automaticallyInstalls = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    static var isUpdatableBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard controller == nil, Self.isUpdatableBundle else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        isRunning = true
        automaticallyChecks = c.updater.automaticallyChecksForUpdates
        automaticallyInstalls = c.updater.automaticallyDownloadsUpdates
        canCheck = c.updater.canCheckForUpdates
        canCheckObservation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in Updater.shared.canCheck = value }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
