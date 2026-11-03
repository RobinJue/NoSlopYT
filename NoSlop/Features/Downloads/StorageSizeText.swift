import Foundation

/// File sizes as text for the downloads screens and Settings: "46.7 MB", and "0 KB" instead of the "Zero KB" that
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
