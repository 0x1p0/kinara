import AppKit
import Sparkle

/// Load the actual packaged framework with the shipped updater configuration.
/// Never calls a check/install method, pumps the run loop, or starts Sway.
@main
struct UpdaterSmoke {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        try controller.updater.start()
        guard controller.updater.canCheckForUpdates,
              !controller.updater.automaticallyChecksForUpdates,
              !controller.updater.automaticallyDownloadsUpdates,
              controller.updater.feedURL?.absoluteString == "https://github.com/0x1p0/kinara/releases/latest/download/appcast.xml",
              Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int == 0 else {
            fatalError("Packaged updater configuration or first-action readiness failed")
        }
        print("Packaged Sparkle started successfully: immediately ready for manual checks, automatic checks/downloads off, signed feed and pre-extraction verification required. No check or installation requested.")
    }
}
