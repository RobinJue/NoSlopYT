import Foundation

/// Atomic JSON persistence for the library files. A file that cannot be decoded is renamed to
/// `<file>.corrupt` (replacing an older one) and the default is used; it is never deleted.
///
/// - Dates are written as ISO 8601 strings (whole seconds). Reading is more forgiving: fractional seconds, UTC
///   offsets and Foundation's default numeric dates are accepted too.
/// - A missing file is not an error (first launch): the default is returned and nothing is touched.
/// - A file that exists but cannot be read or decoded is moved aside, so the next `save` can never overwrite it.
struct JSONFileStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(_ file: String) -> URL {
        directory.appendingPathComponent(file, isDirectory: false)
    }

    /// The decoded content of `file`, or `defaultValue` when there is none or it is damaged.
    func load<T: Decodable>(_ file: String, default defaultValue: T) -> T {
        let url = fileURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: url)
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
    /// the unreadable entry is kept in the `.corrupt` copy and the next `save` writes a clean file.
    func loadList<Element: Decodable>(_ file: String) -> [Element] {
        let url = fileURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let entries = try Self.makeDecoder().decode([Lenient<Element>].self, from: data)
            let readable = entries.compactMap(\.value)
            if readable.count != entries.count { Self.moveAside(url) }
            return readable
        } catch {
            Self.moveAside(url)
            return []
        }
    }

    /// Writes `value` to `file` atomically (the old content stays intact until the new file is complete),
    /// creating the directory when needed. Failures (disk full, an unencodable value) leave the old file alone;
    /// the next save simply tries again.
    func save<T: Encodable>(_ value: T, to file: String) {
        guard let data = try? Self.makeEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(file), options: .atomic)
        } catch {
            return
        }
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
