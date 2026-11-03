import NoSlopKit
import SwiftUI

// MARK: - View model

/// Loads and pages the comments of one video: the first page (the watch page may already have it), the next pages
/// as the list scrolls, the sort order, and the replies of a comment.
@MainActor
@Observable
final class CommentsViewModel {
    enum Phase {
        case loading
        case loaded
        case failed(Error)
    }

    /// The replies of one comment: hidden until the user asks for them, then loaded on demand.
    struct Replies {
        var comments: [Comment] = []
        var continuation: String?
        var isExpanded = false
        var isLoading = false
        var hasLoaded = false
        var failed = false
    }

    private(set) var phase: Phase
    private(set) var comments: [Comment] = []
    private(set) var totalCountText: String?
    private(set) var sortOptions: [CommentSortOption] = []
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    private(set) var replies: [String: Replies] = [:]

    private var continuation: String?
    /// The token that loads the first page of the current sort order.
    private var firstPageToken: String?
    /// Bumped whenever the list is replaced, so a slow answer for the old list is dropped.
    private var generation = 0

    /// - Parameters:
    ///   - continuation: the token of the first page, from the watch page.
    ///   - firstPage: that page when it was already loaded, so opening the sheet needs no request.
    init(continuation: String?, firstPage: CommentsPage?) {
        firstPageToken = continuation
        if let firstPage {
            phase = .loaded
            apply(firstPage)
        } else {
            phase = continuation == nil ? .loaded : .loading
        }
    }

    // MARK: First page

    /// Loads the first page unless it is already there.
    func loadIfNeeded(using env: AppEnvironment) async {
        guard case .loading = phase, let token = firstPageToken else { return }
        await loadFirstPage(token: token, using: env)
    }

    func reload(using env: AppEnvironment) async {
        guard let token = firstPageToken else { return }
        phase = .loading
        await loadFirstPage(token: token, using: env)
    }

    /// Switches to another sort order ("Top", "Newest") and loads it from the start.
    func select(_ option: CommentSortOption, using env: AppEnvironment) async {
        guard !option.isSelected else { return }
        firstPageToken = option.continuation
        sortOptions = sortOptions.map { existing in
            var updated = existing
            updated.isSelected = existing.continuation == option.continuation
            return updated
        }
        comments = []
        replies = [:]
        continuation = nil
        loadMoreFailed = false
        phase = .loading
        await loadFirstPage(token: option.continuation, using: env)
    }

    private func loadFirstPage(token: String, using env: AppEnvironment) async {
        generation += 1
        let current = generation
        do {
            let page = try await env.youTube.comments(continuation: token)
            guard current == generation, !Task.isCancelled else { return }
            comments = []
            replies = [:]
            apply(page)
            phase = .loaded
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            phase = .failed(error)
        }
    }

    // MARK: Next pages

    /// Called as a row appears: loads the next page once one of the last few comments is on screen.
    func loadMoreIfNeeded(currentID: String, using env: AppEnvironment) async {
        guard continuation != nil, !isLoadingMore, !loadMoreFailed,
              comments.suffix(5).contains(where: { $0.id == currentID }) else { return }
        await loadMore(using: env)
    }

    /// Also the action of the "Retry" row after a failed page.
    func loadMore(using env: AppEnvironment) async {
        guard let token = continuation, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let current = generation
        defer { isLoadingMore = false }
        do {
            let page = try await env.youTube.comments(continuation: token)
            guard current == generation, !Task.isCancelled else { return }
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            // A page that brings nothing new and the same token again would loop forever.
            continuation = page.comments.isEmpty || page.continuation == token ? nil : page.continuation
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            loadMoreFailed = true
        }
    }

    // MARK: Replies

    /// Shows or hides the replies of a comment, loading them the first time.
    func toggleReplies(of comment: Comment, using env: AppEnvironment) async {
        var state = replies[comment.id] ?? Replies()
        state.isExpanded.toggle()
        replies[comment.id] = state
        if state.isExpanded, !state.hasLoaded, let token = comment.repliesContinuation {
            await loadReplies(of: comment.id, token: token, using: env)
        }
    }

    /// Loads the next batch of replies ("Show more replies", and "Retry" after a failure).
    func loadMoreReplies(of comment: Comment, using env: AppEnvironment) async {
        guard let state = replies[comment.id], !state.isLoading,
              let token = state.continuation ?? (state.hasLoaded ? nil : comment.repliesContinuation) else { return }
        await loadReplies(of: comment.id, token: token, using: env)
    }

