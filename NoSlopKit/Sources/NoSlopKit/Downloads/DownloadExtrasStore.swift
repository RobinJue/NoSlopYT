import Foundation

/// The extras of the downloaded videos on disk: one JSON file per video, `<root>/.extras/<video id>.json`.
///
/// The folder starts with a dot like `.work`, so the Files app does not list it next to the videos. The files are not
/// part of `downloads.json`: that file is rewritten whole on every change of every item, and the text of captions can be
/// hundreds of kilobytes.
///
/// A file that cannot be read because the system keeps it closed (data protection before the first unlock) is left
/// alone and nothing is written over it. A file that is there but cannot be decoded is renamed `<file>.corrupt`, like
/// every persisted JSON of the app, and counts as not there. Writes are atomic.
///
/// The methods read and write files on the calling thread, and the files are small except for the captions (up to
/// megabytes). The manager therefore never calls them on the main actor: it reads with `loadOffMainActor`, and merges,
/// removals and prunes run one after the other on a background writer, so that two changes of a file never interleave.
struct DownloadExtrasStore: Sendable {
    let directory: URL

    init(root: URL) {
        directory = root.appendingPathComponent(".extras", isDirectory: true)
    }

    /// The video id becomes part of a file name: anything outside letters, digits, "-" and "_" is percent-encoded, so an id
    /// can never leave the folder (the same rule as for the work directories).
    func fileURL(forVideoID videoID: String) -> URL {
        directory.appendingPathComponent(Self.fileStem(for: videoID) + ".json", isDirectory: false)
    }

    private static func fileStem(for videoID: String) -> String {
        DownloadWorkspace.directoryName(for: videoID)
    }

    private func corruptURL(forVideoID videoID: String) -> URL {
        fileURL(forVideoID: videoID).appendingPathExtension("corrupt")
    }

    // MARK: Reading

    private enum Reading {
        case missing
        case unreadable
        case found(DownloadExtras)
    }

    private func read(videoID: String) -> Reading {
        let url = fileURL(forVideoID: videoID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return JSONFileStore.isMissing(error) ? .missing : .unreadable
        }
        do {
            return .found(try JSONDecoder().decode(DownloadExtras.self, from: data))
        } catch {
            moveAside(videoID: videoID)
            return .missing
        }
    }

    /// What is kept for the video; nil when nothing is, or when it cannot be read now.
    func load(videoID: String) -> DownloadExtras? {
        if case .found(let extras) = read(videoID: videoID) { return extras }
        return nil
    }

    /// `load`, away from the main actor: the text of captions makes a file of some hundreds of kilobytes.
    @concurrent
    func loadOffMainActor(videoID: String) async -> DownloadExtras? {
        load(videoID: videoID)
    }

    // MARK: Writing

    /// Keeps `extras` over what is kept for the video already (`DownloadExtras.merging`). False when nothing was written:
    /// the file is closed to us, or the disk would not take it.
    @discardableResult
    func merge(_ extras: DownloadExtras, videoID: String) -> Bool {
        switch read(videoID: videoID) {
        case .unreadable: return false
        case .missing: return write(extras, videoID: videoID)
        case .found(let kept): return write(kept.merging(extras), videoID: videoID)
        }
    }

    private func write(_ extras: DownloadExtras, videoID: String) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(extras)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(forVideoID: videoID), options: .atomic)
            return true
        } catch {
            // The extras are a bonus: the next download of the video (or the next time it plays online) tries again.
            return false
        }
    }

    // MARK: Removing

    /// Deletes the video's file (and the copy of a damaged one).
    func remove(videoID: String) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileURL(forVideoID: videoID))
        try? fileManager.removeItem(at: corruptURL(forVideoID: videoID))
    }

    /// Deletes the files of every video that is not in `videoIDs`: what an interrupted removal left behind.
    func prune(keeping videoIDs: Set<String>) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let keep = Set(videoIDs.map(Self.fileStem(for:)))
        for entry in entries {
            var name = entry.lastPathComponent
            if name.hasSuffix(".corrupt") { name.removeLast(".corrupt".count) }
            guard name.hasSuffix(".json") else { continue }
            name.removeLast(".json".count)
            if !keep.contains(name) { try? fileManager.removeItem(at: entry) }
        }
    }

    /// Renames the damaged file to `<file>.corrupt`, replacing an older one. It is kept, not deleted.
    private func moveAside(videoID: String) {
        let fileManager = FileManager.default
        let aside = corruptURL(forVideoID: videoID)
        try? fileManager.removeItem(at: aside)
        try? fileManager.moveItem(at: fileURL(forVideoID: videoID), to: aside)
    }
}
