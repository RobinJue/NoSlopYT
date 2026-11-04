import NoSlopKit
import SwiftUI

/// The videos liked on the signed-in Google account, newest like first, loaded page by page and shown through the
/// feed filters (Shorts, blocked channels and words), like every other list. "Play all" and a row queue the whole list,
/// the pages that are not loaded yet included.
struct LikedVideosView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if env.googleAccount == nil {
                EmptyStateView(
                    title: "Sign in to see your likes",
                    systemImage: "hand.thumbsup",
                    message: "Liked videos come from your YouTube account. Sign in with Google at the top of the Library tab."
                )
            } else {
                LikedVideosList()
            }
        }
        .navigationTitle("Liked videos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LikedVideosList: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = AccountVideosModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingView()
            case .failed(let error):
                ErrorStateView(error: error) {
                    await model.reload(using: loader)
                }
            case .loaded:
                if model.videos.isEmpty {
                    AccountVideosEmptyView(
                        model: model,
                        loader: loader,
                        title: "No liked videos",
                        systemImage: "hand.thumbsup",
                        message: "Videos you like on YouTube, or with the Like button here, appear in this list."
                    )
                } else {
                    list
                }
            }
        }
        .task { await model.loadIfNeeded(using: loader) }
        // "Don't show this channel" (or any other feed filter) takes effect on the videos on screen, not after a
        // reload. Also when the screen comes back: the filter may have changed on a screen above it.
        .onChange(of: env.settings) {
            Task { await model.refilter(using: loader) }
        }
        .onAppear {
            Task { await model.refilter(using: loader) }
        }
    }

    private static let queueName = "Liked videos"

    private var list: some View {
        let videos = model.videos
        return List {
            HStack {
                LibraryPlayAllButton(videos: videos, queueName: Self.queueName, more: queueSource)
                Spacer(minLength: 0)
            }
            .listRowSeparator(.hidden)

            // Offsets, not video ids: nothing stops YouTube from listing a video twice.
            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                LibraryVideoRow(video: video) {
                    // "Play all" and a row queue the whole list: what is not loaded yet (a list of 3,000 likes has loaded
                    // 50) follows page by page while the queue plays.
                    env.open(video, queue: Array(videos[(index + 1)...]), more: queueSource(), queueName: Self.queueName)
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await model.loadMoreIfNeeded(at: index, using: loader) }
                }
            }

            AccountVideosFooter(model: model, loader: loader)
        }
        .listStyle(.plain)
        .miniPlayerClearance()
        .refreshable { await model.reload(using: loader) }
    }

    /// Where the pages come from, and what the viewer's filters leave out. Built per call, so it follows the settings.
    private var loader: AccountVideosModel.Loader {
        AccountVideosModel.Loader(
            source: { token in try await env.viaAccount { try await $0.likedVideos(pageToken: token) } },
            filter: { videos in env.contentFilter.filter(videos) }
        )
    }

    /// The pages of the list behind what is loaded, for the player's queue; nil when it is loaded to its end. Asked when
    /// the viewer taps, so it starts where the list is by then.
    private func queueSource() -> QueueSource? {
        model.queueSource(using: env) { account, token in try await account.likedVideos(pageToken: token) }
    }
}

/// A loaded account list that has no row to show, and why: more pages are being looked at (the filters hid the pages
/// so far), a page failed, loading paused, the filters hid everything, or there is really nothing.
struct AccountVideosEmptyView: View {
    let model: AccountVideosModel
    let loader: AccountVideosModel.Loader
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        if let error = model.loadMoreError {
            ErrorStateView(error: error) {
                await model.loadMore(using: loader)
            }
        } else if model.isPaused {
            ContentUnavailableView {
                Label("Nothing to show yet", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Your feed filters hid everything on the pages loaded so far. There may be more further on.")
            } actions: {
                Button("Keep looking") {
                    Task { await model.loadMore(using: loader) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.hasMore || model.isLoadingMore {
            LoadingView()
        } else if model.hiddenCount > 0 {
            EmptyStateView(
                title: "Nothing to show",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "Your feed filters hide everything in this list. You can change them in Settings."
            )
        } else {
            EmptyStateView(title: title, systemImage: systemImage, message: message)
        }
    }
}

/// The end of a paged account list: a spinner while the next page loads, a retry row after a failure, or "Show more"
/// when loading paused behind the filters.
struct AccountVideosFooter: View {
    let model: AccountVideosModel
    let loader: AccountVideosModel.Loader

    var body: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if model.loadMoreFailed {
            Button {
                Task { await model.loadMore(using: loader) }
            } label: {
                Label("Couldn't load more. Tap to retry.", systemImage: "arrow.clockwise")
                    .labelStyle(.tight)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
        } else if model.isPaused {
            Button {
                Task { await model.loadMore(using: loader) }
            } label: {
                Label("Show more", systemImage: "ellipsis.circle")
                    .labelStyle(.tight)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
        }
    }
}

#Preview {
    NavigationStack {
        LikedVideosView()
    }
    .environment(AppEnvironment.preview())
}
