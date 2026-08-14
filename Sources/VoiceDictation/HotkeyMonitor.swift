import AppKit
import CoreGraphics
import DictationCore

/// Global hold-to-talk hotkeys via a CGEventTap.
///
/// Several hotkeys are armed at once, because one Mac routinely has keyboards
/// with different capabilities attached: fn/Globe only ever reaches macOS from
/// an Apple keyboard - a third-party keyboard resolves its own fn in firmware
/// and sends nothing - so an external keyboard needs a trigger of its own and
/// the user should not have to change a setting when they move hands.
///
/// This type is the CGEvent adapter and the debounce. Deciding when a hold
/// begins and ends lives in `HotkeyEdgeResolver`, which is pure Foundation and
/// unit-tested; keeping it out of here is what makes that possible.
///
/// Requires Accessibility permission - `CGEvent.tapCreate` returns `nil`
/// without it.
final class HotkeyMonitor {

    /// Called on the main queue when a hotkey is pressed.
    var onPressStart: (() -> Void)?
    /// Called on the main queue when it is released. `committed` is false when
    /// the hold was shorter than the debounce (an accidental tap), so the
    /// controller can cancel instead of firing an empty transcribe request.
    var onPressEnd: ((_ committed: Bool) -> Void)?

    private var resolver: HotkeyEdgeResolver
    /// Minimum hold to count as intentional; shorter taps are ignored.
    private let debounce: TimeInterval

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressStartedAt: CFAbsoluteTime = 0

    init(hotkeys: [HotkeyConfig], debounce: TimeInterval = 0.08) {
        self.resolver = HotkeyEdgeResolver(hotkeys: hotkeys)
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
        resolver.reset()
    }

    /// Swap the armed set (e.g. after the user toggles a key in the menu). A
    /// hold in progress is cancelled rather than left dangling, since its key
    /// may no longer be watched and its release would never arrive.
    func update(hotkeys: [HotkeyConfig]) {
        guard resolver.update(hotkeys: hotkeys) else { return }
        DispatchQueue.main.async { [weak self] in self?.onPressEnd?(false) }
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The system may disable the tap under load; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard let resolved = Self.event(from: type, event: event) else { return }

        let outcome = resolver.resolve(resolved)
        HotkeyDiagnostics.log("\(Self.describe(resolved, event: event)) -> \(outcome)")

        switch outcome {
        case .began:
            pressStartedAt = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async { [weak self] in self?.onPressStart?() }
        case .ended:
            let committed = CFAbsoluteTimeGetCurrent() - pressStartedAt >= debounce
            DispatchQueue.main.async { [weak self] in self?.onPressEnd?(committed) }
        case .ignored:
            break
        }
    }

    /// Human-readable line for `HotkeyDiagnostics`. The source device id is the
    /// interesting part when two keyboards are attached: it is what proves a
    /// key came from the external keyboard rather than the built-in one, and it
    /// matches the `RegistryID` column of
    /// `hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":6}'`.
    private static func describe(_ resolved: HotkeyEdgeResolver.Event, event: CGEvent) -> String {
        let device = event.getIntegerValueField(CGEventField(rawValue: 87) ?? .eventSourceUserData)
        let flags = String(event.flags.rawValue, radix: 16)
        return "\(resolved) flags=0x\(flags) device=0x\(String(device, radix: 16))"
    }

    private static func event(from type: CGEventType, event: CGEvent) -> HotkeyEdgeResolver.Event? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged: return .flagsChanged(flags: event.flags.rawValue, keyCode: keyCode)
        case .keyDown: return .keyDown(keyCode: keyCode)
        case .keyUp: return .keyUp(keyCode: keyCode)
        default: return nil
        }
    }
}
