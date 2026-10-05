import Testing
import Foundation
@testable import DictationCore

/// Opt-in live sanity check against the default whisper server (the local
/// whisper-service). It validates the full networking path the unit tests
/// can't: the request reaching the server, and `/health` decoding against the
/// live response.
///
/// When the server is not running it is unreachable; the test then skips
/// gracefully rather than failing, per the contract.
@Suite struct LiveHealthSmokeTest {

    @Test func liveHealthOrSkip() async throws {
        let url = URL(string: AppConfig.defaultServerURL)!

        // Short timeout so a run without the server skips quickly instead of hanging.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        let session = URLSession(
            configuration: config,
            delegate: HostTrustDelegate(trustedHost: url.host ?? ""),
            delegateQueue: nil
        )
        let client = WhisperClient(baseURL: url, session: session)

        do {
            let health = try await client.health()
            // The server boots asleep by design; either state is a valid,
            // healthy response and proves the network + decoding path works.
            #expect([.sleeping, .ready].contains(health.state))
            #expect(health.model != nil)
            print("Live /health OK: model=\(health.model ?? "?") state=\(health.state.rawValue)")
        } catch WhisperError.unreachable {
            // Server not running: skip gracefully (a pass, not a failure).
            print("Skipped live /health: server unreachable (whisper-service not running?)")
        } catch WhisperError.backendDown {
            print("Skipped live /health: proxy up but backend down (502)")
        }
    }
}
