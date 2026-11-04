import Foundation
import Testing
@testable import NoSlopKit

// `downloads.json` that exists but cannot be read (data protection before the first unlock after a restart, an I/O
// error) is not an empty list. The library files have the same rule (`JSONFileStore`): a read failure leaves the file
// alone and nothing may write over it. For downloads, treating it as empty also meant that every `.work/<id>` directory
// (all partial downloads) was deleted as an orphan and the session's running tasks were cancelled as unknown.

@MainActor
@Suite struct DownloadListProtectionTests {
    private static let completedID = "aaaaaaaaaaa-720"
    private static let pausedID = "bbbbbbbbbbb-audio"
    private static let newVideo = VideoSummary(id: "ccccccccccc", title: "New")
    private static let newID = "ccccccccccc-audio"

    /// A downloads folder as the last run left it: a finished download with its file, and a paused one with its plan
    /// and one part on disk.
    private struct Folder {
        let directory: DownloadTestDirectory
        let root: URL
        let list: URL
        let originalList: Data
        let pausedWork: URL

        var pausedPart: URL { pausedWork.appendingPathComponent("audio.0.part") }

        func setListPermissions(_ mode: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: list.path)
        }
    }

    private func makeFolder() throws -> Folder {
        let directory = try DownloadTestDirectory.make()
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(count: 1_000).write(to: root.appendingPathComponent("Done [aaaaaaaaaaa].mp4"))
        let completed = DownloadItem(
            id: Self.completedID, video: VideoSummary(id: "aaaaaaaaaaa", title: "Done"), quality: .video(maxHeight: 720),
            state: .completed, progress: 1, bytesDownloaded: 1_000, bytesTotal: 1_000, relativeFilePath: "Done [aaaaaaaaaaa].mp4"
        )
        let paused = DownloadItem(
            id: Self.pausedID, video: VideoSummary(id: "bbbbbbbbbbb", title: "Paused"), quality: .audioOnly,
            state: .paused, bytesDownloaded: 5_000, bytesTotal: ZooFixture.audioBytes
        )

        let workspace = DownloadWorkspace(root: root)
        let plan = DownloadJobPlan(
            itemID: Self.pausedID, videoID: "bbbbbbbbbbb", title: "Paused", video: nil,
            audio: ZooFixture.audio(at: URL(string: "https://example.invalid/a")!),
            durationSeconds: 19, chunkSize: 100_000, fileExtension: "m4a"
        )
        try workspace.savePlan(plan)
        try Data(count: 100_000).write(to: workspace.partURL(for: DownloadTaskDescriptor(itemID: Self.pausedID, stream: .audio, chunkIndex: 0)))

        let list = root.appendingPathComponent("downloads.json")
        try JSONEncoder().encode([paused, completed]).write(to: list)
        return Folder(directory: directory, root: root, list: list, originalList: try Data(contentsOf: list), pausedWork: workspace.directory(for: Self.pausedID))
    }

    private func offlineManager(root: URL) -> DownloadManager {
        DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("offline") }, tuning: .testing)
    }

    // MARK: The list cannot be read

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func anUnreadableListIsNeitherPrunedNorOverwritten() async throws {
        let folder = try makeFolder()
        defer {
            try? folder.setListPermissions(0o644)
            folder.directory.remove()
        }
        try folder.setListPermissions(0o000)

        let manager = offlineManager(root: folder.root)
        #expect(manager.items.isEmpty, "nothing can be shown until the list can be read")
        // The launch used to move every work directory to the trash right here, as orphans of an empty list.
        #expect(FileManager.default.fileExists(atPath: folder.pausedWork.appendingPathComponent("job.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.pausedPart.path))
        try await Task.sleep(for: .milliseconds(150))   // the launch's look at the session has run by now
        #expect(FileManager.default.fileExists(atPath: folder.pausedPart.path))

        // A download started meanwhile (it fails here, offline) must not replace the list on disk with a list of one.
        manager.enqueue(video: Self.newVideo, quality: .audioOnly)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, Self.newID) })
        try folder.setListPermissions(0o644)
        #expect(try Data(contentsOf: folder.list) == folder.originalList, "the list on disk is exactly what it was")
        #expect(!FileManager.default.fileExists(atPath: folder.root.appendingPathComponent("downloads.json.corrupt").path))
        #expect(FileManager.default.fileExists(atPath: folder.pausedPart.path))
    }

    // MARK: The list can be read again

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func theListComesBackOnceItCanBeRead() async throws {
        let folder = try makeFolder()
        defer {
            try? folder.setListPermissions(0o644)
            folder.directory.remove()
        }
        try folder.setListPermissions(0o000)
        let manager = offlineManager(root: folder.root)
        manager.enqueue(video: Self.newVideo, quality: .audioOnly)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, Self.newID) })
        #expect(manager.items.map(\.id) == [Self.newID])

        // Still closed: reading it again changes nothing.
        manager.reloadIfUnreadable()
        #expect(manager.items.map(\.id) == [Self.newID])

        // Unlocked: the items of the last run are back, the new one first, and the launch's housekeeping is done.
        try folder.setListPermissions(0o644)
        #expect(try Data(contentsOf: folder.list) == folder.originalList, "nothing was written over the list meanwhile")
        manager.reloadIfUnreadable()
        #expect(manager.items.map(\.id) == [Self.newID, Self.pausedID, Self.completedID])
        #expect(manager.items.map(\.state) == [.failed, .paused, .completed])
        // The paused item shows what is really on disk.
        #expect(await awaitDownloadCondition { manager.items.first { $0.id == Self.pausedID }?.bytesDownloaded == 100_000 })
        #expect(FileManager.default.fileExists(atPath: folder.pausedPart.path), "its parts were not deleted as orphans")

        // The list on disk has all three now.
        let reopened = offlineManager(root: folder.root)
        #expect(reopened.items.map(\.id) == [Self.newID, Self.pausedID, Self.completedID])

        // Done: calling it again is harmless.
        manager.reloadIfUnreadable()
        #expect(manager.items.map(\.id) == [Self.newID, Self.pausedID, Self.completedID])
    }

    @Test(.enabled(if: getuid() != 0, "the root user can read any file"))
    func addingADownloadReadsTheListAgainFirst() async throws {
        let folder = try makeFolder()
        defer {
            try? folder.setListPermissions(0o644)
            folder.directory.remove()
        }
        try folder.setListPermissions(0o000)
        let manager = offlineManager(root: folder.root)
        #expect(manager.items.isEmpty)

        // The files can be opened by now, and nobody has told the manager. A download of something that is already
        // there must find it instead of starting a second one.
        try folder.setListPermissions(0o644)
        manager.enqueue(video: VideoSummary(id: "aaaaaaaaaaa", title: "Done"), quality: .video(maxHeight: 720))
        #expect(manager.items.map(\.id) == [Self.pausedID, Self.completedID])
        #expect(manager.items.map(\.state) == [.paused, .completed], "the finished download is left alone")
    }

    // MARK: The list is not there

    @Test func aMissingListIsAnEmptyListAndTheFirstSaveCreatesIt() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // The first launch has no list, so a work directory is an orphan and goes, as before.
        let orphan = DownloadWorkspace(root: root).directory(for: "zzzzzzzzzzz-720")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: orphan.appendingPathComponent("video.0.part"))

        let manager = offlineManager(root: root)
        #expect(manager.items.isEmpty)
        #expect(await awaitDownloadCondition { !FileManager.default.fileExists(atPath: orphan.path) })

        let list = root.appendingPathComponent("downloads.json")
        #expect(!FileManager.default.fileExists(atPath: list.path))
        manager.enqueue(video: Self.newVideo, quality: .audioOnly)
        #expect(FileManager.default.fileExists(atPath: list.path), "the first save creates the file")
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, Self.newID) })
        #expect(offlineManager(root: root).items.map(\.id) == [Self.newID])
    }
}

