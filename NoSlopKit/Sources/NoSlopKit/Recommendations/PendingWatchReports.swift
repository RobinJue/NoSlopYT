import Foundation

/// A qualified viewing whose report has not reached YouTube yet.
public struct PendingWatchReport: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var videoID: String
    public var lengthSeconds: Double
    public var position: Double
    public var finished: Bool
    public var createdAt: Date
    /// Where the played range that the report covers began; nil (also in older files) reports from the start.
    public var rangeStart: Double?
    /// How many replays failed for a server reason (not a lost connection); the entry is dropped after a few.
    public var attempts: Int?

    public init(
        id: UUID = UUID(), videoID: String, lengthSeconds: Double, position: Double,
        finished: Bool = false, createdAt: Date = Date(), rangeStart: Double? = nil, attempts: Int? = nil
    ) {
        self.id = id
        self.videoID = videoID
        self.lengthSeconds = lengthSeconds
        self.position = position
        self.finished = finished
        self.createdAt = createdAt
        self.rangeStart = rangeStart
        self.attempts = attempts
    }
}

/// Reports waiting to be sent, kept in a JSON file: written at once on every change.
public final class PendingWatchReports: @unchecked Sendable {
    public static let maxEntries = 50
    public static let maxAge: TimeInterval = 7 * 86_400

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [PendingWatchReport]
    /// The file exists but could not be read (the app was started before the first unlock, and the file is protected).
    /// Nothing is written until a read worked, so the waiting reports are not overwritten with an empty list.
    private var needsReload: Bool

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        switch Self.load(fileURL) {
        case .loaded(let loaded):
            entries = loaded
            needsReload = false
            pruneAndSave()
        case .unreadable:
            entries = []
            needsReload = true
        }
    }

    /// Reads the file again after an unreadable start; entries added in the meantime are kept. Cheap when nothing was
    /// missed. Returns whether the queue is readable now.
    @discardableResult
    public func reloadIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard needsReload else { return true }
        guard case .loaded(let loaded) = Self.load(fileURL) else { return false }
        let known = Set(entries.map(\.id))
        entries = loaded.filter { !known.contains($0.id) } + entries
        needsReload = false
        pruneLocked()
        saveLocked()
        return true
    }

    public func add(_ entry: PendingWatchReport) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        pruneLocked()
        saveLocked()
    }

    public func all() -> [PendingWatchReport] {
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        pruneLocked()
        if entries.count != before { saveLocked() }
        return entries
    }

    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        saveLocked()
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = []
        if needsReload {
            // The file cannot be read, but it may be removed; if that fails too, the reload merges nothing new.
            if (try? FileManager.default.removeItem(at: fileURL)) != nil { needsReload = false }
            return
        }
        saveLocked()
    }

    private func pruneAndSave() {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        saveLocked()
    }

    private func pruneLocked() {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        entries = entries.filter { $0.createdAt >= cutoff }
        if entries.count > Self.maxEntries { entries = Array(entries.suffix(Self.maxEntries)) }
    }

    private func saveLocked() {
        guard !needsReload else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private enum Loaded {
        case loaded([PendingWatchReport])
        case unreadable
    }

    /// Lenient: a damaged file or damaged entries are skipped, never a crash. A missing file is an empty queue; a file that
    /// exists but cannot be read is not.
    private static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .loaded([]) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return .loaded([]) }
        return .loaded(raw.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(PendingWatchReport.self, from: d)
        })
    }
}
