import Foundation

/// A parsed JSON document, navigated with optional subscripts so parsers can skip what they don't understand.
///
/// ```swift
/// let id = json["contents"]?["twoColumnWatchNextResults"]?["results"]?[0]?["videoId"]?.string
/// let renderers = json.findAll("videoRenderer")
/// ```
///
/// Pitfall: `JSON` is `ExpressibleByNilLiteral`, but `json["key"] == nil` still compares the *optional* with `nil`,
/// so it is true only when the key is absent. A JSON `null` is `.null`: compare with `== .null` (or test `.string` etc.).
public enum JSON: Sendable, Hashable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: Literals

    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, latest in latest }))
    }

    public init(arrayLiteral elements: JSON...) {
        self = .array(elements)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(nilLiteral: ()) {
        self = .null
    }

    // MARK: Parsing and serialising

    /// Parses `data` with `JSONSerialization`. Top-level scalars are accepted.
    /// Throws `NoSlopError.decoding` when the bytes are not JSON.
    public init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw NoSlopError.decoding("Invalid JSON: \(error.localizedDescription)")
        }
        self.init(foundationObject: object)
    }

    private init(foundationObject object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // JSONSerialization hands back CFBoolean for true/false; NSNumber(1) also bridges to Bool, so test the type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSON(foundationObject: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSON(foundationObject: $0) })
        default:
            self = .null
        }
    }

    /// Compact UTF-8 JSON with sorted object keys, so equal values always serialise to equal bytes.
    /// Whole numbers are written without a fraction. Throws `NoSlopError.decoding` for NaN or infinity.
    public func data() throws -> Data {
        var output = [UInt8]()
        try write(to: &output)
        return Data(output)
    }

    private func write(to output: inout [UInt8]) throws {
        switch self {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let value):
            guard value.isFinite else {
                throw NoSlopError.decoding("Cannot serialise a non-finite number.")
            }
            if value == value.rounded(), abs(value) < 1e15 {
                output.append(contentsOf: String(Int64(value)).utf8)
            } else {
                output.append(contentsOf: "\(value)".utf8)
            }
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let values):
            output.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try value.write(to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let values):
            output.append(UInt8(ascii: "{"))
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                Self.writeString(key, to: &output)
                output.append(UInt8(ascii: ":"))
                try values[key]?.write(to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ string: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append(contentsOf: "\\\"".utf8)
            case "\\": output.append(contentsOf: "\\\\".utf8)
            case "\n": output.append(contentsOf: "\\n".utf8)
            case "\r": output.append(contentsOf: "\\r".utf8)
            case "\t": output.append(contentsOf: "\\t".utf8)
            case "\u{08}": output.append(contentsOf: "\\b".utf8)
            case "\u{0C}": output.append(contentsOf: "\\f".utf8)
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                output.append(contentsOf: "\\u\(String(repeating: "0", count: 4 - hex.count))\(hex)".utf8)
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    // MARK: Navigation

    /// The value for `key` when this is an object that contains it; nil otherwise.
    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// The element at `index` when this is an array and the index is in bounds; nil otherwise.
    public subscript(index: Int) -> JSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A whole `.number`, or a `.string` that parses as an integer (InnerTube sends many counts as strings).
    public var int: Int? {
        switch self {
        case .number(let value): return Int(exactly: value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// A `.number`, or a `.string` that parses as a number.
    public var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: Search

    /// Every value stored under `key` anywhere in the tree. Depth-first, pre-order: a match is reported before
    /// matches inside it; arrays are walked in order and object keys in sorted order, so the result is deterministic.
    public func findAll(_ key: String) -> [JSON] {
        var matches: [JSON] = []
        collect(key, into: &matches, stopAtFirst: false)
        return matches
    }

    /// The first match of `findAll(key)`, without walking the rest of the tree.
    public func first(_ key: String) -> JSON? {
        var matches: [JSON] = []
        collect(key, into: &matches, stopAtFirst: true)
        return matches.first
    }

    /// Returns true when the walk should stop (a first match was found and `stopAtFirst` is set).
    @discardableResult
    private func collect(_ key: String, into matches: inout [JSON], stopAtFirst: Bool) -> Bool {
        switch self {
        case .object(let object):
            let keys = object.count > 1 ? object.keys.sorted() : Array(object.keys)
            for childKey in keys {
                guard let child = object[childKey] else { continue }
                if childKey == key {
                    matches.append(child)
                    if stopAtFirst { return true }
                }
                if child.collect(key, into: &matches, stopAtFirst: stopAtFirst) { return true }
            }
        case .array(let array):
            for child in array {
                if child.collect(key, into: &matches, stopAtFirst: stopAtFirst) { return true }
            }
        case .string, .number, .bool, .null:
            break
        }
        return false
    }
}
