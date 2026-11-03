import Foundation
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

    static func json(_ name: String) throws -> JSON {
        try JSON(data: data(name))
    }
}
