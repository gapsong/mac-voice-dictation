import AppKit
import DictationCore

/// The single set of user-facing settings mutations, shared by every UI surface
/// (the menu-bar menu and the status/settings window) so the two never drift or
/// duplicate the underlying calls into `DictationController`, `HotkeyMonitor`,
/// `Permissions`, and `LaunchAtLogin`.
@MainActor
final class DictationActions {

    let controller: DictationController
    private let hotkeyMonitor: HotkeyMonitor

    init(controller: DictationController, hotkeyMonitor: HotkeyMonitor) {
        self.controller = controller
        self.hotkeyMonitor = hotkeyMonitor
    }

    // MARK: - Permissions

    /// Requests Microphone; if denied, opens the System Settings pane so the
    /// user can flip it manually.
    func grantMicrophone() {
        Permissions.requestMicrophone { granted in
            if !granted { Permissions.openMicrophoneSettings() }
        }
    }

    /// Prompts for Accessibility and opens its System Settings pane (it must be
    /// granted out-of-band).
    func grantAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    func openKeyboardSettings() {
        Permissions.openKeyboardSettings()
    }

    // MARK: - Config mutations

    func setLanguage(_ language: WhisperLanguage) {
        controller.updateConfig { $0.language = language }
    }

    /// Changes the hold-to-talk hotkey and re-points the live event tap at it.
    func setHotkey(_ hotkey: HotkeyConfig) {
        controller.updateConfig { $0.hotkey = hotkey }
        hotkeyMonitor.update(hotkey: hotkey)
    }

    func setServerURL(_ urlString: String) {
        let value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        controller.updateConfig { $0.serverBaseURLString = value }
    }

    /// Toggles launch-at-login, persisting the OS-confirmed result.
    func toggleLaunchAtLogin() {
        let desired = !controller.config.launchAtLogin
        let ok = LaunchAtLogin.set(desired)
        controller.updateConfig { $0.launchAtLogin = ok ? desired : LaunchAtLogin.isEnabled }
    }

    // MARK: - Server

    func checkServer() async -> String {
        await controller.checkServer()
    }
}
