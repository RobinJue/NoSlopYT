import Foundation
import NoSlopKit

/// File sizes as text for the downloads screens and Settings: "46.7 MB", and "0 bytes" instead of the "Zero KB" that
/// `ByteCountFormatter` writes by default. Locale-aware (decimal separator, units).
enum StorageSizeText {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: max(0, bytes))
    }
}

extension DownloadManager {
    /// Changes whenever the space the downloads take may have changed: an item starts, stops, fails or finishes, and
    /// every 5 % a running download gets further. A view that shows `diskUsage()` measures it again when this changes.
    var diskUsageKey: [String] {
        items.map { "\($0.id)|\($0.state.rawValue)|\(Int(min(1, max(0, $0.progress)) * 20))" }
    }
}
