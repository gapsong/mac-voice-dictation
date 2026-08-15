import Foundation

/// Opt-in stderr trace of the hold-to-talk key path.
///
/// "My key does nothing" is the one hotkey failure that cannot be reasoned
/// about from the outside: the key may never reach macOS at all (fn on a
/// third-party keyboard), may arrive under a different key code than expected
/// (a remapped key), or may arrive and be correctly ignored. Those three look
/// identical from the UI, so the app can print what it actually saw.
///
/// Off unless `VOICEDICTATION_LOG_HOTKEYS=1`, and it only ever writes to
/// stderr, so a normal bundle launch is unaffected. Run the binary in the
/// foreground to read it:
///
///     VOICEDICTATION_LOG_HOTKEYS=1 build/VoiceDictation.app/Contents/MacOS/VoiceDictation
public enum HotkeyDiagnostics {

    /// Read once: the environment cannot change under a running process, and
    /// this is consulted per key event.
    public static let isEnabled = ProcessInfo.processInfo.environment["VOICEDICTATION_LOG_HOTKEYS"] == "1"

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[hotkey] \(message())\n".utf8))
    }
}