// MARK: - The file store

@Suite struct DownloadItemStoreTests {
    private let item = DownloadItem(
        id: "aaaaaaaaaaa-720", video: VideoSummary(id: "aaaaaaaaaaa", title: "A"), quality: .video(maxHeight: 720), state: .failed
    )

    private func makeDirectory() throws -> DownloadTestDirectory {
        try DownloadTestDirectory.make()
    }

    private func write(_ items: [DownloadItem], to url: URL) throws -> Data {
        let data = try JSONEncoder().encode(items)
        try data.write(to: url)
        return data
    }

    /// A reader that can be told to fail, for a store that has to survive what a locked or failing device does.
    private final class SwitchableReader: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: (any Error)?

        init(failingWith failure: (any Error)?) {
            self.failure = failure
        }

        func fail(with failure: (any Error)?) {
            lock.withLock { self.failure = failure }
        }

        func read(_ url: URL) throws -> Data {
            if let failure = lock.withLock({ failure }) { throw failure }
            return try Data(contentsOf: url)
        }
    }

    struct ReadFailure: Sendable, CustomTestStringConvertible {
        var name: String
        var error: any Error
        var testDescription: String { name }
    }

    private static let readFailures: [ReadFailure] = [
        ReadFailure(name: "no permission", error: CocoaError(.fileReadNoPermission)),
        ReadFailure(name: "unknown read error", error: CocoaError(.fileReadUnknown)),
        ReadFailure(name: "I/O error", error: POSIXError(.EIO)),
        // What an iPhone reports for a protected file before the first unlock: no permission, caused by EPERM.
        ReadFailure(
            name: "data protection",
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            ])
        ),
        ReadFailure(name: "some other error", error: NoSlopError.network("weird")),
    ]

    @Test(arguments: readFailures)
    func aReadFailureNeitherEmptiesTheListNorLetsAnythingOverwriteIt(_ failure: ReadFailure) throws {
        let directory = try makeDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("downloads.json")
        let original = try write([item], to: url)
        let reader = SwitchableReader(failingWith: failure.error)
        let store = DownloadItemStore(fileURL: url, read: { try reader.read($0) })

        #expect(store.load() == .unreadable)

        // The file is neither replaced nor moved aside, however often the manager saves meanwhile.
        store.save([])
        store.save([item, item])
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))

        // Once a load of the file succeeds, saving works again.
        reader.fail(with: nil)
        #expect(store.load() == .items([item]))
        store.save([])
        #expect(store.load() == .items([]))
    }

    @Test func theProtectionLastsUntilALoadOfThatFileSucceedsWhicheverStoreDoesIt() throws {
        let directory = try makeDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("downloads.json")
        let original = try write([item], to: url)
        let failing = DownloadItemStore(fileURL: url, read: { _ in throw CocoaError(.fileReadNoPermission) })
        #expect(failing.load() == .unreadable)

        // A store that never loaded the file is just as unable to overwrite it.
        let other = DownloadItemStore(fileURL: url)
        other.save([])
        #expect(try Data(contentsOf: url) == original)

        // A successful load of another file does not lift it.
        let elsewhere = directory.url.appendingPathComponent("elsewhere.json")
        _ = try write([], to: elsewhere)
        #expect(DownloadItemStore(fileURL: elsewhere).load() == .items([]))
        other.save([])
        #expect(try Data(contentsOf: url) == original)

        // A successful load of this one does.
        #expect(other.load() == .items([item]))
        other.save([])
        #expect(other.load() == .items([]))
    }

    struct MissingFileError: Sendable, CustomTestStringConvertible {
        var name: String
        var error: any Error
        var testDescription: String { name }
    }

    @Test(arguments: [
        MissingFileError(name: "no such file to read", error: CocoaError(.fileReadNoSuchFile)),
        MissingFileError(name: "no such file", error: CocoaError(.fileNoSuchFile)),
        MissingFileError(name: "ENOENT", error: POSIXError(.ENOENT)),
        MissingFileError(
            name: "ENOENT underneath",
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            ])
        ),
    ])
    func aFileThatIsNotThereIsAFirstLaunchNotAReadFailure(_ missing: MissingFileError) throws {
        let directory = try makeDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("downloads.json")
        let store = DownloadItemStore(fileURL: url, read: { _ in throw missing.error })

        #expect(store.load() == .items([]))
        // Nothing to protect: the first save creates the file.
        store.save([item])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(DownloadItemStore(fileURL: url).load() == .items([item]))
    }

    @Test func aDamagedFileIsStillMovedAsideAndAnEmptyListComesBack() throws {
        let directory = try makeDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("downloads.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)

        let store = DownloadItemStore(fileURL: url)
        #expect(store.load() == .items([]))
        #expect(try Data(contentsOf: url.appendingPathExtension("corrupt")) == garbage)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        store.save([item])
        #expect(store.load() == .items([item]), "a damaged file is not a protected one: the list can be saved again")
    }
}
