import Foundation

/// High-level state the app reflects. Drives the menu-bar icon, the on-screen
/// overlay, and the status/settings window. Pure Foundation so the overlay
/// presentation logic can be unit-tested without AppKit.
public enum AppStatus: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(String)
    /// A permission the app needs has not been granted yet.
    case needsPermission(String)

    /// SF Symbol name for the status item.
    public var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .inserting: return "text.cursor"
        case .error: return "exclamationmark.triangle"
        case .needsPermission: return "lock.shield"
        }
    }

    /// Short line shown at the top of the menu and in the settings window.
    public var menuText: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .inserting: return "Inserting..."
        case .error(let message): return "Error: \(message)"
        case .needsPermission(let what): return "Needs \(what) permission"
        }
    }
}
