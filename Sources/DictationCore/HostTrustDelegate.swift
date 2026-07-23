import Foundation

/// URLSession delegate that accepts the whisper server's self-signed TLS
/// certificate, but ONLY for a specific host.
///
/// The reverse proxy at `:9443` presents a certificate the system does not
/// trust (the reference client uses `curl -sk`). Rather than disabling App
/// Transport Security globally, we scope the trust exception to exactly the
/// configured host: any challenge from another host falls through to the
/// default handling, so a compromised/hijacked connection to some other server
/// is still validated normally.
public final class HostTrustDelegate: NSObject, URLSessionDelegate {

    /// Host for which the self-signed certificate is accepted (e.g.
    /// `gpuserver.beaver-brotula.ts.net`).
    private let trustedHost: String

    public init(trustedHost: String) {
        self.trustedHost = trustedHost
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard
            space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            space.host == trustedHost,
            let serverTrust = space.serverTrust
        else {
            // Not our host, or not a server-trust challenge: default handling
            // performs normal certificate validation.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
