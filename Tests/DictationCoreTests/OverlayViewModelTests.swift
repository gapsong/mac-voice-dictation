import Testing
import Foundation
@testable import DictationCore

@Suite struct OverlayViewModelTests {

    // MARK: - Visibility

    @Test func idleIsNotVisible() {
        #expect(OverlayViewModel.isVisible(for: .idle) == false)
    }

    @Test func activeAndAttentionStatesAreVisible() {
        #expect(OverlayViewModel.isVisible(for: .recording))
        #expect(OverlayViewModel.isVisible(for: .transcribing))
        #expect(OverlayViewModel.isVisible(for: .inserting))
        #expect(OverlayViewModel.isVisible(for: .error("x")))
        #expect(OverlayViewModel.isVisible(for: .needsPermission("Microphone")))
    }

    // MARK: - Presentation mapping

    @Test func idleHasNoPresentation() {
        #expect(OverlayViewModel.presentation(for: .idle) == nil)
    }

    @Test func recordingShowsPulsingRecordingAccent() {
        let p = OverlayViewModel.presentation(for: .recording)
        #expect(p?.accent == .recording)
        #expect(p?.showsPulse == true)
        #expect(p?.label.contains("Aufnahme") == true)
    }

    @Test func transcribingIsWorkingWithoutPulse() {
        let p = OverlayViewModel.presentation(for: .transcribing)
        #expect(p?.accent == .working)
        #expect(p?.showsPulse == false)
        #expect(p?.label.contains("Transkribiere") == true)
    }

    @Test func insertingIsWorkingWithoutPulse() {
        let p = OverlayViewModel.presentation(for: .inserting)
        #expect(p?.accent == .working)
        #expect(p?.showsPulse == false)
        #expect(p?.label.contains("Einfügen") == true)
    }

    // MARK: - Permission / error copy

    @Test func microphonePermissionUsesGermanCopyWithWarningAccent() {
        let p = OverlayViewModel.presentation(for: .needsPermission("Microphone"))
        #expect(p?.accent == .warning)
        #expect(p?.showsPulse == false)
        #expect(p?.label == "⚠ Mikrofon-Recht fehlt")
    }

    @Test func accessibilityPermissionUsesGermanCopy() {
        let p = OverlayViewModel.presentation(for: .needsPermission("Accessibility"))
        #expect(p?.label == "⚠ Bedienungshilfen-Recht fehlt")
    }

    @Test func unmappedPermissionFallsBackGracefully() {
        let p = OverlayViewModel.presentation(for: .needsPermission("Camera"))
        #expect(p?.label == "⚠ Camera-Recht fehlt")
    }

    @Test func knownServerErrorMapsToGerman() {
        let p = OverlayViewModel.presentation(for: .error("Server unreachable"))
        #expect(p?.accent == .warning)
        #expect(p?.label == "⚠ Server nicht erreichbar")
    }

    @Test func unmappedErrorFallsBackToRawMessage() {
        let p = OverlayViewModel.presentation(for: .error("weird backend thing"))
        #expect(p?.label == "⚠ weird backend thing")
    }

    // MARK: - Timing policy

    @Test func idleHideDelayIsPositiveAndBrief() {
        #expect(OverlayViewModel.idleHideDelay > 0)
        #expect(OverlayViewModel.idleHideDelay <= 3.0)
    }

    @Test func fadeDurationIsPositive() {
        #expect(OverlayViewModel.fadeDuration > 0)
    }
}
