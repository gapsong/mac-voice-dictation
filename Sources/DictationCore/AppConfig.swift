import Foundation

/// How a hold-to-talk key is observed by the global event tap.
///
/// The fn/Globe key is special: it is not reliably identified by a virtual key
/// code, but the system reports it as the `.maskSecondaryFn` (NSEvent
/// `.function`) modifier *flag* on `flagsChanged` events. Left/right modifiers
/// like Right Option, by contrast, share a flag bit with their sibling and so
/// must be told apart by key code. Regular keys arrive via key up/down.
public enum HotkeyTrigger: Codable, Equatable, Sendable {
    /// A `CGEventFlags` modifier bit observed on `flagsChanged` (e.g. fn/Globe
    /// via `.maskSecondaryFn` = `0x800000`). Detected by the flag's rising and
    /// falling edge, since the flag - not a key code - identifies the key.
    case modifierFlag(mask: UInt64)
    /// A modifier key identified by virtual key code, observed on
    /// `flagsChanged` (e.g. Right Option, whose flag bit does not distinguish
    /// side).
    case modifierKey(keyCode: UInt16)
    /// A regular key observed via `keyDown`/`keyUp`.
    case regularKey(keyCode: UInt16)
}

/// A capturable hold-to-talk hotkey: how to detect it, plus a display label.
public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var trigger: HotkeyTrigger
    /// Human-readable label for the menu.
    public var displayName: String

    public init(trigger: HotkeyTrigger, displayName: String) {
        self.trigger = trigger
        self.displayName = displayName
    }

    /// `CGEventFlags.maskSecondaryFn` raw value - the fn/Globe modifier bit.
    public static let fnFlagMask: UInt64 = 0x800000

    /// Default hotkey: hold fn/Globe. Detected via the `.maskSecondaryFn`
    /// modifier flag on `flagsChanged`.
    ///
    /// Note: the user should set System Settings > Keyboard > "Press Globe key
    /// to" -> "Do Nothing" so fn does not also trigger emoji / input switching
    /// while dictating.
    public static let fnGlobe = HotkeyConfig(
        trigger: .modifierFlag(mask: fnFlagMask), displayName: "Fn / Globe"
    )

    /// Hold Right Option (kVK_RightOption = 61).
    public static let rightOption = HotkeyConfig(
        trigger: .modifierKey(keyCode: 61), displayName: "Right Option"
    )

    /// A small menu of alternative hold-to-talk keys the user can pick from.
    public static let presets: [HotkeyConfig] = [
        .fnGlobe,
        .rightOption,
        HotkeyConfig(trigger: .modifierKey(keyCode: 58), displayName: "Left Option"),
        HotkeyConfig(trigger: .modifierKey(keyCode: 54), displayName: "Right Command"),
        HotkeyConfig(trigger: .modifierKey(keyCode: 62), displayName: "Right Control"),
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
        hotkey: .fnGlobe,
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
