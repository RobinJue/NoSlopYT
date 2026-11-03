import Foundation
import Synchronization

/// Atomic JSON persistence for the library files. A file whose content cannot be decoded is renamed to
/// `<file>.corrupt` (replacing an older one) and the default is used; it is never deleted.
///
/// - Dates are written as ISO 8601 strings (whole seconds). Reading is more forgiving: fractional seconds, UTC
///   offsets and Foundation's default numeric dates are accepted too.
/// - A missing file is not an error (first launch): the default is returned and nothing is touched.
/// - Only a *decoding* failure moves a file aside. A *read* failure (no permission, data protection before the first
///   unlock, an I/O error) says nothing about the content, which may be perfectly good: the file stays where it is,
///   the default is returned, and `save` refuses to write over that file for the rest of the process, until a load
///   of it succeeds. Otherwise a launch while the device is locked would replace the user's library with a new,
///   nearly empty file.
struct JSONFileStore: Sendable {
    let directory: URL
    private let read: @Sendable (URL) throws -> Data

    init(directory: URL) {
        self.init(directory: directory, read: { try Data(contentsOf: $0) })
    }

    /// Tests inject the reader to make reading fail the way a device can.
    init(directory: URL, read: @escaping @Sendable (URL) throws -> Data) {
        self.directory = directory
        self.read = read
    }

    func fileURL(_ file: String) -> URL {
        directory.appendingPathComponent(file, isDirectory: false)
    }

    /// The decoded content of `file`, or `defaultValue` when there is none, it cannot be read or it is damaged.
    func load<T: Decodable>(_ file: String, default defaultValue: T) -> T {
        let url = fileURL(file)
        guard case .data(let data) = readFile(at: url) else { return defaultValue }
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            Self.moveAside(url)
            return defaultValue
        }
    }

    /// The elements of the JSON array in `file` that can be decoded, for files that hold a list of independent items.
    ///
    /// One damaged entry does not cost the others: the readable entries are returned. The file is moved aside exactly
    /// as in `load` whenever *anything* in it could not be read (the whole file when it is not a list at all), so
    /// the unreadable entry is kept in the `.corrupt` copy. The readable entries are written back to a clean file
    /// at once: they must not exist only in memory, or a launch that follows without any change to this list would
    /// find no file and start with an empty list although the entries were readable.
    func loadList<Element: Codable>(_ file: String) -> [Element] {
        let url = fileURL(file)
        guard case .data(let data) = readFile(at: url) else { return [] }
        let entries: [Lenient<Element>]
        do {
            entries = try Self.makeDecoder().decode([Lenient<Element>].self, from: data)
        } catch {
            Self.moveAside(url)
            return []
        }
        let readable = entries.compactMap(\.value)
        if readable.count != entries.count {
            Self.moveAside(url)
            // Only over a file that really was moved away: the damaged original is never overwritten.
            if !readable.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
                save(readable, to: file)
            }
        }
        return readable
    }

    /// Writes `value` to `file` atomically (the old content stays intact until the new file is complete),
    /// creating the directory when needed. Failures (disk full, an unencodable value) leave the old file alone;
    /// the next save simply tries again. A file that exists but could not be read is not written to at all (see the
    /// type's documentation).
    func save<T: Encodable>(_ value: T, to file: String) {
        let url = fileURL(file)
        guard !Self.isUnreadable(url) else { return }
        guard let data = try? Self.makeEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    // MARK: Reading

    private enum ReadResult {
        case data(Data)
        /// There is no such file (first launch).
        case missing
        /// The file is there but the system would not give its content.
        case unreadable
    }

    /// The files (by path) that exist but could not be read. It is process-wide on purpose: whoever created the store
    /// that saw the failure, no store in this process may write over such a file until one of them has read it.
    private static let unreadableFiles = Mutex<Set<String>>([])

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func isUnreadable(_ url: URL) -> Bool {
        unreadableFiles.withLock { $0.contains(key(for: url)) }
    }

    /// Reads the file and keeps the list of unreadable files up to date: a successful read (or a file that is not
    /// there) lifts the protection, a failed one sets it.
    private func readFile(at url: URL) -> ReadResult {
        let key = Self.key(for: url)
        do {
            let data = try read(url)
            Self.unreadableFiles.withLock { _ = $0.remove(key) }
            return .data(data)
        } catch {
            if Self.isMissing(error) {
                Self.unreadableFiles.withLock { _ = $0.remove(key) }
                return .missing
            }
            Self.unreadableFiles.withLock { _ = $0.insert(key) }
            return .unreadable
        }
    }

    /// Whether the error says "there is no such file" (possibly as the underlying error of another one).
    private static func isMissing(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let nsError = current else { return false }
            switch nsError.domain {
            case NSCocoaErrorDomain where nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError:
                return true
            case NSPOSIXErrorDomain where nsError.code == Int(ENOENT):
                return true
            default:
                break
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: Damaged files

    /// Renames `url` to `<name>.corrupt`, replacing an older `.corrupt` file. The damaged file itself is kept.
    private static func moveAside(_ url: URL) {
        let aside = url.appendingPathExtension("corrupt")
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: aside.path) {
                try fileManager.removeItem(at: aside)
            }
            try fileManager.moveItem(at: url, to: aside)
        } catch {
            // Could not be moved (read-only volume, say). It stays where it is; the caller carries on with the default.
            return
        }
    }

    // MARK: Coding

    /// An array element that decodes to nil instead of failing, so that the other elements still decode.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) {
            value = try? Value(from: decoder)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard let date = parseISO8601(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
                }
                return date
            }
            // JSONEncoder's default: seconds since 2001-01-01.
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        return decoder
    }

    private static func parseISO8601(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
