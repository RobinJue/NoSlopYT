import Foundation

public enum DownloadQuality: Codable, Hashable, Sendable {
    case video(maxHeight: Int)
    case audioOnly

    /// "720p" | "Audio only"
    public var label: String {
        switch self {
        case .video(let maxHeight): return "\(maxHeight)p"
        case .audioOnly: return "Audio only"
        }
    }

    /// "720" | "audio"; used in `DownloadItem.id`.
    public var key: String {
        switch self {
        case .video(let maxHeight): return String(maxHeight)
        case .audioOnly: return "audio"
        }
    }
}

public enum DownloadState: String, Codable, Sendable {
    case queued, downloading, merging, completed, failed, paused
}

public struct DownloadItem: Codable, Hashable, Sendable, Identifiable {
    /// "<videoID>-<quality.key>"
    public var id: String
    public var video: VideoSummary
    public var quality: DownloadQuality
    public var state: DownloadState
    public var progress: Double
    public var bytesDownloaded: Int64
    public var bytesTotal: Int64?
    /// Path of the finished file relative to the downloads root; nil until completed.
    public var relativeFilePath: String?
    public var createdAt: Date
    public var errorMessage: String?

    public init(
        id: String,
        video: VideoSummary,
        quality: DownloadQuality,
        state: DownloadState = .queued,
        progress: Double = 0,
        bytesDownloaded: Int64 = 0,
        bytesTotal: Int64? = nil,
        relativeFilePath: String? = nil,
        createdAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.video = video
        self.quality = quality
        self.state = state
        self.progress = progress
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.relativeFilePath = relativeFilePath
        self.createdAt = createdAt
        self.errorMessage = errorMessage
    }

    /// Persisted JSON may come from an older build: `id`, `video` and `quality` are required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.video = try c.decode(VideoSummary.self, forKey: .video)
        self.quality = try c.decode(DownloadQuality.self, forKey: .quality)
        self.state = try c.decodeIfPresent(DownloadState.self, forKey: .state) ?? .failed
        self.progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        self.bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded) ?? 0
        self.bytesTotal = try c.decodeIfPresent(Int64.self, forKey: .bytesTotal)
        self.relativeFilePath = try c.decodeIfPresent(String.self, forKey: .relativeFilePath)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

/// One row of the download quality sheet.
public struct DownloadOption: Hashable, Sendable, Identifiable {
    public var quality: DownloadQuality
    public var label: String
    public var estimatedBytes: Int64?

    public var id: String { quality.key }

    public init(quality: DownloadQuality, label: String, estimatedBytes: Int64? = nil) {
        self.quality = quality
        self.label = label
        self.estimatedBytes = estimatedBytes
    }
}
