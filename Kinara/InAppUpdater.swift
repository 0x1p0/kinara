import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle owns download verification, atomic installation, and relaunch.
/// It starts only for a user-requested installation; daily metadata checks are
/// handled separately and never download executable code without an action.
final class InAppUpdater: ObservableObject {
    static let shared = InAppUpdater()
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    #endif

    var isConfigured: Bool {
        #if canImport(Sparkle)
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
        #else
        return false
        #endif
    }

    func installUpdate() {
        guard isConfigured else { error = "This build does not have signed in-app updates configured."; return }
        #if canImport(Sparkle)
        error = nil
        if controller == nil {
            let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            do { try updater.updater.start() }
            catch {
                self.error = "Couldn’t start the updater: \(error.localizedDescription)"
                return
            }
            controller = updater
            observation = updater.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.isBusy = !updater.canCheckForUpdates }
            }
        }
        guard let controller, controller.updater.canCheckForUpdates else { return }
        WindowFocusCoordinator.activateApplication()
        controller.checkForUpdates(nil)
        #endif
    }
}
