import Foundation
import ServiceManagement

/// Wraps the system Login Item registration for the app (macOS 13+ SMAppService).
/// Registering adds Whisp to System Settings → General → Login Items, so it
/// opens automatically at login. The user can also toggle it there.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off. Returns false (and logs) on failure.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Whisp login item \(on ? "register" : "unregister") failed: \(error)")
            return false
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "notRegistered"
        case .requiresApproval: return "requiresApproval (approve in System Settings → Login Items)"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown"
        }
    }
}
