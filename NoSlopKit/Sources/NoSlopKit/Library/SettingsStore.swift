import Foundation
import Observation

/// The user's `AppSettings`, kept as one JSON blob in `UserDefaults` and written on every change.
///
/// Reading is forgiving: keys that an older build did not know take their defaults (`AppSettings` decodes every key
/// optionally). A blob that cannot be decoded at all is copied to `<key>.corrupt` before the defaults are used, so
/// the next save never destroys it.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            if settings != oldValue { persist() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "noslop.settings") {
        self.defaults = defaults
        self.key = key
        self.settings = Self.load(from: defaults, key: key)
    }

    // MARK: Persistence

    private func persist() {
        // An unencodable value (a NaN rate set by a buggy caller) leaves the stored settings as they were.
        guard let data = try? Self.makeEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> AppSettings {
        guard let stored = defaults.object(forKey: key) else { return AppSettings() }
        guard let data = stored as? Data else {
            defaults.set(stored, forKey: key + ".corrupt")
            return AppSettings()
        }
        do {
            return sanitized(try JSONDecoder().decode(AppSettings.self, from: data))
        } catch {
            defaults.set(data, forKey: key + ".corrupt")
            return AppSettings()
        }
    }

    /// Values that decode fine but would break playback are replaced by their defaults.
    private static func sanitized(_ settings: AppSettings) -> AppSettings {
        var settings = settings
        // A rate of 0 would leave the player paused; the player supports 0.25x to 4x (NaN fails both comparisons).
        if !(settings.defaultPlaybackRate >= 0.25 && settings.defaultPlaybackRate <= 4) {
            settings.defaultPlaybackRate = AppSettings().defaultPlaybackRate
        }
        return settings
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
