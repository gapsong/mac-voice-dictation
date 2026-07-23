import Foundation

/// High-level state the menu-bar icon reflects. Drives both the status-item
/// symbol and the menu's status line.
enum AppStatus: Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(String)
    /// A permission the app needs has not been granted yet.
    case needsPermission(String)

    /// SF Symbol name for the status item.
    var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .inserting: return "text.cursor"
        case .error: return "exclamationmark.triangle"
        case .needsPermission: return "lock.shield"
        }
    }

    /// Short line shown at the top of the menu.
    var menuText: String {
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
