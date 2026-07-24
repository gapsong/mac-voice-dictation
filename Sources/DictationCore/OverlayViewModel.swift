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
            return Presentation(label: "🎙 Aufnahme läuft…", accent: .recording, showsPulse: true)
        case .transcribing:
            return Presentation(label: "✍️ Transkribiere…", accent: .working, showsPulse: false)
        case .inserting:
            return Presentation(label: "Einfügen…", accent: .working, showsPulse: false)
        case .needsPermission(let what):
            return Presentation(label: "⚠ \(germanPermission(what)) fehlt", accent: .warning, showsPulse: false)
        case .error(let message):
            return Presentation(label: "⚠ \(germanError(message))", accent: .warning, showsPulse: false)
        }
    }

    /// How long the overlay lingers on-screen after the app returns to idle
    /// before it fades out. Long enough to register the final "Einfügen…", short
    /// enough not to nag.
    public static let idleHideDelay: TimeInterval = 1.2

    /// The fade-out animation duration once the linger delay elapses.
    public static let fadeDuration: TimeInterval = 0.35

    // MARK: - German copy

    /// Maps the English permission identifiers used internally to the German
    /// labels the user sees on the overlay.
    private static func germanPermission(_ what: String) -> String {
        switch what {
        case "Microphone": return "Mikrofon-Recht"
        case "Accessibility": return "Bedienungshilfen-Recht"
        default: return "\(what)-Recht"
        }
    }

    /// Maps the known English error messages from the whisper client to German
    /// overlay copy, falling back to the raw message for anything unmapped.
    private static func germanError(_ message: String) -> String {
        switch message {
        case "Server unreachable", "Server unreachable (on Tailscale?)":
            return "Server nicht erreichbar"
        case "Mic unavailable":
            return "Mikrofon nicht verfügbar"
        case "No speech detected":
            return "Nichts erkannt"
        case "Transcription failed":
            return "Transkription fehlgeschlagen"
        default:
            return message
        }
    }
}
