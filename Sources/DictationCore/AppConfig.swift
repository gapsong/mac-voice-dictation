import Foundation

/// How a hold-to-talk key is observed by the global event tap.
///
/// The fn/Globe key is special: it is not reliably identified by a virtual key
/// code, but the system reports it as the `.maskSecondaryFn` (NSEvent
/// `.function`) modifier *flag* on `flagsChanged` events. Left/right modifiers
/// like Right Option, by contrast, share a flag bit with their sibling and so
/// must be told apart by key code. Regular keys arrive via key up/down.
public enum HotkeyTrigger: Codable, Equatable, Hashable, Sendable {
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
public struct HotkeyConfig: Codable, Equatable, Hashable, Sendable {
    public var trigger: HotkeyTrigger
    /// Human-readable label for the menu.
    public var displayName: String

    public init(trigger: HotkeyTrigger, displayName: String) {
        self.trigger = trigger
        self.displayName = displayName
    }

    /// `CGEventFlags.maskSecondaryFn` raw value - the fn/Globe modifier bit.
    public static let fnFlagMask: UInt64 = 0x800000

    /// Hold fn/Globe. Detected via the `.maskSecondaryFn` modifier flag on
    /// `flagsChanged`.
    ///
    /// Only Apple's own keyboards emit this. fn on a third-party keyboard is
    /// almost always resolved inside the keyboard's firmware as a layer switch
    /// and never reaches macOS at all, so this trigger cannot see it - see
    /// `functionKeys` for the portable alternative.
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

    /// Hold F13 (kVK_F13 = 105).
    ///
    /// F13-F19 exist in the USB HID keyboard page but are absent from Apple
    /// keyboards and unbound in macOS, so nothing else competes for them. That
    /// makes F13 the trigger to remap an external keyboard's fn key onto: it
    /// travels over standard HID (unlike Apple's fn), and holding it cannot
    /// disturb typing the way holding a live modifier such as Right Option
    /// would.
    public static let f13 = HotkeyConfig(
        trigger: .regularKey(keyCode: 105), displayName: "F13"
    )

    /// Modifier keys that macOS reports per side, usable as hold-to-talk keys
    /// on any keyboard. Holding one of these suppresses nothing, but it does
    /// double as a live modifier, so a long hold while typing can start a
    /// recording.
    public static let modifierPresets: [HotkeyConfig] = [
        .fnGlobe,
        .rightOption,
        HotkeyConfig(trigger: .modifierKey(keyCode: 58), displayName: "Left Option"),
        HotkeyConfig(trigger: .modifierKey(keyCode: 54), displayName: "Right Command"),
        HotkeyConfig(trigger: .modifierKey(keyCode: 62), displayName: "Right Control"),
    ]

    /// The unbound F13-F19 block. Preferred for external keyboards: remap a key
    /// there (fn, Right Control, whatever is free) onto one of these in the
    /// keyboard's own configurator and the app sees it on every machine.
    public static let functionKeys: [HotkeyConfig] = [
        .f13,
        HotkeyConfig(trigger: .regularKey(keyCode: 107), displayName: "F14"),
        HotkeyConfig(trigger: .regularKey(keyCode: 113), displayName: "F15"),
        HotkeyConfig(trigger: .regularKey(keyCode: 106), displayName: "F16"),
        HotkeyConfig(trigger: .regularKey(keyCode: 64), displayName: "F17"),
        HotkeyConfig(trigger: .regularKey(keyCode: 79), displayName: "F18"),
        HotkeyConfig(trigger: .regularKey(keyCode: 80), displayName: "F19"),
    ]

    /// Every hotkey the user can switch on, in menu order.
    public static let presets: [HotkeyConfig] = modifierPresets + functionKeys
}

/// All persisted, menu-editable settings.
public struct AppConfig: Codable, Equatable, Sendable {
    public var serverBaseURLString: String
    public var language: WhisperLanguage
    /// Every hotkey armed at once. Holding *any* of them records; the hold ends
    /// when that same key is released.
    ///
    /// This is a set rather than a single key because one machine routinely has
    /// keyboards with different capabilities attached at the same time: fn only
    /// ever arrives from an Apple keyboard, so an external keyboard needs its
    /// own trigger, and the user should not have to switch the setting when
    /// they move hands.
    public var hotkeys: [HotkeyConfig]
    public var launchAtLogin: Bool

    public init(
        serverBaseURLString: String,
        language: WhisperLanguage,
        hotkeys: [HotkeyConfig],
        launchAtLogin: Bool
    ) {
        self.serverBaseURLString = serverBaseURLString
        self.language = language
        self.hotkeys = AppConfig.normalized(hotkeys)
        self.launchAtLogin = launchAtLogin
    }

    /// Default server lives on the tailnet; German is the default language to
    /// match the BikeOffice dictation usage.
    public static let defaultServerURL = "https://gpuserver.beaver-brotula.ts.net:9443"

    /// fn/Globe covers the built-in Apple keyboard; F13 covers every external
    /// keyboard once a key is remapped onto it. F13 costs nothing to leave
    /// armed - no physical keyboard sends it unless the user asks it to.
    public static let defaultHotkeys: [HotkeyConfig] = [.fnGlobe, .f13]

    public static let `default` = AppConfig(
        serverBaseURLString: defaultServerURL,
        language: .de,
        hotkeys: defaultHotkeys,
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

    /// Menu label for the armed set: the one name, or a count once there are
    /// several, so the menu title stays short.
    public var hotkeysSummary: String {
        switch hotkeys.count {
        case 0: return "none"
        case 1: return hotkeys[0].displayName
        default: return hotkeys.map(\.displayName).joined(separator: " + ")
        }
    }

    /// Arms or disarms one hotkey. Disarming the last one is refused: with an
    /// empty set the app has no way left to record, which reads as a broken app
    /// rather than a setting.
    public mutating func setHotkey(_ hotkey: HotkeyConfig, enabled: Bool) {
        if enabled {
            guard !hotkeys.contains(hotkey) else { return }
            hotkeys = AppConfig.normalized(hotkeys + [hotkey])
        } else {
            guard hotkeys.count > 1 else { return }
            hotkeys.removeAll { $0 == hotkey }
        }
    }

    /// De-duplicates while keeping the caller's order, and never yields an
    /// empty set.
    static func normalized(_ hotkeys: [HotkeyConfig]) -> [HotkeyConfig] {
        var seen = Set<HotkeyConfig>()
        let unique = hotkeys.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.fnGlobe] : unique
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case serverBaseURLString, language, hotkeys, launchAtLogin
        /// Pre-multi-hotkey key. Read-only, so a config written before this
        /// change still loads and keeps the user's chosen key.
        case hotkey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverBaseURLString = try container.decode(String.self, forKey: .serverBaseURLString)
        language = try container.decode(WhisperLanguage.self, forKey: .language)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)

        if let stored = try container.decodeIfPresent([HotkeyConfig].self, forKey: .hotkeys) {
            hotkeys = AppConfig.normalized(stored)
        } else if let legacy = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) {
            // Migrate: keep what the user picked and add F13 so an external
            // keyboard works without them having to find the new setting.
            hotkeys = AppConfig.normalized([legacy, .f13])
        } else {
            hotkeys = AppConfig.defaultHotkeys
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverBaseURLString, forKey: .serverBaseURLString)
        try container.encode(language, forKey: .language)
        try container.encode(hotkeys, forKey: .hotkeys)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }
}
