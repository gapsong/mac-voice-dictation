import Foundation

/// A capturable hotkey. Modifier keys (Right Option and friends) arrive as
/// `flagsChanged` events and are tracked by key code; regular keys arrive as
/// key up/down. `isModifier` tells the event-tap layer which stream to watch.
public struct HotkeyConfig: Codable, Equatable, Sendable {
    /// Virtual key code (CGKeyCode / kVK_*).
    public var keyCode: UInt16
    /// Whether this key is a modifier (observed via `flagsChanged`).
    public var isModifier: Bool
    /// Human-readable label for the menu.
    public var displayName: String

    public init(keyCode: UInt16, isModifier: Bool, displayName: String) {
        self.keyCode = keyCode
        self.isModifier = isModifier
        self.displayName = displayName
    }

    /// Default hotkey: hold Right Option (kVK_RightOption = 61). Reliably
    /// capturable via a global event tap, unlike fn/Globe.
    public static let rightOption = HotkeyConfig(
        keyCode: 61, isModifier: true, displayName: "Right Option"
    )

    /// A small menu of alternative hold-to-talk keys the user can pick from.
    public static let presets: [HotkeyConfig] = [
        .rightOption,
        HotkeyConfig(keyCode: 58, isModifier: true, displayName: "Left Option"),
        HotkeyConfig(keyCode: 54, isModifier: true, displayName: "Right Command"),
        HotkeyConfig(keyCode: 62, isModifier: true, displayName: "Right Control"),
        HotkeyConfig(keyCode: 63, isModifier: true, displayName: "Fn / Globe"),
    ]
}

/// All persisted, menu-editable settings.
public struct AppConfig: Codable, Equatable, Sendable {
    public var serverBaseURLString: String
    public var language: WhisperLanguage
    public var hotkey: HotkeyConfig
    public var launchAtLogin: Bool

    public init(
        serverBaseURLString: String,
        language: WhisperLanguage,
        hotkey: HotkeyConfig,
        launchAtLogin: Bool
    ) {
        self.serverBaseURLString = serverBaseURLString
        self.language = language
        self.hotkey = hotkey
        self.launchAtLogin = launchAtLogin
    }

    /// Default server lives on the tailnet; German is the default language to
    /// match the BikeOffice dictation usage.
    public static let defaultServerURL = "https://gpuserver.beaver-brotula.ts.net:9443"

    public static let `default` = AppConfig(
        serverBaseURLString: defaultServerURL,
        language: .de,
        hotkey: .rightOption,
        launchAtLogin: false
    )

    /// Parsed base URL, or `nil` if the stored string is malformed.
    public var serverBaseURL: URL? {
        guard let url = URL(string: serverBaseURLString),
              url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }
}
