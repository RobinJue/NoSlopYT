import Foundation
import Synchronization
@testable import NoSlopKit

/// Loads the captured YouTube responses in `Tests/NoSlopKitTests/Fixtures/`.
/// `name` includes the extension, e.g. `"search_blender_tutorial.json"`.
enum Fixture {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture '\(name)' is not in the test bundle's Fixtures folder." }
    }

    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw Missing(name: name)
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The fixture parsed as JSON. Each fixture is parsed once per test run and handed out as a copy of the same
    /// immutable value: the larger captures take a few hundred milliseconds to parse in a debug build, about a hundred
    /// tests ask for them, and Swift Testing starts all of those at once. Parsing them over and over kept every thread
    /// of the cooperative pool busy for seconds and starved the timers of the other tests (see `heavyWork`).
    /// `JSON` is a value type, so a test that edits its copy cannot affect another one.
    static func json(_ name: String) throws -> JSON {
        let slot = slots.withLock { slots -> Slot in
            if let existing = slots[name] { return existing }
            let created = Slot()
            slots[name] = created
            return created
        }
        // One thread parses a given fixture while the others needing it wait, instead of all parsing it at the same time.
        return try slot.lock.withLock {
            if let parsed = slot.json { return parsed }
            let parsed = try JSON(data: data(name))
            slot.json = parsed
            return parsed
        }
    }

    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var json: JSON?
    }

    private static let slots = Mutex<[String: Slot]>([:])
}
