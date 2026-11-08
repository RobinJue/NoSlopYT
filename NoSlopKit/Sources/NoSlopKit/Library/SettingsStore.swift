import Foundation
import Observation

/// The user's `AppSettings`, kept as one JSON blob in `UserDefaults` and written on every change.
///
/// Reading is forgiving: keys that an older build did not know take their defaults (`AppSettings` decodes every key
/// optionally). A blob that cannot be decoded at all is copied to `<key>.corrupt` before the defaults are used, so
/// the next save never destroys it.
///
/// An app that iOS starts in the background before the first unlock after a restart cannot read its `UserDefaults`
/// yet: the defaults come up, and a save would put them over the real settings. The app says so through
/// `protectedDataAvailable`; such a store saves nothing until `reloadIfNeeded` has read the stored settings again.
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
    /// The settings were read while protected data was unavailable and have not been read since: no saving.
    @ObservationIgnored private var needsReload: Bool
    /// What the first read gave, to tell whether the settings were changed before the second one.
    @ObservationIgnored private var firstRead: AppSettings

    /// - Parameter protectedDataAvailable: false when the app was started before the device was unlocked for the first
    ///   time since the restart (`UIApplication.isProtectedDataAvailable`; the kit does not know UIKit).
    public init(defaults: UserDefaults = .standard, key: String = "noslop.settings", protectedDataAvailable: Bool = true) {
        self.defaults = defaults
        self.key = key
        let loaded = Self.load(from: defaults, key: key, moveAside: protectedDataAvailable)
        self.settings = loaded
        self.firstRead = loaded
        self.needsReload = !protectedDataAvailable
    }

    /// Reads the stored settings again when they were read while protected data was unavailable, and does nothing
    /// otherwise. Call it when the protected data becomes available and when the app becomes active. Settings the viewer
    /// changed in the meantime are newer than the stored ones and are kept (and saved).
    public func reloadIfNeeded(protectedDataAvailable: Bool = true) {
        guard needsReload, protectedDataAvailable else { return }
        let changedMeanwhile = settings != firstRead
        let stored = Self.load(from: defaults, key: key, moveAside: true)
        if changedMeanwhile {
            needsReload = false
            persist()
        } else {
            // Still blocked while `settings` is assigned, so that taking over the stored settings writes nothing.
            settings = stored
            needsReload = false
        }
    }

    // MARK: Persistence

    private func persist() {
        guard !needsReload else { return }
        // An unencodable value (a NaN rate set by a buggy caller) leaves the stored settings as they were.
        guard let data = try? Self.makeEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String, moveAside: Bool) -> AppSettings {
        guard let stored = defaults.object(forKey: key) else { return AppSettings() }
        guard let data = stored as? Data else {
            if moveAside { defaults.set(stored, forKey: key + ".corrupt") }
            return AppSettings()
        }
        do {
            return sanitized(try JSONDecoder().decode(AppSettings.self, from: data))
        } catch {
            if moveAside { defaults.set(data, forKey: key + ".corrupt") }
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
