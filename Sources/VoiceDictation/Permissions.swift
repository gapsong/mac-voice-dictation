import AVFoundation
import AppKit
import ApplicationServices

/// Thin wrappers over the two OS permissions the app needs: Microphone (audio
/// capture) and Accessibility (the global event tap and synthetic paste).
enum Permissions {

    // MARK: Microphone

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophone: Bool {
        microphoneStatus == .authorized
    }

    /// Requests microphone access; the completion is delivered on the main queue.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Accessibility

    /// Whether Accessibility (AXIsProcessTrusted) is granted. Without it the
    /// event tap cannot be created and synthetic paste is dropped.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user, once, to grant Accessibility. macOS shows its own
    /// dialog with a deep link to System Settings.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens System Settings at the Accessibility pane so the user can grant it.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings at the Microphone pane.
    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings at the Keyboard pane, where the user can set
    /// "Press Globe key to" -> "Do Nothing" so fn does not also trigger emoji /
    /// input switching while it is used as the dictation hotkey.
    static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!
        NSWorkspace.shared.open(url)
    }
}
