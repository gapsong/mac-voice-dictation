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
/// down, empty text, network/timeout, and not-yet-ready-after-`/start` (one
/// short retry). The scoped `HostTrustDelegate` accepts the server's
/// self-signed certificate for the configured host only.
public final class WhisperClient: Sendable {

    private let baseURL: URL
    private let session: URLSession
    private let ownsSession: Bool

    /// - Parameters:
    ///   - baseURL: Server base, e.g. `https://gpuserver...:9443`.
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

    /// `POST /transcribe`. On a not-ready backend, retries once after a short
    /// backoff (the model may still be finishing its wake from `/start`).
    public func transcribe(
        wavData: Data,
        language: WhisperLanguage
    ) async throws -> TranscribeResponse {
        do {
            return try await transcribeOnce(wavData: wavData, language: language)
        } catch WhisperError.notReady {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return try await transcribeOnce(wavData: wavData, language: language)
        }
    }

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
        // A transcribe before the model is ever woken fails server-side: map
        // 502 to backendDown and 503 to notReady (the retryable case).
        if http.statusCode == 502 { throw WhisperError.backendDown }
        if http.statusCode == 503 { throw WhisperError.notReady }
        guard (200..<300).contains(http.statusCode) else {
            throw WhisperError.httpStatus(http.statusCode)
        }

        let decoded = try decode(TranscribeResponse.self, from: data)
        let trimmed = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WhisperError.emptyText }
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
