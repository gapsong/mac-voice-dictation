import AppKit
import DictationCore

/// Wires the app together at launch: config, controller, global hotkey, and the
/// menu-bar status item. Also drives first-run permission requests and re-arms
/// the event tap once Accessibility is granted.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: DictationController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var statusItemController: StatusItemController!
    private var accessibilityPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UserDefaultsConfigStore()
        controller = DictationController(store: store)

        hotkeyMonitor = HotkeyMonitor(hotkey: controller.config.hotkey)
        hotkeyMonitor.onPressStart = { [weak self] in
            self?.controller.beginRecording()
        }
        hotkeyMonitor.onPressEnd = { [weak self] committed in
            self?.controller.endRecording(committed: committed)
        }

        statusItemController = StatusItemController(
            controller: controller,
            hotkeyMonitor: hotkeyMonitor
        )

        // Keep the persisted launch-at-login preference in sync with the OS.
        _ = LaunchAtLogin.set(controller.config.launchAtLogin)

        requestPermissionsAndArm()
    }

    /// Requests Microphone up front and arms the hotkey tap. Because the tap
    /// needs Accessibility (which the user grants out-of-band in System
    /// Settings), we poll until it is granted and then start the tap.
    private func requestPermissionsAndArm() {
        Permissions.requestMicrophone { _ in }

        if !armHotkey() {
            controller.beginNeedsAccessibility()
            Permissions.promptAccessibility()
            startAccessibilityPolling()
        }
    }

    @discardableResult
    private func armHotkey() -> Bool {
        guard Permissions.hasAccessibility else { return false }
        return hotkeyMonitor.start()
    }

    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                if self.armHotkey() {
                    timer.invalidate()
                    self.accessibilityPollTimer = nil
                    self.controller.clearError()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }
}
