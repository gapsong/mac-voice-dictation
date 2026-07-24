import Testing
import Foundation
@testable import DictationCore

/// A stub URLProtocol that returns scripted responses so the client's
/// error-mapping and retry logic can be exercised without a real server.
final class StubURLProtocol: URLProtocol {
    /// (statusCode, body) per request, consumed in order. Set before each test.
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.requestCount
        Self.requestCount += 1
        let (status, body): (Int, Data)
        if index < Self.responses.count {
            (status, body) = Self.responses[index]
        } else {
            (status, body) = Self.responses.last ?? (200, Data())
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized because the stub protocol shares process-wide static state.
@Suite(.serialized)
struct WhisperClientBehaviorTests {

    private let baseURL = URL(string: "https://gpuserver.beaver-brotula.ts.net:9443")!

    private func makeClient(_ responses: [(Int, Data)]) -> WhisperClient {
        StubURLProtocol.responses = responses
        StubURLProtocol.requestCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WhisperClient(baseURL: baseURL, session: session)
    }

    @Test func transcribeSuccess() async throws {
        let json = #"{"text":"hallo welt","language":"de","ms":123.4}"#
        let client = makeClient([(200, Data(json.utf8))])

        let result = try await client.transcribe(wavData: Data(), language: .de)
        #expect(result.text == "hallo welt")
        #expect(result.language == "de")
    }

    @Test func transcribeEmptyTextThrows() async {
        let client = makeClient([(200, Data(#"{"text":"   ","language":"de","ms":1}"#.utf8))])
        await #expect(throws: WhisperError.emptyText) {
            _ = try await client.transcribe(wavData: Data(), language: .de)
        }
    }

    @Test func transcribeBackendDownThrows() async {
        let client = makeClient([(502, Data())])
        await #expect(throws: WhisperError.backendDown) {
            _ = try await client.transcribe(wavData: Data(), language: .en)
        }
    }

    @Test func transcribeRetriesOnceWhenNotReady() async throws {
        // First 503 (not ready), then success on the retry.
        let client = makeClient([
            (503, Data()),
            (200, Data(#"{"text":"ok","language":"en","ms":2}"#.utf8)),
        ])
        let result = try await client.transcribe(wavData: Data(), language: .en)
        #expect(result.text == "ok")
        #expect(StubURLProtocol.requestCount == 2)
    }

    @Test func transcribeRetriesOn500ThenSucceeds() async throws {
        // The server 500s ("NoneType has no attribute transcribe") when audio
        // arrives before the model finishes loading. That is the retryable race,
        // not a hard failure - the retry should ride it out.
        let client = makeClient([
            (500, Data()),
            (200, Data(#"{"text":"ready now","language":"en","ms":5}"#.utf8)),
        ])
        let result = try await client.transcribe(wavData: Data(), language: .en)
        #expect(result.text == "ready now")
        #expect(StubURLProtocol.requestCount == 2)
    }

    @Test func transcribeGivesUpAfterBoundedNotReadyRetries() async {
        // Persistent 500s should surface .notReady after a bounded number of
        // attempts rather than looping forever.
        let client = makeClient([(500, Data())])
        await #expect(throws: WhisperError.notReady) {
            _ = try await client.transcribe(wavData: Data(), language: .en)
        }
        #expect(StubURLProtocol.requestCount == WhisperClient.maxTranscribeAttempts)
    }

    @Test func waitUntilReadyReturnsTrueAfterNPolls() async {
        // Two sleeping health responses, then ready: waitUntilReady should poll
        // health three times and report ready.
        let sleeping = Data(#"{"model":"m","state":"sleeping","ready":false}"#.utf8)
        let ready = Data(#"{"model":"m","state":"ready","ready":true}"#.utf8)
        let client = makeClient([
            (200, sleeping),
            (200, sleeping),
            (200, ready),
        ])
        let up = await client.waitUntilReady(timeout: 5, pollInterval: 0.01)
        #expect(up == true)
        #expect(StubURLProtocol.requestCount == 3)
    }

    @Test func waitUntilReadyTimesOutWhenNeverReady() async {
        let sleeping = Data(#"{"model":"m","state":"sleeping","ready":false}"#.utf8)
        let client = makeClient([(200, sleeping)])
        let up = await client.waitUntilReady(timeout: 0.05, pollInterval: 0.01)
        #expect(up == false)
    }

    @Test func waitUntilReadyTreatsStateReadyWithoutFlagAsReady() async {
        // {"state":"ready"} with no `ready` field must still count as ready.
        let client = makeClient([(200, Data(#"{"state":"ready"}"#.utf8))])
        let up = await client.waitUntilReady(timeout: 1, pollInterval: 0.01)
        #expect(up == true)
    }

    @Test func healthDecodes() async throws {
        let client = makeClient([
            (200, Data(#"{"model":"large-v3-turbo","state":"ready","ready":true}"#.utf8)),
        ])
        let health = try await client.health()
        #expect(health.state == .ready)
        #expect(health.ready == true)
        #expect(health.model == "large-v3-turbo")
    }

    @Test func startDecodes() async throws {
        let client = makeClient([
            (200, Data(#"{"model":"large-v3-turbo","state":"ready","ready":true}"#.utf8)),
        ])
        let health = try await client.start()
        #expect(health.state == .ready)
    }
}
