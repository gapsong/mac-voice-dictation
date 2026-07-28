import AppKit
import DictationCore

/// Owns the menu-bar `NSStatusItem`: its icon reflects `AppStatus`, and its menu
/// exposes every configurable setting plus permission guidance.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let actions: DictationActions
    /// Opens/foregrounds the status/settings window from the menu.
    private let openSettings: () -> Void

    /// Latest health line from a "Check server" action, shown in the menu.
    private var lastServerLine: String?

    init(controller: DictationController, actions: DictationActions, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.actions = actions
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.observeStatus { [weak self] status in
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

        // Always-reachable window (the dependable entry point when the notch
        // hides this very status item).
        let window = NSMenuItem(title: "Open Status Window…", action: #selector(openStatusWindow), keyEquivalent: "")
        window.target = self
        menu.addItem(window)

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
        for (index, preset) in HotkeyConfig.presets.enumerated() {
            let item = NSMenuItem(title: "Hold \(preset.displayName)", action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = controller.config.hotkey == preset ? .on : .off
            submenu.addItem(item)
        }

        // First-run guidance for the default fn/Globe hotkey: without this the
        // Globe key also fires emoji / input switching while dictating.
        if case .modifierFlag = controller.config.hotkey.trigger {
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Set Globe key → \"Do Nothing\" so fn"))
            submenu.addItem(disabledItem("doesn't also switch input / emoji:"))
            let fix = NSMenuItem(title: "Open Keyboard Settings...", action: #selector(openKeyboardSettings), keyEquivalent: "")
            fix.target = self
            submenu.addItem(fix)
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

    @objc private func openStatusWindow() {
        openSettings()
    }

    @objc private func checkServer() {
        lastServerLine = "Checking..."
        Task {
            let line = await actions.checkServer()
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
            actions.setServerURL(value)
            lastServerLine = nil
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = WhisperLanguage(rawValue: raw) else { return }
        actions.setLanguage(language)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              HotkeyConfig.presets.indices.contains(index) else { return }
        actions.setHotkey(HotkeyConfig.presets[index])
    }

    @objc private func toggleLaunchAtLogin() {
        actions.toggleLaunchAtLogin()
    }

    @objc private func openKeyboardSettings() {
        actions.openKeyboardSettings()
    }

    @objc private func fixMicrophone() {
        actions.grantMicrophone()
    }

    @objc private func fixAccessibility() {
        actions.grantAccessibility()
    }
}
