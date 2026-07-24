import AppKit
import DictationCore
import os

/// Orchestrates the whole push-to-talk flow: permissions, audio capture, server
/// wake, transcription, and text insertion. Owns the mutable app config and
/// rebuilds the whisper client when the server URL changes.
@MainActor
final class DictationController {

    private let log = Logger(subsystem: "com.firstmate.VoiceDictation", category: "Dictation")

    private let store: ConfigStore
    private(set) var config: AppConfig

    private let audio = AudioCapture()
    private var client: WhisperClient

    /// Fan-out of status changes to every UI surface that reflects it: the
    /// menu-bar icon, the on-screen overlay, and the settings window. A list
    /// (not a single closure) so all three stay in sync off one state model.
    private var statusObservers: [(AppStatus) -> Void] = []
    private(set) var status: AppStatus = .idle {
        didSet { statusObservers.forEach { $0(status) } }
    }

    /// Registers an observer for status changes and immediately delivers the
    /// current status so the caller can render its initial state.
    func observeStatus(_ observer: @escaping (AppStatus) -> Void) {
        statusObservers.append(observer)
        observer(status)
    }

    private var transcribeTask: Task<Void, Never>?

    init(store: ConfigStore) {
        self.store = store
        let config = store.load()
        self.config = config
        self.client = DictationController.makeClient(for: config)
    }

    private static func makeClient(for config: AppConfig) -> WhisperClient {
        let url = config.serverBaseURL ?? URL(string: AppConfig.defaultServerURL)!
        return WhisperClient(baseURL: url)
    }

    // MARK: - Recording lifecycle

    /// Hotkey pressed: begin recording and proactively warm the model.
    func beginRecording() {
        guard status == .idle || isErrorLike(status) else { return }

        guard Permissions.hasMicrophone else {
            status = .needsPermission("Microphone")
            return
        }
        guard Permissions.hasAccessibility else {
            status = .needsPermission("Accessibility")
            return
        }

        do {
            try audio.start()
        } catch {
            status = .error("Mic unavailable")
            log.error("audio.start failed: \(error.localizedDescription)")
            return
        }
        status = .recording

        // Fire /start so the model warms while the user is still speaking. We
        // ignore the result here; transcribe() handles a still-waking backend.
        let client = self.client
        Task.detached {
            _ = try? await client.start()
        }
    }

    /// Hotkey released. `committed` is false for an accidental sub-debounce tap.
    func endRecording(committed: Bool) {
        guard status == .recording else {
            // Nothing was recording (e.g. blocked on permission); reset the tap.
            _ = audio.stop()
            return
        }

        let wav = audio.stop()

        guard committed, let wav, !wav.isEmpty else {
            status = .idle
            return
        }

        status = .transcribing
        let client = self.client
        let language = config.language

        transcribeTask = Task { [weak self] in
            do {
                let response = try await client.transcribe(wavData: wav, language: language)
                self?.handleTranscription(response.text)
            } catch let error as WhisperError {
                self?.status = .error(error.userMessage)
                self?.log.error("transcribe failed: \(error.userMessage)")
            } catch {
                self?.status = .error("Transcription failed")
                self?.log.error("transcribe failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .error("No speech detected")
            return
        }
        status = .inserting
        TextInserter.insert(trimmed)
        // Give the paste a beat, then return to idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if case .inserting = self?.status { self?.status = .idle }
        }
    }

    private func isErrorLike(_ status: AppStatus) -> Bool {
        switch status {
        case .error, .needsPermission: return true
        default: return false
        }
    }

    // MARK: - Health check

    /// Runs a `/health` probe and reports a human-readable line (used by the
    /// menu's "Check server" action).
    func checkServer() async -> String {
        do {
            let health = try await client.health()
            return "Server: \(health.state.rawValue)\(health.ready ? " (ready)" : "") - \(health.model ?? "?")"
        } catch let error as WhisperError {
            return error.userMessage
        } catch {
            return "Server unreachable"
        }
    }

    // MARK: - Config mutation

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        var updated = config
        mutate(&updated)
        let urlChanged = updated.serverBaseURLString != config.serverBaseURLString
        config = updated
        store.save(updated)
        if urlChanged {
            client = DictationController.makeClient(for: updated)
        }
    }

    /// Reset a transient error back to idle (e.g. after the user acts on it).
    func clearError() {
        if isErrorLike(status) { status = .idle }
    }

    /// Surface that the global hotkey cannot arm until Accessibility is granted.
    func beginNeedsAccessibility() {
        status = .needsPermission("Accessibility")
    }
}
