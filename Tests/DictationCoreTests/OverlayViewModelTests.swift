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
        #expect(OverlayViewModel.isVisible(for: .warmingUp))
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
        #expect(p?.label.contains("Recording") == true)
    }

    @Test func transcribingIsWorkingWithoutPulse() {
        let p = OverlayViewModel.presentation(for: .transcribing)
        #expect(p?.accent == .working)
        #expect(p?.showsPulse == false)
        #expect(p?.label.contains("Transcribing") == true)
    }

    @Test func insertingIsWorkingWithoutPulse() {
        let p = OverlayViewModel.presentation(for: .inserting)
        #expect(p?.accent == .working)
        #expect(p?.showsPulse == false)
        #expect(p?.label.contains("Inserting") == true)
    }

    @Test func warmingUpIsWorkingWithoutPulse() {
        let p = OverlayViewModel.presentation(for: .warmingUp)
        #expect(p?.accent == .working)
        #expect(p?.showsPulse == false)
        #expect(p?.label.contains("Warming up") == true)
    }

    // MARK: - Permission / error copy (English, warning accent)

    @Test func microphonePermissionUsesWarningAccent() {
        let p = OverlayViewModel.presentation(for: .needsPermission("Microphone"))
        #expect(p?.accent == .warning)
        #expect(p?.showsPulse == false)
        #expect(p?.label == "⚠ Microphone permission required")
    }

    @Test func accessibilityPermissionCopy() {
        let p = OverlayViewModel.presentation(for: .needsPermission("Accessibility"))
        #expect(p?.label == "⚠ Accessibility permission required")
    }

    @Test func serverErrorShownWithWarningAccent() {
        let p = OverlayViewModel.presentation(for: .error("Server unreachable"))
        #expect(p?.accent == .warning)
        #expect(p?.label == "⚠ Server unreachable")
    }

    @Test func errorLabelPrefixesRawMessage() {
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

    // MARK: - Auto-hide policy

    @Test func attentionStatesSelfDismiss() {
        #expect(OverlayViewModel.autoHideDelay(for: .error("Server unreachable")) == OverlayViewModel.attentionHideDelay)
        #expect(OverlayViewModel.autoHideDelay(for: .needsPermission("Microphone")) == OverlayViewModel.attentionHideDelay)
        #expect(OverlayViewModel.attentionHideDelay > 0)
    }

    @Test func transientAndActiveStatesDoNotSelfDismiss() {
        #expect(OverlayViewModel.autoHideDelay(for: .recording) == nil)
        #expect(OverlayViewModel.autoHideDelay(for: .warmingUp) == nil)
        #expect(OverlayViewModel.autoHideDelay(for: .transcribing) == nil)
        #expect(OverlayViewModel.autoHideDelay(for: .inserting) == nil)
        #expect(OverlayViewModel.autoHideDelay(for: .idle) == nil)
    }
}
