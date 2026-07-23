import Testing
import Foundation
@testable import DictationCore

/// Opt-in live sanity check against the real whisper server. It validates the
/// full networking path the unit tests can't: the scoped `HostTrustDelegate`
/// accepting the self-signed cert, and `/health` decoding against the live
/// response.
///
/// When the machine is NOT on the tailnet the server is unreachable; the test
/// then skips gracefully rather than failing, per the contract.
@Suite struct LiveHealthSmokeTest {

    @Test func liveHealthOrSkip() async throws {
        let url = URL(string: AppConfig.defaultServerURL)!

        // Short timeout so an off-tailnet run skips quickly instead of hanging.
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
            // healthy response and proves the TLS trust + decoding path works.
            #expect([.sleeping, .ready].contains(health.state))
            #expect(health.model != nil)
            print("Live /health OK: model=\(health.model ?? "?") state=\(health.state.rawValue)")
        } catch WhisperError.unreachable {
            // Not on the tailnet: skip gracefully (a pass, not a failure).
            print("Skipped live /health: server unreachable (not on tailnet)")
        } catch WhisperError.backendDown {
            print("Skipped live /health: proxy up but backend down (502)")
        }
    }
}
