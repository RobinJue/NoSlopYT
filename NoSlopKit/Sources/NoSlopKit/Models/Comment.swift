import Foundation

public struct Comment: Hashable, Sendable, Identifiable {
    public var id: String
    public var authorName: String
    public var authorAvatarURL: URL?
    public var authorChannelID: String?
    public var text: String
    public var publishedText: String
    public var likeCountText: String?
    public var replyCount: Int
    public var repliesContinuation: String?
    public var isPinned: Bool
    public var isByUploader: Bool
    public var isHearted: Bool

    public init(
        id: String,
        authorName: String,
        authorAvatarURL: URL? = nil,
        authorChannelID: String? = nil,
        text: String,
        publishedText: String,
        likeCountText: String? = nil,
        replyCount: Int = 0,
        repliesContinuation: String? = nil,
        isPinned: Bool = false,
        isByUploader: Bool = false,
        isHearted: Bool = false
    ) {
        self.id = id
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.authorChannelID = authorChannelID
        self.text = text
        self.publishedText = publishedText
        self.likeCountText = likeCountText
        self.replyCount = replyCount
        self.repliesContinuation = repliesContinuation
        self.isPinned = isPinned
        self.isByUploader = isByUploader
        self.isHearted = isHearted
    }
}

/// One entry of the comments sort menu ("Top", "Newest"); `continuation` loads the comments in that order.
public struct CommentSortOption: Hashable, Sendable {
    public var title: String
    public var continuation: String
    public var isSelected: Bool

    public init(title: String, continuation: String, isSelected: Bool = false) {
        self.title = title
        self.continuation = continuation
        self.isSelected = isSelected
    }
}

public struct CommentsPage: Sendable {
    public var comments: [Comment]
    public var continuation: String?
    public var totalCountText: String?
    public var sortOptions: [CommentSortOption]

    public init(
        comments: [Comment] = [],
        continuation: String? = nil,
        totalCountText: String? = nil,
        sortOptions: [CommentSortOption] = []
    ) {
        self.comments = comments
        self.continuation = continuation
        self.totalCountText = totalCountText
        self.sortOptions = sortOptions
    }
}
