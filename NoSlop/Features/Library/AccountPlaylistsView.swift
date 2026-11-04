import NoSlopKit
import SwiftUI

/// The playlists of the signed-in YouTube account. A row opens the playlist.
struct AccountPlaylistsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if env.googleAccount == nil {
                EmptyStateView(
                    title: "Sign in to see your playlists",
                    systemImage: "rectangle.stack",
                    message: "These are the playlists of your YouTube account. Sign in with Google at the top of the Library tab."
                )
            } else {
                PlaylistsList()
            }
        }
        .navigationTitle("YouTube playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaylistsList: View {
    private enum Phase {
        case loading
        case loaded([PlaylistSummary])
        case failed(Error)
    }

    @Environment(AppEnvironment.self) private var env
    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                LoadingView()
            case .failed(let error):
                ErrorStateView(error: error) {
                    await load()
                }
            case .loaded(let playlists):
                if playlists.isEmpty {
                    EmptyStateView(
                        title: "No playlists",
                        systemImage: "rectangle.stack",
                        message: "Playlists you create on YouTube appear here."
                    )
                } else {
                    // A stack, not a List, like the playlists in search results: the count badge of the row
                    // is a Label, which a List would give a wide icon column.
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(playlists) { playlist in
                                Button {
                                    env.show(.accountPlaylist(playlist))
                                } label: {
                                    PlaylistRowView(playlist: playlist)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, Theme.padding)
                            }
                        }
                        .padding(.vertical, Theme.padding)
                    }
                    .refreshable { await load() }
                    .miniPlayerClearance()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if case .loaded = phase {
            // A refresh keeps showing the list; only a failure of the first load shows an error.
        } else {
            phase = .loading
        }
        do {
            // Through the environment, which notices when the failure was a session that Google ended.
            let playlists = try await env.viaAccount { try await $0.myPlaylists() }
            guard !Task.isCancelled else { return }
            phase = .loaded(playlists)
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded = phase { return }
            phase = .failed(error)
        }
    }
}

#Preview {
    NavigationStack {
        AccountPlaylistsView()
    }
    .environment(AppEnvironment.preview())
}
