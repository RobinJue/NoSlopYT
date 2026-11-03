import Foundation

/// Atomic JSON persistence for the library files. A file that cannot be decoded is renamed to
/// `<file>.corrupt` (replacing an older one) and the default is used; it is never deleted.
///
/// STUB (Task 1A). Task 6 owns this file: `load` returns the default and `save` writes nothing.
struct JSONFileStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func load<T: Decodable>(_ file: String, default defaultValue: T) -> T {
        defaultValue
    }

    func save<T: Encodable>(_ value: T, to file: String) {}
}
