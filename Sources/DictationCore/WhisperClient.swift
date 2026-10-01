import Foundation

/// Builds the HTTP requests for the whisper contract. Split out from the
/// networking so request shaping (URL, method, headers, content-type, body)
/// can be unit-tested without hitting the network.
public enum WhisperRequestFactory {

    public enum RequestError: Error, Equatable {
        case invalidBaseURL
    }

    /// `GET /health`
    public static func healthRequest(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        return request
    }

    /// `POST /start` - wakes the server and loads the model.
    public static func startRequest(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("start"))
        request.httpMethod = "POST"
        return request
    }

    /// `POST /transcribe` with `Content-Type: audio/wav`, `X-Language` header,
    /// and the WAV bytes as the body.
    public static func transcribeRequest(
        baseURL: URL,
        wavData: Data,
        language: WhisperLanguage
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(language.rawValue, forHTTPHeaderField: "X-Language")
        request.httpBody = wavData
        return request
    }
}

/// Async client for the remote whisper service.
///
/// Handles the documented failure modes without ever trapping: 502 backend
/// down, empty text, network/timeout, and the not-yet-ready-after-`/start` race
/// (gated by `waitUntilReady` and ridden out by a bounded retry loop in
/// `transcribe`). The scoped `HostTrustDelegate` accepts the server's
/// self-signed certificate for the configured host only.
public final class WhisperClient: Sendable {

    private let baseURL: URL
    private let session: URLSession
    private let ownsSession: Bool

    /// - Parameters:
    ///   - baseURL: Server base, e.g. `http://127.0.0.1:9876`.
    ///   - session: Inject a custom session for tests; defaults to one wired to
    ///     a `HostTrustDelegate` scoped to `baseURL`'s host.
    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.waitsForConnectivity = false
            let delegate = HostTrustDelegate(trustedHost: baseURL.host ?? "")
            self.session = URLSession(
                configuration: config,
                delegate: delegate,
                delegateQueue: nil
            )
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    /// `GET /health`
    public func health() async throws -> HealthResponse {
        let request = WhisperRequestFactory.healthRequest(baseURL: baseURL)
        let (data, response) = try await perform(request)
        try ensureOK(response)
        return try decode(HealthResponse.self, from: data)
    }

    /// `POST /start` - fire on hotkey-down so the model warms while the user is
    /// still speaking.
    @discardableResult
    public func start() async throws -> HealthResponse {
        let request = WhisperRequestFactory.startRequest(baseURL: baseURL)
        let (data, response) = try await perform(request)
        try ensureOK(response)
        return try decode(HealthResponse.self, from: data)
    }

    /// How long `waitUntilReady` polls before giving up, and how often it polls.
    /// The model typically loads within a few seconds of `/start`.
    public static let defaultReadyTimeout: TimeInterval = 15
    public static let defaultReadyPollInterval: TimeInterval = 0.4

    /// One `GET /health`, reduced to a simple readiness bool. Never throws -
    /// any transport/decoding hiccup is reported as "not ready".
    public func isReadyNow() async -> Bool {
        (try? await health())?.isReady ?? false
    }

    /// Polls `GET /health` until the model reports ready or `timeout` elapses,
    /// returning the final readiness. The server boots asleep and loads the
    /// model a few seconds after `/start`; sending audio before then makes it
    /// 500, so callers use this to gate `/transcribe`. Transient errors while
    /// polling are treated as "not ready yet" and retried until the deadline.
    @discardableResult
    public func waitUntilReady(
        timeout: TimeInterval = WhisperClient.defaultReadyTimeout,
        pollInterval: TimeInterval = WhisperClient.defaultReadyPollInterval
    ) async -> Bool {
        let polls = max(1, Int((timeout / pollInterval).rounded(.up)))
        for poll in 0..<polls {
            if await isReadyNow() { return true }
            if poll < polls - 1 {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        return false
    }

    /// `POST /transcribe`. Retries a bounded number of times on a not-ready
    /// backend (HTTP 500/503) with exponential backoff, since even just after a
    /// "ready" health the very first transcribe can race the model swap-in.
    public func transcribe(
        wavData: Data,
        language: WhisperLanguage
    ) async throws -> TranscribeResponse {
        var backoff: UInt64 = 500_000_000
        for attempt in 0..<WhisperClient.maxTranscribeAttempts {
            do {
                return try await transcribeOnce(wavData: wavData, language: language)
            } catch WhisperError.notReady {
                if attempt == WhisperClient.maxTranscribeAttempts - 1 {
                    throw WhisperError.notReady
                }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 4_000_000_000)
            }
        }
        // Unreachable (the loop either returns or throws), but keeps the
        // compiler happy about exhaustiveness.
        throw WhisperError.notReady
    }

    /// Total attempts (initial + retries) `transcribe` makes on a not-ready
    /// backend before surfacing `.notReady`.
    static let maxTranscribeAttempts = 4

    private func transcribeOnce(
        wavData: Data,
        language: WhisperLanguage
    ) async throws -> TranscribeResponse {
        let request = WhisperRequestFactory.transcribeRequest(
            baseURL: baseURL,
            wavData: wavData,
            language: language
        )
        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.decoding
        }
        // A transcribe before the model has finished loading fails server-side.
        // Map 502 to backendDown; 500 and 503 are the transient not-ready race
        // (the server 500s with "NoneType has no attribute transcribe" when the
        // model is not yet loaded), which the retry loop above rides out.
        if http.statusCode == 502 { throw WhisperError.backendDown }
        if http.statusCode == 500 || http.statusCode == 503 { throw WhisperError.notReady }
        guard (200..<300).contains(http.statusCode) else {
            throw WhisperError.httpStatus(http.statusCode)
        }

        let decoded = try decode(TranscribeResponse.self, from: data)
        // Silence does not come back empty. Whisper answers it with subtitle
        // boilerplate ("Untertitelung des ZDF, 2020"), which the server reports
        // as an ordinary success - so treat it as the no-speech case it is,
        // rather than pasting it into the user's document.
        if SilenceArtifactFilter.isArtifact(decoded.text) { throw WhisperError.emptyText }
        return decoded
    }

    // MARK: - Helpers

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as WhisperError {
            throw error
        } catch {
            throw WhisperError.unreachable(error.localizedDescription)
        }
    }

    private func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.decoding
        }
        if http.statusCode == 502 { throw WhisperError.backendDown }
        guard (200..<300).contains(http.statusCode) else {
            throw WhisperError.httpStatus(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WhisperError.decoding
        }
    }
}
