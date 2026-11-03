import NoSlopKit
import SwiftUI

/// The videos liked on the signed-in Google account, newest like first, loaded page by page.
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
                    await model.reload(from: source)
                }
            case .loaded:
                if model.videos.isEmpty {
                    EmptyStateView(
                        title: "No liked videos",
                        systemImage: "hand.thumbsup",
                        message: "Videos you like on YouTube, or with the Like button here, appear in this list."
                    )
                } else {
                    list
                }
            }
        }
        .task { await model.reload(from: source) }
    }

    private var list: some View {
        let videos = model.videos
        return List {
            HStack {
                LibraryPlayAllButton(videos: videos)
                Spacer(minLength: 0)
            }
            .listRowSeparator(.hidden)

            // Offsets, not video ids: nothing stops YouTube from listing a video twice.
            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                LibraryVideoRow(video: video) {
                    env.open(video, queue: Array(videos[(index + 1)...]))
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await model.loadMoreIfNeeded(at: index, from: source) }
                }
            }

            AccountVideosFooter(model: model, source: source)
        }
        .listStyle(.plain)
        .refreshable { await model.reload(from: source) }
    }

    private var source: AccountVideosModel.PageSource {
        { token in try await env.account.likedVideos(pageToken: token) }
    }
}

/// The end of a paged account list: a spinner while the next page loads, or a retry row after a failure.
struct AccountVideosFooter: View {
    let model: AccountVideosModel
    let source: AccountVideosModel.PageSource

    var body: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if model.loadMoreFailed {
            Button {
                Task { await model.loadMore(from: source) }
            } label: {
                Label("Couldn't load more. Tap to retry.", systemImage: "arrow.clockwise")
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
