import Foundation
import Testing
@testable import NoSlopKit

@Suite struct SearchParamsTests {
    // MARK: From the plan

    @Test(arguments: [
        (SearchFilter(), nil),
        (SearchFilter(type: .video), "EgIQAQ=="),
        (SearchFilter(type: .channel), "EgIQAg=="),
        (SearchFilter(type: .playlist), "EgIQAw=="),
        (SearchFilter(type: .video, sort: .uploadDate), "CAISAhAB"),
        (SearchFilter(sort: .viewCount), "CAM="),
        (SearchFilter(type: .video, duration: .long), "EgQQARgC"),
        (SearchFilter(type: .video, uploadDate: .today), "EgQIAhAB"),
    ] as [(SearchFilter, String?)])
    func searchParams(filter: SearchFilter, expected: String?) {
        #expect(SearchParams.encode(filter) == expected)
    }

    // MARK: Every combination

    /// What a `params` string says, decoded independently of the encoder: protobuf field numbers 1 (sort) and
    /// 2 (a filters message with 1 = upload date, 2 = type, 3 = duration). Nil when the bytes are not that shape.
    private struct Decoded: Equatable {
        var sort: UInt64?
        var uploadDate: UInt64?
        var type: UInt64?
        var duration: UInt64?
    }

    private static func fields(of bytes: [UInt8]) -> [(field: UInt64, varint: UInt64?, payload: [UInt8]?)]? {
        var result: [(UInt64, UInt64?, [UInt8]?)] = []
        var index = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = readVarint() else { return nil }
            switch tag & 0x07 {
            case 0:
                guard let value = readVarint() else { return nil }
                result.append((tag >> 3, value, nil))
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return nil }
                result.append((tag >> 3, nil, Array(bytes[index..<index + Int(length)])))
                index += Int(length)
            default:
                return nil
            }
        }
        return result
    }

    private static func decode(_ base64: String) -> Decoded? {
        guard let data = Data(base64Encoded: base64), let top = fields(of: [UInt8](data)) else { return nil }
        var decoded = Decoded()
        for entry in top {
            switch (entry.field, entry.varint, entry.payload) {
            case (1, let value?, _):
                decoded.sort = value
            case (2, _, let payload?):
                guard let inner = fields(of: payload) else { return nil }
                for filter in inner {
                    guard let value = filter.varint else { return nil }
                    switch filter.field {
                    case 1: decoded.uploadDate = value
                    case 2: decoded.type = value
                    case 3: decoded.duration = value
                    default: return nil
                    }
                }
            default:
                return nil
            }
        }
        return decoded
    }

    private static func expectedFields(for filter: SearchFilter) -> Decoded {
        var expected = Decoded()
        switch filter.sort {
        case .relevance: break
        case .uploadDate: expected.sort = 2
        case .viewCount: expected.sort = 3
        }
        switch filter.uploadDate {
        case .any: break
        case .lastHour: expected.uploadDate = 1
        case .today: expected.uploadDate = 2
        case .thisWeek: expected.uploadDate = 3
        case .thisMonth: expected.uploadDate = 4
        case .thisYear: expected.uploadDate = 5
        }
        switch filter.type {
        case .all: break
        case .video: expected.type = 1
        case .channel: expected.type = 2
        case .playlist: expected.type = 3
        }
        switch filter.duration {
        case .any: break
        case .short: expected.duration = 1
        case .long: expected.duration = 2
        case .medium: expected.duration = 3
        }
        return expected
    }

    @Test func everyCombinationEncodesItsFacetsAndNothingElse() {
        var seen: [String: SearchFilter] = [:]
        for type in SearchType.allCases {
            for sort in SearchSort.allCases {
                for duration in SearchDuration.allCases {
                    for uploadDate in SearchUploadDate.allCases {
                        let filter = SearchFilter(type: type, sort: sort, duration: duration, uploadDate: uploadDate)
                        guard let encoded = SearchParams.encode(filter) else {
                            #expect(filter.isDefault, "nil is only for the default filter, not \(filter)")
                            continue
                        }
                        #expect(!filter.isDefault)
                        #expect(Self.decode(encoded) == Self.expectedFields(for: filter), "\(filter) → \(encoded)")
                        // Standard base64 with padding, nothing URL-safe.
                        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" })
                        #expect(encoded.count % 4 == 0)
                        #expect(seen.updateValue(filter, forKey: encoded) == nil, "\(filter) collides with another filter")
                    }
                }
            }
        }
        #expect(seen.count == 4 * 3 * 4 * 6 - 1)
    }

    @Test func defaultFilterHasNoParams() {
        #expect(SearchParams.encode(SearchFilter()) == nil)
        #expect(SearchParams.encode(SearchFilter(type: .all, sort: .relevance, duration: .any, uploadDate: .any)) == nil)
    }
}
