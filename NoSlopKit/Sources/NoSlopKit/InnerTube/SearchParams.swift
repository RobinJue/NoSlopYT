import Foundation

/// Encodes a `SearchFilter` into the protobuf `params` string of the `search` endpoint.
///
/// The message: field 1 is the sort order (relevance is the default and is left out); field 2 is a nested message
/// with field 1 the upload date, field 2 the type and field 3 the duration. Standard base64 with padding.
public enum SearchParams {
    /// nil for the default filter.
    public static func encode(_ filter: SearchFilter) -> String? {
        var filters: [UInt8] = []
        switch filter.uploadDate {
        case .any: break
        case .lastHour: appendField(1, value: 1, to: &filters)
        case .today: appendField(1, value: 2, to: &filters)
        case .thisWeek: appendField(1, value: 3, to: &filters)
        case .thisMonth: appendField(1, value: 4, to: &filters)
        case .thisYear: appendField(1, value: 5, to: &filters)
        }
        switch filter.type {
        case .all: break
        case .video: appendField(2, value: 1, to: &filters)
        case .channel: appendField(2, value: 2, to: &filters)
        case .playlist: appendField(2, value: 3, to: &filters)
        }
        switch filter.duration {
        case .any: break
        case .short: appendField(3, value: 1, to: &filters)
        case .long: appendField(3, value: 2, to: &filters)
        case .medium: appendField(3, value: 3, to: &filters)
        }

        var message: [UInt8] = []
        switch filter.sort {
        case .relevance: break
        case .uploadDate: appendField(1, value: 2, to: &message)
        case .viewCount: appendField(1, value: 3, to: &message)
        }
        if !filters.isEmpty {
            appendTag(2, wireType: 2, to: &message)
            appendVarint(UInt64(filters.count), to: &message)
            message.append(contentsOf: filters)
        }

        return message.isEmpty ? nil : Data(message).base64EncodedString()
    }

    // MARK: Protobuf

    /// A varint field: tag, then value.
    private static func appendField(_ field: UInt64, value: UInt64, to bytes: inout [UInt8]) {
        appendTag(field, wireType: 0, to: &bytes)
        appendVarint(value, to: &bytes)
    }

    private static func appendTag(_ field: UInt64, wireType: UInt64, to bytes: inout [UInt8]) {
        appendVarint(field << 3 | wireType, to: &bytes)
    }

    private static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }
}
