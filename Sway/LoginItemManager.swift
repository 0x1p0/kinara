import Foundation
import Combine
import ServiceManagement

final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var statusMessage = "Launch at login is off."
    @Published private(set) var lastError: String?

    private init() { refreshStatus() }

    func refreshStatus() {
        status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            statusMessage = "Kinara opens when you log in."
        case .requiresApproval:
            statusMessage = "Allow Kinara in System Settings → General → Login Items."
        case .notFound:
            statusMessage = "Move Kinara to Applications, then enable launch at login."
        case .notRegistered:
            statusMessage = "Launch at login is off."
        @unknown default:
            statusMessage = "macOS could not determine the login item status."
        }
    }

    func currentStatus() -> Bool {
        refreshStatus()
        return status == .enabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled,
                   SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled
                        || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refreshStatus()
        if let lastError { statusMessage = lastError }
        return lastError == nil && (enabled ? status == .enabled : status == .notRegistered)
    }
}
