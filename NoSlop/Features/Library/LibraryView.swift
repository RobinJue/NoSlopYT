import NoSlopKit
import SwiftUI

/// The Library tab: the account at the top, then history, Watch Later, downloads, the playlists on this device
/// (create, rename, delete), the account's liked videos and playlists when signed in, the subscriptions manager
/// and Settings.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistTitle = ""
    @State private var renamingPlaylistID: UUID?
    @State private var renameTitle = ""
    @State private var playlistToDelete: LocalPlaylist?

    var body: some View {
        List {
            Section {
                AccountHeaderView()
                    .padding(.vertical, 4)
                RecommendationsRow()
            }

            Section {
                row("History", systemImage: "clock.arrow.circlepath", route: .history)
                row("Watch Later", systemImage: "clock", detail: countText(env.library.watchLater.count), route: .watchLater)
                row("Downloads", systemImage: "arrow.down.circle", detail: downloadsDetail, route: .downloads)
                if env.googleAccount != nil {
                    row("Liked videos", systemImage: "hand.thumbsup", route: .likedVideos)
                    row("YouTube playlists", systemImage: "rectangle.stack", route: .accountPlaylists)
                }
            }

            playlistsSection

            Section {
                row(
                    "Subscriptions",
                    systemImage: "person.2",
                    detail: countText(env.library.subscriptions.count),
                    route: .subscriptionsManager
                )
                row("Settings", systemImage: "gearshape", route: .settings)
            }
        }
        .miniPlayerClearance()
        .navigationTitle("Library")
        .refreshable { await env.refreshAccount() }
        .alert("New playlist", isPresented: $isCreatingPlaylist) {
            TextField("Title", text: $newPlaylistTitle)
            Button("Create") {
                env.library.createPlaylist(title: newPlaylistTitle)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename playlist",
            isPresented: Binding(
                get: { renamingPlaylistID != nil },
                set: { if !$0 { renamingPlaylistID = nil } }
            )
        ) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                if let id = renamingPlaylistID {
                    env.library.renamePlaylist(id, title: renameTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // An alert, shown from the list itself: a swipe action closes its row, and a dialog attached to that row
        // would be lost with it.
        .alert(
            "Delete \u{201C}\(playlistToDelete?.title ?? "")\u{201D}?",
            isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            ),
            presenting: playlistToDelete
        ) { playlist in
            Button("Delete", role: .destructive) {
                env.library.deletePlaylist(playlist.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only the list on this device is removed.")
        }
        #if DEBUG
        .debugWatchDetailsSheet()
        #endif
    }

    // MARK: Playlists

    private var playlistsSection: some View {
        Section {
            ForEach(env.library.playlists) { playlist in
                NavigationLink(value: Route.localPlaylist(id: playlist.id)) {
                    LibraryRowLabel(
                        title: playlist.title,
                        systemImage: "music.note.list",
                        detail: countText(playlist.videos.count)
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        beginRename(playlist)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        beginRename(playlist)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                newPlaylistTitle = ""
                isCreatingPlaylist = true
            } label: {
                Label("New playlist", systemImage: "plus")
            }
        } header: {
            Text("Playlists")
        }
    }

    private func beginRename(_ playlist: LocalPlaylist) {
        renameTitle = playlist.title
        renamingPlaylistID = playlist.id
    }

    // MARK: Rows

    private func row(_ title: String, systemImage: String, detail: String? = nil, route: Route) -> some View {
        NavigationLink(value: route) {
            LibraryRowLabel(title: title, systemImage: systemImage, detail: detail)
        }
    }

    /// Nothing for an empty list, otherwise the number.
    private func countText(_ count: Int) -> String? {
        count == 0 ? nil : count.formatted()
    }

    /// "3" finished downloads, plus "1 downloading" while something is running.
    private var downloadsDetail: String? {
        let items = env.downloads.items
        let finished = items.filter { $0.state == .completed }.count
        let running = items.filter { [.queued, .downloading, .merging].contains($0.state) }.count
        var parts: [String] = []
        if finished > 0 { parts.append(finished.formatted()) }
        if running > 0 { parts.append("\(running) downloading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A Library row: an accent-coloured icon, the title and, on the right, a count or short status.
///
/// At accessibility text sizes the title and the status cannot share a line without the title being cut to a few
/// letters, so the title may wrap and the status goes under it.
private struct LibraryRowLabel: View {
    let title: String
    let systemImage: String
    let detail: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView()
            .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
    }
    .environment(AppEnvironment.preview())
}

#Preview("Accessibility text size") {
    NavigationStack {
        LibraryView()
            .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
    }
    .environment(AppEnvironment.preview())
    .dynamicTypeSize(.accessibility2)
}
