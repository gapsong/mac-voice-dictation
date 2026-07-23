import AppKit
import CoreGraphics
import DictationCore

/// Global hold-to-talk hotkey via a CGEventTap.
///
/// Handles the three `HotkeyTrigger` shapes. The default fn/Globe key is a
/// modifier *flag* (`.maskSecondaryFn`): it has no reliable key code, so it is
/// detected by the rising/falling edge of that flag on `flagsChanged`. Other
/// modifiers like Right Option arrive on `flagsChanged` too, but share a flag
/// bit with their sibling, so we compare the event's key code to tell the
/// left/right variant apart. Regular keys arrive via `keyDown`/`keyUp`. A short
/// debounce suppresses an accidental tap so it does not fire an empty request.
///
/// Requires Accessibility permission - `CGEvent.tapCreate` returns `nil`
/// without it.
final class HotkeyMonitor {

    /// Called on the main queue when the key is pressed.
    var onPressStart: (() -> Void)?
    /// Called on the main queue when the key is released. `committed` is false
    /// when the hold was shorter than the debounce (an accidental tap), so the
    /// controller can cancel instead of firing an empty transcribe request.
    var onPressEnd: ((_ committed: Bool) -> Void)?

    private var hotkey: HotkeyConfig
    /// Minimum hold to count as intentional; shorter taps are ignored.
    private let debounce: TimeInterval

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private var pressStartedAt: CFAbsoluteTime = 0

    init(hotkey: HotkeyConfig, debounce: TimeInterval = 0.08) {
        self.hotkey = hotkey
        self.debounce = debounce
    }

    /// Whether the tap is currently installed.
    private(set) var isRunning = false

    /// Installs the event tap. Returns false if Accessibility is not granted
    /// (the caller then surfaces a permission prompt).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isRunning = true
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        isHeld = false
    }

    /// Swap the active hotkey (e.g. after the user picks a different key).
    func update(hotkey: HotkeyConfig) {
        self.hotkey = hotkey
        isHeld = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The system may disable the tap under load; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch hotkey.trigger {
        case .modifierFlag(let mask):
            // fn/Globe and similar: identified by a modifier flag, not a key
            // code. Detect the rising/falling edge of that flag so extra
            // flagsChanged events (e.g. Shift pressed while fn is held) are
            // ignored.
            guard type == .flagsChanged else { return }
            let isSet = (event.flags.rawValue & mask) != 0
            if isSet, !isHeld {
                begin()
            } else if !isSet, isHeld {
                end()
            }

        case .modifierKey(let code):
            // Left/right modifiers share a flag bit, so match the key code and
            // toggle: the first flagsChanged for that code is the press, the
            // next is the release.
            guard type == .flagsChanged, keyCode == code else { return }
            if !isHeld {
                begin()
            } else {
                end()
            }

        case .regularKey(let code):
            guard keyCode == code else { return }
            if type == .keyDown, !isHeld {
                begin()
            } else if type == .keyUp, isHeld {
                end()
            }
        }
    }

    private func begin() {
        isHeld = true
        pressStartedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { [weak self] in self?.onPressStart?() }
    }

    private func end() {
        isHeld = false
        let heldFor = CFAbsoluteTimeGetCurrent() - pressStartedAt
        let committed = heldFor >= debounce
        DispatchQueue.main.async { [weak self] in
            self?.onPressEnd?(committed)
        }
    }
}
