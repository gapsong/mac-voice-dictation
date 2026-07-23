import AppKit
import DictationCore

/// Owns the menu-bar `NSStatusItem`: its icon reflects `AppStatus`, and its menu
/// exposes every configurable setting plus permission guidance.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let hotkeyMonitor: HotkeyMonitor

    /// Latest health line from a "Check server" action, shown in the menu.
    private var lastServerLine: String?

    init(controller: DictationController, hotkeyMonitor: HotkeyMonitor) {
        self.controller = controller
        self.hotkeyMonitor = hotkeyMonitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        apply(status: controller.status)
        controller.onStatusChange = { [weak self] status in
            self?.apply(status: status)
        }
    }

    // MARK: - Icon

    private func apply(status: AppStatus) {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.menuText
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Voice Dictation - \(status.menuText)"
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status line.
        menu.addItem(disabledItem(controller.status.menuText))

        // Permission guidance, only when something is missing.
        addPermissionItems(to: menu)

        menu.addItem(.separator())

        // Server health check + last result.
        let check = NSMenuItem(title: "Check Server", action: #selector(checkServer), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        if let line = lastServerLine {
            menu.addItem(disabledItem(line))
        }
        let urlItem = NSMenuItem(title: "Set Server URL...", action: #selector(editServerURL), keyEquivalent: "")
        urlItem.target = self
        menu.addItem(urlItem)
        menu.addItem(disabledItem(controller.config.serverBaseURLString))

        menu.addItem(.separator())

        // Language submenu.
        menu.addItem(languageMenu())

        // Hotkey submenu.
        menu.addItem(hotkeyMenu())

        // Launch at login toggle.
        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = controller.config.launchAtLogin ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addPermissionItems(to menu: NSMenu) {
        if !Permissions.hasMicrophone {
            let item = NSMenuItem(title: "⚠ Grant Microphone access", action: #selector(fixMicrophone), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !Permissions.hasAccessibility {
            let item = NSMenuItem(title: "⚠ Grant Accessibility access", action: #selector(fixAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func languageMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in WhisperLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = controller.config.language == language ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func hotkeyMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Hotkey: \(controller.config.hotkey.displayName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for preset in HotkeyConfig.presets {
            let item = NSMenuItem(title: "Hold \(preset.displayName)", action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.keyCode
            item.state = controller.config.hotkey.keyCode == preset.keyCode ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func checkServer() {
        lastServerLine = "Checking..."
        Task {
            let line = await controller.checkServer()
            self.lastServerLine = line
        }
    }

    @objc private func editServerURL() {
        let alert = NSAlert()
        alert.messageText = "Whisper Server URL"
        alert.informativeText = "Base URL of the whisper service (e.g. the tailnet host)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = controller.config.serverBaseURLString
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            controller.updateConfig { $0.serverBaseURLString = value }
            lastServerLine = nil
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = WhisperLanguage(rawValue: raw) else { return }
        controller.updateConfig { $0.language = language }
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let keyCode = sender.representedObject as? UInt16,
              let preset = HotkeyConfig.presets.first(where: { $0.keyCode == keyCode }) else { return }
        controller.updateConfig { $0.hotkey = preset }
        hotkeyMonitor.update(hotkey: preset)
    }

    @objc private func toggleLaunchAtLogin() {
        let desired = !controller.config.launchAtLogin
        let ok = LaunchAtLogin.set(desired)
        controller.updateConfig { $0.launchAtLogin = ok ? desired : LaunchAtLogin.isEnabled }
    }

    @objc private func fixMicrophone() {
        Permissions.requestMicrophone { granted in
            if !granted { Permissions.openMicrophoneSettings() }
        }
    }

    @objc private func fixAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }
}
