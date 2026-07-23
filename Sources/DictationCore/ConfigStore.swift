import Foundation

/// Persists `AppConfig`. Abstracted so tests can drive it against an isolated
/// `UserDefaults` suite instead of the real app domain.
public protocol ConfigStore: AnyObject {
    func load() -> AppConfig
    func save(_ config: AppConfig)
}

/// `UserDefaults`-backed store. The whole config is serialized as one JSON blob
/// under a single key, which keeps migrations simple and load/save atomic.
public final class UserDefaultsConfigStore: ConfigStore {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "AppConfig") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .default
        }
        return config
    }

    public func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
