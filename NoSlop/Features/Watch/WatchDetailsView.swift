import NoSlopKit
import SwiftUI

/// The watch page under the player, inside the expanded player overlay: title, views and date, the channel with
/// Subscribe, action chips (Like, Watch Later, Save, Download, Share), the description, chapters, a comments
/// teaser and the "Up next" list.
///
/// It scrolls by itself and needs no navigation stack: links go through `AppEnvironment` (`open`, `show`), which
/// shrinks the player to the mini player before a channel or playlist page is pushed.
struct WatchDetailsView: View {
    let video: VideoSummary

    var body: some View {
        WatchDetailsContent(video: video)
            // Another video is another page: fresh state, scrolled to the top.
            .id(video.id)
    }
}

private struct WatchDetailsContent: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: WatchDetailsViewModel
    @State private var isTitleExpanded = false
    @State private var isShowingComments = false
    @State private var isShowingDownloads = false
    @State private var isShowingPlaylists = false
    @State private var isExplainingSignIn = false
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollMemory = PageScrollMemory()

    init(video: VideoSummary) {
        self.video = video
        _model = State(initialValue: WatchDetailsViewModel(video: video))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                titleBlock
                channelRow
                actionChips
                pageContent
            }
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: PageScroll.self) { geometry in
            PageScroll(offset: geometry.contentOffset.y, height: geometry.containerSize.height)
        } action: { _, page in
            pageScrolled(page)
        }
        #if DEBUG
        .debugWatchPageSteps(
            isLoaded: debugIsLoaded,
            isTitleExpanded: $isTitleExpanded,
            isShowingComments: $isShowingComments
        )
        #endif
        .task { await model.load(using: env) }
        .task(id: env.googleAccount?.id) { await model.loadRating(using: env) }
        // "Don't show this channel" on a row of the Up next list (or any other feed filter) takes effect on the list and on
        // the player's autoplay list at once, like on the other lists, not after the page is loaded again.
        .onChange(of: env.settings) {
            model.filtersChanged(using: env)
        }
        .sheet(isPresented: $isShowingComments) {
            CommentsSheet(
                video: model.summary,
                continuation: model.details?.commentsContinuation,
                firstPage: model.commentsFirstPage
            )
        }
        .sheet(isPresented: $isShowingDownloads) {
            DownloadOptionsSheet(video: model.summary)
        }
        .sheet(isPresented: $isShowingPlaylists) {
            AddToPlaylistSheet(video: model.summary)
        }
        .alert("Sign in to like videos", isPresented: $isExplainingSignIn) {
            Button("Go to Library") {
                env.player.minimize()
                // The sign-in card is at the top of the Library tab, which may still be showing a screen from earlier.
                env.router.showRoot(of: .library)
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Likes are saved to your YouTube account, so you need to sign in with Google first. You can do that at the top of the Library tab.")
        }
        .alert(
            "Couldn't update your rating",
            isPresented: Binding(
                get: { model.ratingFailure != nil },
                set: { if !$0 { model.ratingFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.ratingFailure ?? "")
        }
    }

    // MARK: Scroll position

    /// Full screen collapses the page to no height and turning the phone lays it out again, and SwiftUI does not keep
    /// the scroll offset through that: the page comes back scrolled somewhere else (a few rows further down, in the
    /// simulator). So the page remembers where it was while it had room to be seen, and puts the offset back when it
    /// has room again.
    private func pageScrolled(_ page: PageScroll) {
        if page.height < Self.collapsedHeight {
            scrollMemory.isCollapsed = true
            return
        }
        if scrollMemory.isCollapsed {
            scrollMemory.isCollapsed = false
            if let offset = scrollMemory.offset {
                scrollPosition.scrollTo(y: offset)
            }
            return
        }
        scrollMemory.offset = page.offset
    }

    /// A page with less height than this is collapsed (full screen), not scrolled by the viewer.
    private static let collapsedHeight: CGFloat = 100

    #if DEBUG
    private var debugIsLoaded: Bool {
        if case .loaded = model.phase { return true }
        return false
    }
    #endif

    // MARK: Title

    private var titleBlock: some View {
        var shown = model.summary
        // A video opened from a bare link: the player has its title from the stream (`video` is the player's copy) while
        // the details are still on their way, or cannot be loaded.
        if shown.title.isEmpty {
            shown.title = video.title
        }
        return VStack(alignment: .leading, spacing: 4) {
            if shown.title.isEmpty {
                // A bare id from a link: the title arrives with the details, unless they cannot be loaded.
                if case .failed = model.phase {
                    Text("Video \(shown.id)")
                        .font(.headline)
                        .foregroundStyle(.primary)
                } else {
                    Text("Loading video")
                        .font(.headline)
                        .redacted(reason: .placeholder)
                }
            } else {
                VideoTitleText(video: shown, lineLimit: isTitleExpanded ? nil : 2)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { isTitleExpanded.toggle() }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(isTitleExpanded ? "Shows fewer lines" : "Shows the whole title")
            }

            if !model.statsLine.isEmpty {
                Text(model.statsLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.top, 12)
    }

    // MARK: Channel

    @ViewBuilder
    private var channelRow: some View {
        if let channel = model.channel {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // The name and "Subscribe" cannot share a line at these sizes without one of them being cut or
                    // broken mid-word, so the button goes under the channel.
                    VStack(alignment: .leading, spacing: 12) {
                        channelButton(channel, lineLimit: 3)
                        SubscribeButton(channel: channel)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) {
                        channelButton(channel, lineLimit: 1)
                        Spacer(minLength: 8)
                        // The button keeps its width; a long channel name is what gets cut.
                        SubscribeButton(channel: channel)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.horizontal, Theme.padding)
            .padding(.top, 14)
        }
    }

    /// Avatar, name and subscriber count; opens the channel.
    private func channelButton(_ channel: ChannelRef, lineLimit: Int) -> some View {
        Button {
            env.show(.channel(id: channel.id))
        } label: {
            HStack(spacing: 10) {
                ChannelAvatarView(url: channel.avatarURL, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(lineLimit)
                    if let subscribers = model.details?.subscriberCountText, !subscribers.isEmpty {
                        Text(subscribers)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(lineLimit)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open channel \(channel.name)")
    }

    // MARK: Actions

    private var actionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                likeChip
                watchLaterChip
                playlistChip
                if !model.isLive {
                    downloadChip
                }
                ShareLink(item: video.watchURL) {
                    ChipLabel(title: "Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.padding)
        }
        .padding(.top, 14)
    }

    private var likeChip: some View {
        let liked = model.rating == .like
        return Button {
            if env.googleAccount == nil {
                isExplainingSignIn = true
            } else {
                Task { await model.toggleLike(using: env) }
            }
        } label: {
            ChipLabel(
                title: model.likeCountLabel ?? "Like",
                systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                tint: liked ? Theme.accent : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? "Unlike" : "Like")
        .accessibilityValue(model.likeCountLabel.map { "\($0) likes" } ?? "")
    }

    private var watchLaterChip: some View {
        let saved = env.library.isInWatchLater(video.id)
        return Button {
            env.library.toggleWatchLater(model.summary)
        } label: {
            ChipLabel(
                title: saved ? "Saved" : "Watch Later",
                systemImage: saved ? "clock.badge.checkmark" : "clock",
                tint: saved ? Theme.accent : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Remove from Watch Later" : "Save to Watch Later")
    }

    private var playlistChip: some View {
        Button {
            isShowingPlaylists = true
        } label: {
            ChipLabel(title: "Playlist", systemImage: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save to playlist")
    }

    private var downloadChip: some View {
        let state = downloadChipState()
        return Button {
            isShowingDownloads = true
        } label: {
            ChipLabel(title: state.title, systemImage: state.systemImage, tint: state.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download")
        .accessibilityValue(state.title)
    }

    /// One summary of every download of this video: finished beats running beats failed.
    private func downloadChipState() -> (title: String, systemImage: String, tint: Color?) {
        let items = env.downloads.items.filter { $0.video.id == video.id }
        if items.contains(where: { $0.state == .completed }) {
            return ("Downloaded", "checkmark.circle.fill", Theme.accent)
        }
        if let running = items.first(where: { [.queued, .downloading, .merging].contains($0.state) }) {
            switch running.state {
            case .queued:
                return ("Queued", "arrow.down.circle", Theme.accent)
            case .merging:
                return ("Finishing…", "arrow.down.circle", Theme.accent)
            default:
                let percent = Int((min(1, max(0, running.progress)) * 100).rounded())
                return ("Downloading \(percent)%", "arrow.down.circle", Theme.accent)
            }
        }
        if let stopped = items.first {
            return (stopped.state == .paused ? "Download paused" : "Download failed", "exclamationmark.arrow.circlepath", nil)
        }
        return ("Download", "arrow.down.circle", nil)
    }

    // MARK: Page

    @ViewBuilder
    private var pageContent: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case .failed(let error):
            ErrorStateView(error: error, openURL: video.watchURL) {
                await model.reload(using: env)
            }
            .padding(.top, 24)
        case .loaded:
            if let details = model.details {
                loadedContent(details)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ details: VideoDetails) -> some View {
        if !details.description.text.isEmpty {
            DescriptionView(description: details.description)
                .padding(.horizontal, Theme.padding)
                .padding(.top, 14)
        }

        if !details.chapters.isEmpty {
            ChaptersView(chapters: details.chapters)
                .padding(.top, 18)
        }

        commentsTeaser(details)

        relatedList
    }

    // MARK: Comments teaser

    @ViewBuilder
    private func commentsTeaser(_ details: VideoDetails) -> some View {
        if details.commentsContinuation != nil {
            Button {
                isShowingComments = true
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Comments")
                            .font(.subheadline.weight(.semibold))
                        if let count = details.commentCountText, !count.isEmpty {
                            Text(count)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    if let first = model.commentsFirstPage?.comments.first {
                        HStack(alignment: .top, spacing: 10) {
                            ChannelAvatarView(url: first.authorAvatarURL, size: 26)
                            Text(first.text)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.padding)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.padding)
            .padding(.top, 14)
            .accessibilityHint("Opens the comments")
        }
    }

    // MARK: Up next

    @ViewBuilder
    private var relatedList: some View {
        if !model.related.isEmpty {
            Text("Up next")
                .font(.headline)
                .padding(.horizontal, Theme.padding)
                .padding(.top, 22)
                .padding(.bottom, 6)

            ForEach(model.related) { related in
                Button {
                    env.open(related, queue: [])
                } label: {
                    VideoRowView(video: related)
                }
                .buttonStyle(.plain)
                .videoContextMenu(related)
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 6)
                .onAppear {
                    Task { await model.loadMoreRelatedIfNeeded(currentID: related.id, using: env) }
                }
            }

            if model.isLoadingMoreRelated {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }
}

/// How far the page is scrolled and how tall it is, as the scroll view reports it.
private struct PageScroll: Equatable {
    var offset: CGFloat
    var height: CGFloat
}

/// What the page remembers about its scroll position. A plain object, not state: remembering must not redraw the page
/// at every frame of a scroll.
private final class PageScrollMemory {
    var offset: CGFloat?
    var isCollapsed = false
}

/// A rounded action chip: an icon and a short label on a soft background, in the primary colour or a tint.
private struct ChipLabel: View {
    let title: String
    let systemImage: String
    var tint: Color?

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint ?? Color.primary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemFill), in: Capsule())
            .fixedSize()
    }
}

#if DEBUG
extension View {
    /// Simulator checks: with the launch argument `-debugWatchDetails YES` the screen this is attached to presents
    /// the watch page in a sheet once, without a player. `-debugWatchDetails <videoID>` picks a sample video other
    /// than the Rick Astley one. Compiled out of Release builds.
    func debugWatchDetailsSheet() -> some View {
        modifier(DebugWatchDetailsModifier())
    }
}

extension View {
    /// Simulator checks: with the launch argument `-watchPage '<steps>'` the watch page scrolls, expands its title and
    /// opens the Comments sheet by itself, once the page has loaded (see `DebugLaunchHooks`). Compiled out of Release
    /// builds.
    @ViewBuilder
    fileprivate func debugWatchPageSteps(
        isLoaded: Bool,
        isTitleExpanded: Binding<Bool>,
        isShowingComments: Binding<Bool>
    ) -> some View {
        if DebugLaunchHooks.watchPageSteps.isEmpty {
            self
        } else {
            modifier(DebugWatchPageModifier(isLoaded: isLoaded, isTitleExpanded: isTitleExpanded, isShowingComments: isShowingComments))
        }
    }
}

private struct DebugWatchPageModifier: ViewModifier {
    let isLoaded: Bool
    @Binding var isTitleExpanded: Bool
    @Binding var isShowingComments: Bool

    func body(content: Content) -> some View {
        content
            .task(id: isLoaded) {
                guard isLoaded else { return }
                // Lists below the description are still being measured for a moment after the page has loaded.
                try? await Task.sleep(for: .seconds(1.5))
                if DebugLaunchHooks.takeWatchPageStep("title") != nil {
                    isTitleExpanded = true
                }
                if let points = DebugLaunchHooks.takeWatchPageStep("scroll").flatMap(Double.init) {
                    DebugLaunchHooks.scrollWatchPage(to: points)
                }
                if DebugLaunchHooks.takeWatchPageStep("comments") != nil {
                    try? await Task.sleep(for: .seconds(1))
                    isShowingComments = true
                }
            }
    }
}

private struct DebugWatchDetailsModifier: ViewModifier {
    @State private var video: VideoSummary? = {
        guard let argument = UserDefaults.standard.string(forKey: "debugWatchDetails"), !argument.isEmpty else { return nil }
        let id = argument.count == 11 ? argument : "dQw4w9WgXcQ"
        return SampleData.video(id: id) ?? SampleData.videos.first
    }()

    func body(content: Content) -> some View {
        content.sheet(item: $video) { video in
            WatchDetailsView(video: video)
        }
    }
}
#endif

#Preview {
    WatchDetailsView(video: SampleData.videos[3])
        .environment(AppEnvironment.preview())
}
