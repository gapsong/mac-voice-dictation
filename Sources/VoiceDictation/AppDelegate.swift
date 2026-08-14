import AppKit
import DictationCore

/// Wires the app together at launch: config, controller, global hotkey, the
/// menu-bar status item, the on-screen overlay, and the status/settings window.
/// Also drives first-run permission requests and re-arms the event tap once
/// Accessibility is granted.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: DictationController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var actions: DictationActions!
    private var statusItemController: StatusItemController!
    private var overlay: OverlayController!
    private var settingsWindow: SettingsWindowController!
    private var accessibilityPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UserDefaultsConfigStore()
        controller = DictationController(store: store)

        hotkeyMonitor = HotkeyMonitor(hotkeys: controller.config.hotkeys)
        hotkeyMonitor.onPressStart = { [weak self] in
            self?.controller.beginRecording()
        }
        hotkeyMonitor.onPressEnd = { [weak self] committed in
            self?.controller.endRecording(committed: committed)
        }

        actions = DictationActions(controller: controller, hotkeyMonitor: hotkeyMonitor)

        // On-screen HUD: presence and recording feedback that never depends on
        // the (notch-hideable) menu-bar icon.
        overlay = OverlayController()
        controller.observeStatus { [weak self] status in
            self?.overlay.apply(status: status)
        }

        settingsWindow = SettingsWindowController(
            controller: controller,
            actions: actions,
            onClose: { [weak self] in self?.returnToAccessory() }
        )

        statusItemController = StatusItemController(
            controller: controller,
            actions: actions,
            openSettings: { [weak self] in self?.showSettingsWindow() }
        )

        // Keep the persisted launch-at-login preference in sync with the OS.
        _ = LaunchAtLogin.set(controller.config.launchAtLogin)

        requestPermissionsAndArm()
        surfacePresenceOnFirstLaunch()
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

    /// First-launch presence: if a permission is missing, open the status window
    /// to guide the user; otherwise flash a brief non-intrusive greeting overlay
    /// so the user knows the (icon-only) app actually started.
    private func surfacePresenceOnFirstLaunch() {
        if !Permissions.hasMicrophone || !Permissions.hasAccessibility {
            showSettingsWindow()
        } else {
            overlay.showBanner("Voice Dictation is running - hold fn to dictate", duration: 2.0)
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

    // MARK: - Status/settings window

    /// The dependable entry point when the menu-bar icon is hidden. Briefly
    /// becomes a `.regular` app so the window can come to the front, then drops
    /// back to `.accessory` when it closes (no permanent Dock icon).
    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.show()
    }

    private func returnToAccessory() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Re-launching the app (or clicking it in the Dock/Finder) while it is
    /// already running opens the status window - the "click the app again to get
    /// its window" behaviour that makes the app reachable past the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }
}
