import Testing
import Foundation
@testable import DictationCore

@Suite struct WhisperRequestFactoryTests {

    private let baseURL = URL(string: "https://gpuserver.beaver-brotula.ts.net:9443")!

    @Test func healthRequestShape() {
        let request = WhisperRequestFactory.healthRequest(baseURL: baseURL)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://gpuserver.beaver-brotula.ts.net:9443/health")
        #expect(request.httpBody == nil)
    }

    @Test func startRequestShape() {
        let request = WhisperRequestFactory.startRequest(baseURL: baseURL)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://gpuserver.beaver-brotula.ts.net:9443/start")
    }

    @Test func transcribeRequestShape() {
        let wav = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let request = WhisperRequestFactory.transcribeRequest(
            baseURL: baseURL,
            wavData: wav,
            language: .de
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://gpuserver.beaver-brotula.ts.net:9443/transcribe")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(request.value(forHTTPHeaderField: "X-Language") == "de")
        #expect(request.httpBody == wav)
    }

    @Test func transcribeLanguageHeaderVaries() {
        for language in WhisperLanguage.allCases {
            let request = WhisperRequestFactory.transcribeRequest(
                baseURL: baseURL,
                wavData: Data(),
                language: language
            )
            #expect(request.value(forHTTPHeaderField: "X-Language") == language.rawValue)
        }
    }

    @Test func baseURLWithTrailingPathIsPreserved() {
        let prefixed = URL(string: "https://example.test:9443/api")!
        let request = WhisperRequestFactory.healthRequest(baseURL: prefixed)
        #expect(request.url?.absoluteString == "https://example.test:9443/api/health")
    }
}
