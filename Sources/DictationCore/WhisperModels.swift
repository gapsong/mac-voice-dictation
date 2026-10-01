import Foundation

/// Language hint sent to the whisper backend via the `X-Language` header.
public enum WhisperLanguage: String, CaseIterable, Codable, Sendable {
    case de
    case en
    case auto

    /// Human-readable label for menu display.
    public var displayName: String {
        switch self {
        case .de: return "German (de)"
        case .en: return "English (en)"
        case .auto: return "Auto-detect"
        }
    }
}

/// Server state as reported by `GET /health` and `POST /start`.
public enum WhisperServerState: String, Codable, Sendable {
    case sleeping
    case ready
}

/// Decoded `GET /health` (and `POST /start`) response.
///
/// The backend boots asleep by design (0 GPU); `state` transitions to `ready`
/// once the model is loaded.
public struct HealthResponse: Codable, Equatable, Sendable {
    public let model: String?
    public let state: WhisperServerState
    /// The server sometimes omits `ready` and reports readiness via `state`
    /// alone (e.g. `{"state":"ready"}`). Optional so decoding tolerates that;
    /// use `isReady` rather than reading this directly.
    public let ready: Bool?

    public init(model: String?, state: WhisperServerState, ready: Bool? = nil) {
        self.model = model
        self.state = state
        self.ready = ready
    }

    /// Whether the model is loaded and can transcribe. Trusts an explicit
    /// `ready` flag when present, otherwise falls back to `state == .ready`, so
    /// a `{"state":"ready"}` body without the flag is correctly treated as up.
    public var isReady: Bool {
        ready ?? (state == .ready)
    }
}

/// Decoded `POST /transcribe` response.
public struct TranscribeResponse: Codable, Equatable, Sendable {
    public let text: String
    public let language: String?
    public let ms: Double?

    public init(text: String, language: String?, ms: Double?) {
        self.text = text
        self.language = language
        self.ms = ms
    }
}

/// Errors surfaced by the whisper client. Each maps to a user-visible status;
/// the client never traps, so the menu bar can always show something.
public enum WhisperError: Error, Equatable, Sendable {
    /// Proxy reachable but backend down (HTTP 502).
    case backendDown
    /// Model not yet loaded after `/start` (retried once, still not ready).
    case notReady
    /// Backend returned an empty transcription.
    case emptyText
    /// Non-success HTTP status we do not special-case.
    case httpStatus(Int)
    /// Response body could not be decoded.
    case decoding
    /// Network failure / timeout / host unreachable (e.g. whisper-service not
    /// running, or a remote server while off the tailnet).
    case unreachable(String)

    public var userMessage: String {
        switch self {
        case .backendDown: return "Whisper backend is down (502)"
        case .notReady: return "Model still loading, try again"
        case .emptyText: return "No speech detected"
        case .httpStatus(let code): return "Server error (HTTP \(code))"
        case .decoding: return "Bad response from server"
        case .unreachable: return "Server unreachable (whisper-service running?)"
        }
    }
}
