import Foundation

public enum SubscriptionSource: Codable, Hashable, Sendable {
    /// Stored on this device only.
    case local
    /// Mirrors a subscription on the signed-in Google account.
    case google(subscriptionID: String)
}

public struct SubscribedChannel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var source: SubscriptionSource
    public var subscribedAt: Date?

    public init(
        id: String,
        name: String,
        avatarURL: URL? = nil,
        source: SubscriptionSource = .local,
        subscribedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.source = source
        self.subscribedAt = subscribedAt
    }

    /// Persisted JSON may come from an older build: every key except `id` decodes to a default when missing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        self.source = try c.decodeIfPresent(SubscriptionSource.self, forKey: .source) ?? .local
        self.subscribedAt = try c.decodeIfPresent(Date.self, forKey: .subscribedAt)
    }

    public var ref: ChannelRef {
        ChannelRef(id: id, name: name, avatarURL: avatarURL)
    }
}

public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var video: VideoSummary
    public var lastWatchedAt: Date
    public var progressSeconds: Double
    public var durationSeconds: Double?

    public var id: String { video.id }

    public init(video: VideoSummary, lastWatchedAt: Date, progressSeconds: Double, durationSeconds: Double? = nil) {
        self.video = video
        self.lastWatchedAt = lastWatchedAt
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
    }

    /// Persisted JSON may come from an older build: only `video` is required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.video = try c.decode(VideoSummary.self, forKey: .video)
        self.lastWatchedAt = try c.decodeIfPresent(Date.self, forKey: .lastWatchedAt) ?? Date(timeIntervalSince1970: 0)
        self.progressSeconds = try c.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }

    /// The duration is known and the viewer got within 15 s of the end or at least 95% through.
    public var isFinished: Bool {
        guard let durationSeconds, durationSeconds > 0 else { return false }
        return progressSeconds >= durationSeconds - 15 || progressSeconds / durationSeconds >= 0.95
    }
}

public struct LocalPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var videos: [VideoSummary]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        videos: [VideoSummary] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.videos = videos
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Persisted JSON may come from an older build: only `id` is required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.videos = try c.decodeIfPresent([VideoSummary].self, forKey: .videos) ?? []
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.createdAt = created
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
    }
}

public struct BlockedChannel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The channel's @handle when it was known at the time of blocking; lets the filter recognise the channel's
    /// videos where YouTube gives no channel id (its Home tiles). Absent in what older builds saved.
    public var handle: String?

    public init(id: String, name: String, handle: String? = nil) {
        self.id = id
        self.name = name
        self.handle = handle
    }

    private enum CodingKeys: String, CodingKey { case id, name, handle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        handle = (try? c.decodeIfPresent(String.self, forKey: .handle)) ?? nil
    }
}
