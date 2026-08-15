import Foundation

/// Decides when a hold-to-talk press begins and ends, for a set of hotkeys
/// armed at once.
///
/// This is the part of the hotkey path worth testing, so it is pure Foundation
/// and knows nothing about CGEvent: `HotkeyMonitor` translates real events into
/// `Event` values and feeds them in. The rules it encodes:
///
/// - A hold is owned by the trigger that started it. Until that key is released
///   the other armed hotkeys are ignored, so pressing a second one mid-recording
///   can neither nest a hold nor end the recording early.
/// - fn/Globe carries no reliable key code, so its state is read straight off
///   the modifier flag. Unrelated `flagsChanged` events (Shift pressed while fn
///   is held) therefore resolve to "still down" rather than a release.
/// - Left/right modifiers share a flag bit, so they are matched by key code and
///   alternate press/release.
/// - Regular keys use key down/up, and their auto-repeat is absorbed by the
///   ownership rule above.
public struct HotkeyEdgeResolver: Equatable, Sendable {

    /// A keyboard event, reduced to what the decision actually needs.
    public enum Event: Equatable, Sendable {
        /// Modifier state changed. `flags` is the full `CGEventFlags` bitfield.
        case flagsChanged(flags: UInt64, keyCode: UInt16)
        case keyDown(keyCode: UInt16)
        case keyUp(keyCode: UInt16)
    }

    public enum Outcome: Equatable, Sendable {
        case began
        case ended
        case ignored
    }

    /// The trigger currently holding the recording open, if any.
    public private(set) var heldTrigger: HotkeyTrigger?

    private var hotkeys: [HotkeyConfig]

    public init(hotkeys: [HotkeyConfig]) {
        self.hotkeys = hotkeys
    }

    /// Swap the armed set. Returns true when a hold in progress was abandoned:
    /// its key may no longer be watched, in which case its release would never
    /// arrive and the recording would hang open.
    public mutating func update(hotkeys: [HotkeyConfig]) -> Bool {
        self.hotkeys = hotkeys
        guard heldTrigger != nil else { return false }
        heldTrigger = nil
        return true
    }

    /// Abandon any hold, e.g. when the event tap is torn down.
    public mutating func reset() {
        heldTrigger = nil
    }

    public mutating func resolve(_ event: Event) -> Outcome {
        if let held = heldTrigger {
            guard edge(for: held, event: event) == .release else { return .ignored }
            heldTrigger = nil
            return .ended
        }

        for hotkey in hotkeys where edge(for: hotkey.trigger, event: event) == .press {
            heldTrigger = hotkey.trigger
            return .began
        }
        return .ignored
    }

    // MARK: - Per-trigger edge detection

    private enum Edge { case press, release, none }

    private func edge(for trigger: HotkeyTrigger, event: Event) -> Edge {
        switch (trigger, event) {
        case let (.modifierFlag(mask), .flagsChanged(flags, _)):
            // The flag itself is the key's state, so read it rather than
            // alternating - that keeps unrelated flag traffic from ending a hold.
            return (flags & mask) != 0 ? .press : .release

        case let (.modifierKey(code), .flagsChanged(_, keyCode)) where keyCode == code:
            // No per-side flag bit exists, so alternate on the key code.
            return heldTrigger == trigger ? .release : .press

        case let (.regularKey(code), .keyDown(keyCode)) where keyCode == code:
            return .press

        case let (.regularKey(code), .keyUp(keyCode)) where keyCode == code:
            return .release

        default:
            return .none
        }
    }
}
