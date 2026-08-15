import Testing
@testable import DictationCore

/// The hold-to-talk state machine, exercised with the event shapes a real
/// keyboard produces. `HotkeyMonitor` is a thin CGEvent adapter over this, so
/// these tests cover the part that can actually be wrong.
@Suite struct HotkeyEdgeResolverTests {

    private static let fnMask = HotkeyConfig.fnFlagMask
    private static let shiftMask: UInt64 = 0x20000
    private static let rightOptionCode: UInt16 = 61
    private static let f13Code: UInt16 = 105

    private func resolver(
        _ hotkeys: [HotkeyConfig] = AppConfig.defaultHotkeys
    ) -> HotkeyEdgeResolver {
        HotkeyEdgeResolver(hotkeys: hotkeys)
    }

    // MARK: - fn / Globe

    @Test func fnFlagRiseBeginsAndFallEnds() {
        var r = resolver()
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 63)) == .began)
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ended)
    }

    @Test func shiftPressedWhileFnHeldDoesNotEndTheHold() {
        // The real reason fn reads its flag instead of alternating: any other
        // modifier moving produces a flagsChanged while fn is still down.
        var r = resolver()
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 63)) == .began)
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask | Self.shiftMask, keyCode: 56)) == .ignored)
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 56)) == .ignored)
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ended)
    }

    @Test func flagsClearingWhileNothingHeldIsIgnored() {
        var r = resolver()
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ignored)
        #expect(r.heldTrigger == nil)
    }

    // MARK: - Regular keys (the external-keyboard path)

    @Test func f13DownBeginsAndUpEnds() {
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ended)
    }

    @Test func autoRepeatWhileHoldingF13DoesNotRestartTheHold() {
        // Holding a regular key produces repeated keyDown events.
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .ignored)
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .ignored)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ended)
    }

    @Test func unrelatedTypingIsIgnored() {
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: 0)) == .ignored)
        #expect(r.resolve(.keyUp(keyCode: 0)) == .ignored)
        #expect(r.heldTrigger == nil)
    }

    @Test func typingWhileF13IsHeldDoesNotEndTheHold() {
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.resolve(.keyDown(keyCode: 0)) == .ignored)
        #expect(r.resolve(.keyUp(keyCode: 0)) == .ignored)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ended)
    }

    // MARK: - Side-specific modifiers

    @Test func rightOptionAlternatesPressAndRelease() {
        var r = resolver([.rightOption])
        #expect(r.resolve(.flagsChanged(flags: 0x80140, keyCode: Self.rightOptionCode)) == .began)
        #expect(r.resolve(.flagsChanged(flags: 0x100, keyCode: Self.rightOptionCode)) == .ended)
    }

    @Test func leftOptionDoesNotDriveARightOptionHotkey() {
        // Both sides set the same flag bit, so only the key code tells them apart.
        var r = resolver([.rightOption])
        #expect(r.resolve(.flagsChanged(flags: 0x80120, keyCode: 58)) == .ignored)
        #expect(r.heldTrigger == nil)
    }

    // MARK: - Several hotkeys armed at once

    @Test func eitherArmedHotkeyCanStartAHold() {
        var r = resolver()
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 63)) == .began)
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ended)

        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ended)
    }

    @Test func aSecondHotkeyPressedMidHoldCannotEndItEarly() {
        // The hold belongs to the key that started it: releasing the other one
        // must not stop the recording.
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 63)) == .ignored)
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ignored)
        #expect(r.heldTrigger == .regularKey(keyCode: Self.f13Code))
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ended)
    }

    @Test func holdSurvivesFnFlagTrafficFromTheOtherKeyboard() {
        // Both keyboards are live at once: fn moving on the built-in keyboard
        // while F13 is held on the external one must not disturb the hold.
        var r = resolver()
        #expect(r.resolve(.flagsChanged(flags: Self.fnMask, keyCode: 63)) == .began)
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .ignored)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ignored)
        #expect(r.resolve(.flagsChanged(flags: 0, keyCode: 63)) == .ended)
    }

    // MARK: - Re-arming

    @Test func changingTheArmedSetMidHoldAbandonsTheHold() {
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        #expect(r.update(hotkeys: [.fnGlobe]) == true)
        #expect(r.heldTrigger == nil)
        // The now-unwatched release must not be read as a second end.
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ignored)
    }

    @Test func changingTheArmedSetWithNoHoldReportsNothingToCancel() {
        var r = resolver()
        #expect(r.update(hotkeys: [.fnGlobe]) == false)
    }

    @Test func newlyArmedHotkeyWorksImmediately() {
        var r = resolver([.fnGlobe])
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .ignored)
        _ = r.update(hotkeys: [.fnGlobe, .f13])
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
    }

    @Test func disarmedHotkeyStopsFiring() {
        var r = resolver()
        _ = r.update(hotkeys: [.fnGlobe])
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .ignored)
    }

    @Test func resetDropsTheHold() {
        var r = resolver()
        #expect(r.resolve(.keyDown(keyCode: Self.f13Code)) == .began)
        r.reset()
        #expect(r.heldTrigger == nil)
        #expect(r.resolve(.keyUp(keyCode: Self.f13Code)) == .ignored)
    }
}
