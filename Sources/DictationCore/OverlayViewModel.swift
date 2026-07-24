import Foundation

/// Headless presentation logic for the on-screen recording overlay. Maps an
/// `AppStatus` to what the floating HUD should show (label, accent, pulse) and
/// how long it should linger after the app returns to idle.
///
/// Kept free of AppKit so the mapping and the auto-hide timing policy are
/// unit-testable. The AppKit panel wiring lives in `Sources/VoiceDictation/`.
public enum OverlayViewModel {

    /// Visual emphasis for the overlay, mapped to a concrete colour by the panel.
    public enum Accent: Equatable, Sendable {
        /// Active recording - red, paired with a pulsing dot.
        case recording
        /// Working (transcribing / inserting) - neutral accent.
        case working
        /// Informational banner (e.g. the launch greeting).
        case info
        /// Something needs attention (error / missing permission).
        case warning
    }

    /// Everything the panel needs to render one overlay frame.
    public struct Presentation: Equatable, Sendable {
        public var label: String
        public var accent: Accent
        /// Whether to show the pulsing red recording dot.
        public var showsPulse: Bool

        public init(label: String, accent: Accent, showsPulse: Bool) {
            self.label = label
            self.accent = accent
            self.showsPulse = showsPulse
        }
    }

    /// Whether the overlay should be on-screen for a given status. Idle is the
    /// only state that hides it (after `idleHideDelay`); every active or
    /// attention state keeps it visible.
    public static func isVisible(for status: AppStatus) -> Bool {
        status != .idle
    }

    /// How the overlay should render for a given status. Returns `nil` for
    /// `.idle`, which has no visible presentation of its own (the panel fades
    /// out instead of rendering an idle frame).
    public static func presentation(for status: AppStatus) -> Presentation? {
        switch status {
        case .idle:
            return nil
        case .recording:
            return Presentation(label: "🎙 Recording…", accent: .recording, showsPulse: true)
        case .warmingUp:
            return Presentation(label: "⏳ Warming up server…", accent: .working, showsPulse: false)
        case .transcribing:
            return Presentation(label: "✍️ Transcribing…", accent: .working, showsPulse: false)
        case .inserting:
            return Presentation(label: "Inserting…", accent: .working, showsPulse: false)
        case .needsPermission(let what):
            return Presentation(label: "⚠ \(what) permission required", accent: .warning, showsPulse: false)
        case .error(let message):
            return Presentation(label: "⚠ \(message)", accent: .warning, showsPulse: false)
        }
    }

    /// How long the overlay lingers on-screen after the app returns to idle
    /// before it fades out. Long enough to register the final "Inserting…", short
    /// enough not to nag.
    public static let idleHideDelay: TimeInterval = 1.2

    /// How long an attention banner (error / missing permission) stays before it
    /// dismisses itself. The controller never auto-leaves these terminal states,
    /// so without this the HUD - a floating panel that rides over every Space and
    /// full-screen app - would linger indefinitely after a failure.
    public static let attentionHideDelay: TimeInterval = 4.0

    /// How long the overlay should stay before auto-dismissing for a given
    /// status, or `nil` if it should remain until the next status change drives
    /// it away. Only the terminal attention states self-dismiss; the transient
    /// working states are always superseded by another status.
    public static func autoHideDelay(for status: AppStatus) -> TimeInterval? {
        switch status {
        case .error, .needsPermission:
            return attentionHideDelay
        default:
            return nil
        }
    }

    /// The fade-out animation duration once the linger delay elapses.
    public static let fadeDuration: TimeInterval = 0.35
}
