import Foundation
import Observation
import Testing
@testable import NoSlopKit

/// Set from an observation callback, read by the test.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var isSet: Bool {
        lock.withLock { changed }
    }

    func set() {
        lock.withLock { changed = true }
    }
}

@MainActor
@Suite final class SettingsStoreTests {
    private static let key = "noslop.settings"

    /// A defaults suite of its own per test (never `.standard`). Its name is a path inside a temporary directory of
    /// its own, which puts the suite's plist there, and removing the directory afterwards removes everything.
    ///
    /// A suite with a plain name would leave an empty `<name>.plist` in `~/Library/Preferences` for every test:
    /// `removePersistentDomain` does not remove it, and the preferences daemon writes it again about ten seconds
    /// after a test deleted it, which no cleanup in the test can wait for.
    private let directory: URL
    private let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: directory.appendingPathComponent("defaults").path))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(key: String = SettingsStoreTests.key) -> SettingsStore {
        SettingsStore(defaults: defaults, key: key)
    }

    private func stored(_ json: String, key: String = SettingsStoreTests.key) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: From the plan

    /// Review Focus #5 (testDecodesEmptySettingsObjectToDefaults).
    @Test func decodesEmptySettingsObjectToDefaults() {
        stored("{}")
        #expect(store().settings == AppSettings())
    }

    @Test func decodesOldSettingsMissingNewKeys() {
        stored(#"{"hideShorts":false}"#)

        var expected = AppSettings()
        expected.hideShorts = false
        let settings = store().settings

        #expect(!settings.hideShorts)
        #expect(settings == expected)
    }

    @Test func persistsOnChange() {
        let first = store()
        #expect(!first.settings.autoplayNext)
        first.settings.autoplayNext = true

        #expect(store().settings.autoplayNext)
    }

    // MARK: More persistence

    @Test func changesAreObservableForTheViews() {
        let first = store()
        let flag = ChangeFlag()
        withObservationTracking {
            _ = first.settings.autoplayNext
        } onChange: {
            flag.set()
        }

        first.settings.autoplayNext = true

        #expect(flag.isSet)
    }

    @Test func aFreshStoreHasTheDefaultsAndWritesNothing() {
        #expect(store().settings == AppSettings())
        #expect(defaults.object(forKey: Self.key) == nil)
    }

    @Test func everyKindOfValueSurvivesARestart() {
        let first = store()
        first.settings.hideShorts = false
        first.settings.hideLiveAndUpcoming = true
        first.settings.hideWatchedInSubscriptions = true
        first.settings.blockedChannels = [BlockedChannel(id: "UC1", name: "One"), BlockedChannel(id: "UC2", name: "Two")]
        first.settings.blockedKeywords = ["minecraft", "reaction"]
        first.settings.sponsorBlockEnabled = false
        first.settings.segmentBehaviors[.intro] = .autoSkip
        first.settings.segmentBehaviors[.sponsor] = .ignore
        first.settings.deArrowTitles = false
        first.settings.wifiQuality = .p1080
        first.settings.cellularQuality = .p360
        first.settings.defaultPlaybackRate = 1.75
        first.settings.backgroundPlayback = false
        first.settings.autoPictureInPicture = false
        first.settings.preferredCaptionLanguage = "de"
        first.settings.googleClientID = "123-abc.apps.googleusercontent.com"
        first.settings.contentLanguage = "de"
        first.settings.contentRegion = "AT"

        let reloaded = store().settings

        #expect(reloaded == first.settings)
        #expect(reloaded.segmentBehaviors[.intro] == .autoSkip)
        #expect(reloaded.segmentBehaviors[.sponsor] == .ignore)
        #expect(reloaded.segmentBehaviors[.outro] == .showInBar)
        #expect(reloaded.blockedChannels.map(\.id) == ["UC1", "UC2"])
    }

    @Test func storesWithDifferentKeysAreIndependent() {
        let first = store(key: "a")
        let second = store(key: "b")
        first.settings.autoplayNext = true

        #expect(!second.settings.autoplayNext)
        #expect(store(key: "a").settings.autoplayNext)
        #expect(!store(key: "b").settings.autoplayNext)
    }

    @Test func settingTheSameValueAgainDoesNotWrite() {
        let first = store()
        first.settings.autoplayNext = true
        defaults.removeObject(forKey: Self.key)

        first.settings.autoplayNext = true
        #expect(defaults.object(forKey: Self.key) == nil)

        first.settings.autoplayNext = false
        #expect(defaults.object(forKey: Self.key) != nil)
    }

    // MARK: Old and damaged data

    @Test func unknownKeysAndPartialBehaviorsAreTolerated() {
        stored(#"{"someFutureKey":[1,2,3],"autoplayNext":true,"segmentBehaviors":{"sponsor":"ignore","bogus":"autoSkip","intro":"nonsense"}}"#)

        let settings = store().settings

        #expect(settings.autoplayNext)
        #expect(settings.segmentBehaviors[.sponsor] == .ignore)
        #expect(settings.segmentBehaviors[.intro] == .showInBar)
        #expect(settings.segmentBehaviors[.selfpromo] == .autoSkip)
        #expect(defaults.object(forKey: Self.key + ".corrupt") == nil)
    }

    @Test func aDamagedBlobFallsBackToDefaultsAndIsKeptAside() {
        stored("{garbage")

        let first = store()
        #expect(first.settings == AppSettings())
        #expect(defaults.data(forKey: Self.key + ".corrupt") == Data("{garbage".utf8))

        // The next change replaces the damaged value but not the preserved copy.
        first.settings.autoplayNext = true
        #expect(store().settings.autoplayNext)
        #expect(defaults.data(forKey: Self.key + ".corrupt") == Data("{garbage".utf8))
    }

    @Test func aWronglyTypedValueOnlyResetsThatSetting() {
        stored(#"{"hideShorts":"yes","autoplayNext":true,"blockedKeywords":["minecraft"]}"#)

        var expected = AppSettings()
        expected.autoplayNext = true
        expected.blockedKeywords = ["minecraft"]
        let settings = store().settings

        // "hideShorts" is back to its default (on); the readable settings around it are kept.
        #expect(settings.hideShorts)
        #expect(settings == expected)
        // The document itself is fine, so nothing is moved aside.
        #expect(defaults.object(forKey: Self.key + ".corrupt") == nil)
    }

    @Test func aBlobThatIsNotAnObjectIsDamagedAndKeptAside() {
        stored("[1,2,3]")

        #expect(store().settings == AppSettings())
        #expect(defaults.data(forKey: Self.key + ".corrupt") == Data("[1,2,3]".utf8))
    }

    @Test func aValueThatIsNotDataIsKeptAsideToo() {
        defaults.set("just a string", forKey: Self.key)

        #expect(store().settings == AppSettings())
        #expect(defaults.string(forKey: Self.key + ".corrupt") == "just a string")
    }

    @Test(arguments: ["0", "-1", "100", "0.1"])
    func anUnusablePlaybackRateFallsBackToTheDefault(rate: String) {
        // Rate 0 would leave the player paused; the other values are outside what the player supports.
        stored(#"{"defaultPlaybackRate":\#(rate),"autoplayNext":true}"#)

        let settings = store().settings

        #expect(settings.defaultPlaybackRate == AppSettings().defaultPlaybackRate)
        #expect(settings.autoplayNext, "the rest of the settings is kept")
    }

    @Test(arguments: ["0.25", "0.5", "1.5", "2", "4"])
    func aSensiblePlaybackRateIsKept(rate: String) {
        stored(#"{"defaultPlaybackRate":\#(rate)}"#)
        #expect(store().settings.defaultPlaybackRate == Double(rate))
    }
    // MARK: A launch before the first unlock (concurrency-1)

    @Test func settingsReadWhileProtectedDataWasUnavailableAreReadAgainAndNotSavedOver() {
        // The defaults could not be read at launch (empty here), and become readable afterwards.
        let locked = SettingsStore(defaults: defaults, key: Self.key, protectedDataAvailable: false)
        #expect(locked.settings == AppSettings())
        let original = #"{"autoplayNext":true,"contentRegion":"DE"}"#
        stored(original)

        locked.reloadIfNeeded(protectedDataAvailable: false)
        #expect(locked.settings == AppSettings(), "still locked: nothing to read yet")

        locked.reloadIfNeeded(protectedDataAvailable: true)
        #expect(locked.settings.autoplayNext)
        #expect(locked.settings.contentRegion == "DE")
        #expect(defaults.data(forKey: Self.key) == Data(original.utf8), "taking the stored settings over writes nothing")
    }

    @Test func aChangeMadeBeforeTheSettingsWereReadAgainIsKeptAndSavedAfterwards() throws {
        let locked = SettingsStore(defaults: defaults, key: Self.key, protectedDataAvailable: false)
        let original = #"{"autoplayNext":true}"#
        stored(original)

        locked.settings.hideShorts = false
        #expect(defaults.data(forKey: Self.key) == Data(original.utf8), "nothing is saved before the stored settings were read")

        locked.reloadIfNeeded()
        #expect(!locked.settings.hideShorts, "the viewer's change is newer than the stored settings")
        let saved = try JSONDecoder().decode(AppSettings.self, from: try #require(defaults.data(forKey: Self.key)))
        #expect(!saved.hideShorts)

        #expect(locked.settings.autoplayNext, "the other stored settings are not replaced by defaults")
        #expect(saved.autoplayNext, "and they stay in what is saved")

        locked.settings.backgroundPlayback = false
        let later = try JSONDecoder().decode(AppSettings.self, from: try #require(defaults.data(forKey: Self.key)))
        #expect(!later.backgroundPlayback, "saving works again")
        #expect(later.autoplayNext)
    }

    @Test func aChangeToAnOptionalSettingBeforeTheReadAgainWinsOverTheStoredValueAndLeavesTheRest() throws {
        let locked = SettingsStore(defaults: defaults, key: Self.key, protectedDataAvailable: false)
        stored(#"{"autoplayNext":true,"contentRegion":"FR","blockedKeywords":["a"]}"#)

        locked.settings.contentRegion = "DE"
        locked.settings.contentLanguage = "de"
        locked.reloadIfNeeded()

        #expect(locked.settings.contentRegion == "DE", "the viewer's value wins over the stored one")
        #expect(locked.settings.contentLanguage == "de")
        #expect(locked.settings.autoplayNext)
        #expect(locked.settings.blockedKeywords == ["a"])
    }

    @Test func aStoreThatWasNotLockedSavesAndNeverReadsAgain() throws {
        let normal = store()
        normal.settings.autoplayNext = true
        stored(#"{"contentRegion":"FR"}"#)

        normal.reloadIfNeeded()

        #expect(normal.settings.autoplayNext, "nothing is read again")
        #expect(normal.settings.contentRegion == nil)
    }
}
