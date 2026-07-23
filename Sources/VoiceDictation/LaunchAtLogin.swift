import Foundation
import ServiceManagement
import os

/// Launch-at-login toggle backed by `SMAppService` (macOS 13+). The app
/// registers itself as a login item; no separate helper bundle is required.
enum LaunchAtLogin {

    private static let log = Logger(subsystem: "com.firstmate.VoiceDictation", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch at login. Returns whether the desired state
    /// was achieved; failures are logged (e.g. running an unbundled binary).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return isEnabled == enabled
        } catch {
            log.error("Failed to set launch-at-login=\(enabled): \(error.localizedDescription)")
            return false
        }
    }
}
