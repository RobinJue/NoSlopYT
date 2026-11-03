import Foundation
import Observation

/// The user's `AppSettings`.
///
/// STUB (Task 1A). Task 6 owns this file and adds persistence into `UserDefaults`. Until then this is a simple,
/// fully working in-memory store: `defaults` and `key` are ignored and the values start at the defaults.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings = AppSettings()

    public init(defaults: UserDefaults = .standard, key: String = "noslop.settings") {}
}
