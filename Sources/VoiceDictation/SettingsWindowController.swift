import AppKit
import DictationCore

/// A plain, normal-level AppKit window that gives the user a dependable way into
/// the app regardless of the menu-bar icon - the notch on 15" MacBook Airs can
/// hide the status item entirely. Shows live status, the two permission states
/// with Grant buttons, a server check, and the same hotkey / language / URL /
/// launch-at-login controls the menu exposes. All mutations go through the
/// shared `DictationActions`, so nothing is duplicated.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let controller: DictationController
    private let actions: DictationActions
    /// Called when the window closes so the app can drop back to `.accessory`
    /// (no permanent Dock icon).
    private let onClose: () -> Void

    private var window: NSWindow?

    // Live-updating views.
    private let statusValue = NSTextField(labelWithString: "")
    private let micRow = PermissionRow(title: "Microphone")
    private let axRow = PermissionRow(title: "Accessibility")
    private let serverField = NSTextField(string: "")
    private let serverResult = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    /// One checkbox per preset, in `HotkeyConfig.presets` order - several
    /// hotkeys can be armed at once, so this is not a single-choice popup.
    private let hotkeyChecks: [NSButton] = HotkeyConfig.presets.map {
        NSButton(checkboxWithTitle: $0.displayName, target: nil, action: nil)
    }
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private var permissionPollTimer: Timer?

    init(controller: DictationController, actions: DictationActions, onClose: @escaping () -> Void) {
        self.controller = controller
        self.actions = actions
        self.onClose = onClose
        super.init()

        controller.observeStatus { [weak self] status in
            self?.statusValue.stringValue = status.menuText
        }
    }

    // MARK: - Presentation

    /// Show (building lazily) and foreground the window.
    func show() {
        if window == nil { buildWindow() }
        refresh()
        startPermissionPolling()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 0),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Dictation"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(headerRow())
        content.addArrangedSubview(separator())
        content.addArrangedSubview(sectionLabel("Permissions"))
        content.addArrangedSubview(configurePermissionRow(micRow, action: #selector(grantMicrophone)))
        content.addArrangedSubview(configurePermissionRow(axRow, action: #selector(grantAccessibility)))
        content.addArrangedSubview(separator())
        content.addArrangedSubview(sectionLabel("Server"))
        content.addArrangedSubview(serverRow())
        content.addArrangedSubview(serverResult)
        content.addArrangedSubview(separator())
        content.addArrangedSubview(sectionLabel("Settings"))
        content.addArrangedSubview(labeledRow("Language", languagePopup))
        content.addArrangedSubview(hotkeySection())
        content.addArrangedSubview(launchRow())

        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        window.contentView = root
        self.window = window
    }

    // MARK: - Rows

    private func headerRow() -> NSView {
        let title = NSTextField(labelWithString: "Status:")
        title.font = .boldSystemFont(ofSize: 13)
        statusValue.font = .systemFont(ofSize: 13)
        return hStack([title, statusValue])
    }

    private func configurePermissionRow(_ row: PermissionRow, action: Selector) -> NSView {
        row.grantButton.target = self
        row.grantButton.action = action
        return row
    }

    private func serverRow() -> NSView {
        serverField.placeholderString = "http://127.0.0.1:9876"
        serverField.translatesAutoresizingMaskIntoConstraints = false
        serverField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let save = NSButton(title: "Save", target: self, action: #selector(saveServerURL))
        let check = NSButton(title: "Check Server", target: self, action: #selector(checkServer))
        serverResult.font = .systemFont(ofSize: 11)
        serverResult.textColor = .secondaryLabelColor
        return hStack([serverField, save, check])
    }

    private func launchRow() -> NSView {
        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLaunchAtLogin)
        return launchAtLogin
    }

    /// Hotkeys as a checkbox list: arming several at once is the point, since
    /// fn only ever reaches macOS from an Apple keyboard and an external
    /// keyboard needs a trigger of its own.
    private func hotkeySection() -> NSView {
        var rows: [NSView] = [sectionLabel("Hotkeys (hold any to dictate)")]

        for (index, button) in hotkeyChecks.enumerated() {
            button.target = self
            button.action = #selector(toggleHotkey(_:))
            button.tag = index
            rows.append(button)

            // The F13-F19 block needs a word of explanation: it is empty on
            // every real keyboard until the user remaps a key onto it.
            if HotkeyConfig.presets[index] == HotkeyConfig.modifierPresets.last {
                rows.append(hint("For an external keyboard, remap one of its keys"))
                rows.append(hint("onto F13-F19 in the keyboard's own configurator."))
            }
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return hStack([label, control])
    }

    // MARK: - State sync

    /// Populate every control from the current config and permission state.
    private func refresh() {
        statusValue.stringValue = controller.status.menuText
        micRow.update(granted: Permissions.hasMicrophone)
        axRow.update(granted: Permissions.hasAccessibility)

        serverField.stringValue = controller.config.serverBaseURLString

        languagePopup.removeAllItems()
        for language in WhisperLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(selectLanguage)
        if let index = WhisperLanguage.allCases.firstIndex(of: controller.config.language) {
            languagePopup.selectItem(at: index)
        }

        syncHotkeyChecks()

        launchAtLogin.state = controller.config.launchAtLogin ? .on : .off
    }

    /// While the window is open, re-poll the two permission states (they are
    /// granted out-of-band in System Settings) so the rows update live.
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.micRow.update(granted: Permissions.hasMicrophone)
                self.axRow.update(granted: Permissions.hasAccessibility)
            }
        }
    }

    // MARK: - Actions (all via the shared DictationActions)

    @objc private func grantMicrophone() { actions.grantMicrophone() }
    @objc private func grantAccessibility() { actions.grantAccessibility() }

    @objc private func saveServerURL() {
        actions.setServerURL(serverField.stringValue)
        serverResult.stringValue = ""
    }

    @objc private func checkServer() {
        serverResult.stringValue = "Checking…"
        Task { [weak self] in
            guard let self else { return }
            let line = await self.actions.checkServer()
            self.serverResult.stringValue = line
        }
    }

    @objc private func selectLanguage() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = WhisperLanguage(rawValue: raw) else { return }
        actions.setLanguage(language)
    }

    @objc private func toggleHotkey(_ sender: NSButton) {
        let index = sender.tag
        guard HotkeyConfig.presets.indices.contains(index) else { return }
        actions.setHotkey(HotkeyConfig.presets[index], enabled: sender.state == .on)
        // Re-read the config rather than trusting the click: disarming the last
        // hotkey is refused, and the checkbox must snap back when it is.
        syncHotkeyChecks()
    }

    /// Mirror the armed set onto the checkboxes.
    private func syncHotkeyChecks() {
        let armed = controller.config.hotkeys
        for (index, button) in hotkeyChecks.enumerated() {
            button.state = armed.contains(HotkeyConfig.presets[index]) ? .on : .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        actions.toggleLaunchAtLogin()
        launchAtLogin.state = controller.config.launchAtLogin ? .on : .off
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        onClose()
    }

    // MARK: - Small view helpers

    private func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return line
    }
}

/// One "<permission>: ✓ Granted / ✗ Missing [Grant]" row.
private final class PermissionRow: NSStackView {
    private let name: NSTextField
    private let state = NSTextField(labelWithString: "")
    let grantButton = NSButton(title: "Grant", target: nil, action: nil)

    init(title: String) {
        name = NSTextField(labelWithString: "\(title):")
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY

        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 110).isActive = true
        state.font = .systemFont(ofSize: 12)

        addArrangedSubview(name)
        addArrangedSubview(state)
        addArrangedSubview(grantButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(granted: Bool) {
        if granted {
            state.stringValue = "✓ Granted"
            state.textColor = .systemGreen
            grantButton.isHidden = true
        } else {
            state.stringValue = "✗ Missing"
            state.textColor = .systemRed
            grantButton.isHidden = false
        }
    }
}
