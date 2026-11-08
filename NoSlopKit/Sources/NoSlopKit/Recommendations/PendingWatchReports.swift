import Foundation

/// A qualified viewing whose report has not reached YouTube yet.
public struct PendingWatchReport: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var videoID: String
    public var lengthSeconds: Double
    public var position: Double
    public var finished: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(), videoID: String, lengthSeconds: Double, position: Double,
        finished: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.videoID = videoID
        self.lengthSeconds = lengthSeconds
        self.position = position
        self.finished = finished
        self.createdAt = createdAt
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

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        self.entries = Self.load(fileURL)
        pruneAndSave()
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
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Lenient: a damaged file or damaged entries are skipped, never a crash.
    private static func load(_ url: URL) -> [PendingWatchReport] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return raw.compactMap { item in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(PendingWatchReport.self, from: d)
        }
    }
}