    private func loadReplies(of commentID: String, token: String, using env: AppEnvironment) async {
        let current = generation
        update(commentID) { $0.isLoading = true; $0.failed = false }
        do {
            let page = try await env.youTube.comments(continuation: token)
            guard current == generation, !Task.isCancelled else { return }
            update(commentID) { state in
                let known = Set(state.comments.map(\.id))
                state.comments += page.comments.filter { !known.contains($0.id) }
                state.continuation = page.comments.isEmpty || page.continuation == token ? nil : page.continuation
                state.hasLoaded = true
                state.isLoading = false
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            update(commentID) { $0.isLoading = false; $0.failed = true }
        }
    }

    private func update(_ commentID: String, _ change: (inout Replies) -> Void) {
        var state = replies[commentID] ?? Replies()
        change(&state)
        replies[commentID] = state
    }

    // MARK: Helpers

    private func apply(_ page: CommentsPage) {
        var seen = Set<String>()
        comments = page.comments.filter { seen.insert($0.id).inserted }
        continuation = page.continuation
        loadMoreFailed = false
        if let total = page.totalCountText { totalCountText = total }
        if !page.sortOptions.isEmpty { sortOptions = page.sortOptions }
    }
}

// MARK: - Sheet

/// The comments of a video in a sheet: sort menu, endless scrolling, replies that open under their comment.
struct CommentsSheet: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: CommentsViewModel

    init(video: VideoSummary, continuation: String?, firstPage: CommentsPage?) {
        self.video = video
        _model = State(initialValue: CommentsViewModel(continuation: continuation, firstPage: firstPage))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.sortOptions.count > 1 {
                        ToolbarItem(placement: .topBarLeading) {
                            sortMenu
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .task { await model.loadIfNeeded(using: env) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView()
        case .failed(let error):
            ErrorStateView(error: error, openURL: video.watchURL) {
                await model.reload(using: env)
            }
        case .loaded:
            if model.comments.isEmpty {
                EmptyStateView(
                    title: "No comments",
                    systemImage: "bubble.left",
                    message: "Comments may be turned off for this video, or nobody has written one yet."
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if let total = model.totalCountText, !total.isEmpty {
                Text(total)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(model.comments) { comment in
                VStack(alignment: .leading, spacing: 8) {
                    CommentRow(comment: comment, isReply: false)
                    repliesSection(for: comment)
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await model.loadMoreIfNeeded(currentID: comment.id, using: env) }
                }
            }

            footer
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if model.loadMoreFailed {
            Button {
                Task { await model.loadMore(using: env) }
            } label: {
                Label("Couldn't load more comments. Tap to retry.", systemImage: "arrow.clockwise")
                    .labelStyle(.tight)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(model.sortOptions, id: \.continuation) { option in
                Button {
                    Task { await model.select(option, using: env) }
                } label: {
                    if option.isSelected {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Sort comments", systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: Replies

    @ViewBuilder
    private func repliesSection(for comment: Comment) -> some View {
        let state = model.replies[comment.id]
        let hasReplies = comment.replyCount > 0 || comment.repliesContinuation != nil

        if hasReplies {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await model.toggleReplies(of: comment, using: env) }
                } label: {
                    Label(
                        state?.isExpanded == true ? "Hide replies" : Self.repliesTitle(for: comment.replyCount),
                        systemImage: state?.isExpanded == true ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.tight)
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

                if let state, state.isExpanded {
                    ForEach(state.comments) { reply in
                        CommentRow(comment: reply, isReply: true)
                    }
                    if state.isLoading {
                        ProgressView()
                    } else if state.failed {
                        Button("Couldn't load replies. Tap to retry.") {
                            Task { await model.loadMoreReplies(of: comment, using: env) }
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else if state.continuation != nil {
                        Button("Show more replies") {
                            Task { await model.loadMoreReplies(of: comment, using: env) }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            // Lines up with the comment text, to the right of the avatar.
            .padding(.leading, 48)
        }
    }

    private static func repliesTitle(for count: Int) -> String {
        switch count {
        case ..<1: return "Replies"
        case 1: return "1 reply"
        default: return "\(count.formatted()) replies"
        }
    }
}

// MARK: - Row

/// One comment (or reply): avatar, author and age, text, likes. Draws only.
private struct CommentRow: View {
    let comment: Comment
    let isReply: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChannelAvatarView(url: comment.authorAvatarURL, size: isReply ? 24 : 36)
                .frame(width: isReply ? 24 : 36)

            VStack(alignment: .leading, spacing: 4) {
                if comment.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .labelStyle(.tight)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, comment.isByUploader ? 6 : 0)
                        .padding(.vertical, comment.isByUploader ? 1 : 0)
                        .background {
                            if comment.isByUploader {
                                Capsule().fill(Color(.tertiarySystemFill))
                            }
                        }
                    Text(comment.publishedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(comment.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    if let likes = comment.likeCountText, !likes.isEmpty {
                        Label(likes, systemImage: "hand.thumbsup")
                            .labelStyle(.tight)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if comment.isHearted {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Liked by the creator")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    CommentsSheet(
        video: SampleData.videos[2],
        continuation: "mock-comments:aqz-KE-bpKQ:top",
        firstPage: nil
    )
    .environment(AppEnvironment.preview())
}
