import Testing
import Foundation
@testable import DictationCore

@Suite struct AppConfigTests {

    @Test func defaultsMatchContract() {
        let config = AppConfig.default
        #expect(config.serverBaseURLString == "http://127.0.0.1:9876")
        #expect(config.language == .de)
        #expect(config.hotkeys == [.fnGlobe, .f13])
        #expect(config.launchAtLogin == false)
    }

    @Test func defaultArmsFnGlobeAndF13Together() {
        // fn/Globe covers the built-in Apple keyboard. It never arrives from a
        // third-party keyboard, so F13 ships armed as well: nothing else sends
        // F13, so leaving it on costs nothing and one remap makes an external
        // keyboard work.
        #expect(AppConfig.default.hotkeys.contains(.fnGlobe))
        #expect(AppConfig.default.hotkeys.contains(.f13))
        #expect(HotkeyConfig.fnGlobe.trigger == .modifierFlag(mask: 0x800000))
        #expect(HotkeyConfig.fnFlagMask == 0x800000)
        #expect(HotkeyConfig.f13.trigger == .regularKey(keyCode: 105))
    }

    @Test func rightOptionRemainsSelectableFallback() {
        #expect(HotkeyConfig.rightOption.trigger == .modifierKey(keyCode: 61))
        #expect(HotkeyConfig.presets.contains(.fnGlobe))
        #expect(HotkeyConfig.presets.contains(.rightOption))
        // fn/Globe is offered first as the primary default.
        #expect(HotkeyConfig.presets.first == .fnGlobe)
    }

    @Test func presetsCoverTheUnboundFunctionKeyBlock() {
        // F13-F19 are absent from Apple keyboards and unbound in macOS, which
        // is what makes them safe remap targets for an external keyboard.
        let codes = HotkeyConfig.functionKeys.map(\.trigger)
        #expect(codes == [105, 107, 113, 106, 64, 79, 80].map { HotkeyTrigger.regularKey(keyCode: $0) })
        #expect(HotkeyConfig.presets == HotkeyConfig.modifierPresets + HotkeyConfig.functionKeys)
    }

    @Test func presetsHaveNoDuplicateTriggers() {
        let triggers = HotkeyConfig.presets.map(\.trigger)
        #expect(Set(triggers).count == triggers.count)
    }

    // MARK: - Arming and disarming

    @Test func armingAddsAndDisarmingRemoves() {
        var config = AppConfig.default
        config.setHotkey(.rightOption, enabled: true)
        #expect(config.hotkeys.contains(.rightOption))

        config.setHotkey(.rightOption, enabled: false)
        #expect(!config.hotkeys.contains(.rightOption))
    }

    @Test func armingTheSameHotkeyTwiceIsIdempotent() {
        var config = AppConfig.default
        let before = config.hotkeys
        config.setHotkey(.fnGlobe, enabled: true)
        #expect(config.hotkeys == before)
    }

    @Test func disarmingTheLastHotkeyIsRefused() {
        // An empty set leaves no way to record, which reads as a broken app
        // rather than a setting.
        var config = AppConfig.default
        config.setHotkey(.f13, enabled: false)
        #expect(config.hotkeys == [.fnGlobe])

        config.setHotkey(.fnGlobe, enabled: false)
        #expect(config.hotkeys == [.fnGlobe])
    }

    @Test func initNeverYieldsAnEmptySet() {
        let config = AppConfig(
            serverBaseURLString: "https://example.test",
            language: .de,
            hotkeys: [],
            launchAtLogin: false
        )
        #expect(config.hotkeys == [.fnGlobe])
    }

    @Test func initDropsDuplicatesKeepingOrder() {
        let config = AppConfig(
            serverBaseURLString: "https://example.test",
            language: .de,
            hotkeys: [.f13, .fnGlobe, .f13],
            launchAtLogin: false
        )
        #expect(config.hotkeys == [.f13, .fnGlobe])
    }

    @Test func summaryListsEveryArmedHotkey() {
        var config = AppConfig.default
        #expect(config.hotkeysSummary == "Fn / Globe + F13")

        config.setHotkey(.f13, enabled: false)
        #expect(config.hotkeysSummary == "Fn / Globe")
    }

    // MARK: - URL parsing

    @Test func serverBaseURLParsesValid() {
        #expect(AppConfig.default.serverBaseURL != nil)
        #expect(AppConfig.default.serverBaseURL?.host == "127.0.0.1")
        #expect(AppConfig.default.serverBaseURL?.port == 9876)
    }

    @Test func serverBaseURLRejectsMalformed() {
        var config = AppConfig.default
        config.serverBaseURLString = "not a url"
        #expect(config.serverBaseURL == nil)
    }

    // MARK: - Persistence

    @Test func roundTripThroughStore() {
        let suiteName = "AppConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsConfigStore(defaults: defaults, key: "cfg")

        // Fresh store returns defaults.
        #expect(store.load() == .default)

        var config = AppConfig.default
        config.language = .en
        config.launchAtLogin = true
        config.serverBaseURLString = "https://example.test:9443"
        config.hotkeys = [
            HotkeyConfig(trigger: .modifierKey(keyCode: 58), displayName: "Left Option"),
            .f13,
        ]
        store.save(config)

        // A brand-new store instance reads the persisted value.
        let reloaded = UserDefaultsConfigStore(defaults: defaults, key: "cfg").load()
        #expect(reloaded == config)
    }

    @Test func legacySingleHotkeyConfigStillLoads() throws {
        // Configs written before multi-hotkey support store one "hotkey" object.
        // Keep the user's choice and add F13, so an external keyboard works
        // without them having to find the new setting first.
        let legacy = """
        {
          "serverBaseURLString": "https://example.test:9443",
          "language": "en",
          "launchAtLogin": true,
          "hotkey": { "trigger": { "modifierKey": { "keyCode": 61 } }, "displayName": "Right Option" }
        }
        """
        // Encode the legacy hotkey with the same encoder the app uses, so the
        // fixture cannot drift from HotkeyTrigger's real Codable shape.
        let legacyHotkey = HotkeyConfig.rightOption
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any]
        )
        object["hotkey"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacyHotkey)
        )
        let data = try JSONSerialization.data(withJSONObject: object)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.hotkeys == [.rightOption, .f13])
        #expect(config.language == .en)
        #expect(config.launchAtLogin == true)
    }

    @Test func configWithNeitherHotkeyKeyFallsBackToDefaults() throws {
        let json = """
        {
          "serverBaseURLString": "https://example.test:9443",
          "language": "de",
          "launchAtLogin": false
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.hotkeys == AppConfig.defaultHotkeys)
    }

    @Test func encodingDropsTheLegacyKey() throws {
        let data = try JSONEncoder().encode(AppConfig.default)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["hotkeys"] != nil)
        #expect(object["hotkey"] == nil)
    }
}
