import Testing
import Foundation
@testable import DictationCore

@Suite struct AppConfigTests {

    @Test func defaultsMatchContract() {
        let config = AppConfig.default
        #expect(config.serverBaseURLString == "https://gpuserver.beaver-brotula.ts.net:9443")
        #expect(config.language == .de)
        #expect(config.hotkey == .fnGlobe)
        #expect(config.launchAtLogin == false)
    }

    @Test func defaultHotkeyIsFnGlobeViaSecondaryFnFlag() {
        // The default is fn/Globe, detected via the .maskSecondaryFn flag bit.
        #expect(AppConfig.default.hotkey == .fnGlobe)
        #expect(HotkeyConfig.fnGlobe.trigger == .modifierFlag(mask: 0x800000))
        #expect(HotkeyConfig.fnFlagMask == 0x800000)
    }

    @Test func rightOptionRemainsSelectableFallback() {
        #expect(HotkeyConfig.rightOption.trigger == .modifierKey(keyCode: 61))
        #expect(HotkeyConfig.presets.contains(.fnGlobe))
        #expect(HotkeyConfig.presets.contains(.rightOption))
        // fn/Globe is offered first as the primary default.
        #expect(HotkeyConfig.presets.first == .fnGlobe)
    }

    @Test func serverBaseURLParsesValid() {
        #expect(AppConfig.default.serverBaseURL != nil)
        #expect(AppConfig.default.serverBaseURL?.host == "gpuserver.beaver-brotula.ts.net")
        #expect(AppConfig.default.serverBaseURL?.port == 9443)
    }

    @Test func serverBaseURLRejectsMalformed() {
        var config = AppConfig.default
        config.serverBaseURLString = "not a url"
        #expect(config.serverBaseURL == nil)
    }

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
        config.hotkey = HotkeyConfig(trigger: .modifierKey(keyCode: 58), displayName: "Left Option")
        store.save(config)

        // A brand-new store instance reads the persisted value.
        let reloaded = UserDefaultsConfigStore(defaults: defaults, key: "cfg").load()
        #expect(reloaded == config)
    }
}
