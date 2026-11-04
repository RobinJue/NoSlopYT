import NoSlopKit
import SwiftUI

extension View {
    /// The long-press menu for a video: Watch Later, Add to playlist, Download, Don't show this channel (Show this
    /// channel again, once it is blocked), Share.
    func videoContextMenu(_ video: VideoSummary) -> some View {
        modifier(VideoContextMenuModifier(video: video))
    }
}

private struct VideoContextMenuModifier: ViewModifier {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @State private var isPickingPlaylist = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .sheet(isPresented: $isPickingPlaylist) {
                LocalPlaylistPickerSheet(video: video)
            }
    }

    @ViewBuilder
    private var menu: some View {
        let saved = env.library.isInWatchLater(video.id)
        Button {
            env.library.toggleWatchLater(video)
        } label: {
            Label(
                saved ? "Remove from Watch Later" : "Save to Watch Later",
                systemImage: saved ? "clock.badge.checkmark" : "clock"
            )
        }

        Button {
            isPickingPlaylist = true
        } label: {
            Label("Add to playlist…", systemImage: "text.badge.plus")
        }

        Menu {
            // Named by the cap, not by a height: the download takes the tallest rendition the video has up to that
            // height, which may be a lower one (a video that stops at 480p is the 480p file for "up to 720p", and "up to
            // 360p" gives its 360p one). The Downloads list and the quality sheet name the rendition it really got.
            Button("Download up to 720p") { env.downloads.enqueue(video: video, quality: .video(maxHeight: 720)) }
            Button("Download up to 360p") { env.downloads.enqueue(video: video, quality: .video(maxHeight: 360)) }
            Button("Audio only") { env.downloads.enqueue(video: video, quality: .audioOnly) }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        // A channel without an id cannot be recognised later, so there is nothing to block.
        if let channel = video.channel, !channel.id.isEmpty {
            if ChannelBlocking.isBlocked(channel, using: env) {
                // Library lists, the channel's own page and the player's Up next show a blocked channel's videos on
                // purpose, so the menu is where the block is seen to have worked, and where it is undone.
                Button {
                    ChannelBlocking.unblock(channelID: channel.id, using: env)
                } label: {
                    Label("Show this channel again", systemImage: "checkmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    ChannelBlocking.block(channel, using: env)
                } label: {
                    Label("Don't show this channel", systemImage: "nosign")
                }
            }
        }

        ShareLink(item: video.watchURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

/// "Don't show this channel" and its undo, "Show this channel again": the blocked channels in the settings. Every
/// filtered list that is on screen (feeds, search, channels, playlists, the account's liked videos and playlists)
/// listens to the settings and drops the channel's videos at once. Not so History, Watch Later and your own playlists
/// (they show everything you put there), the channel's own page (it would be empty) and the player's Up next (filtered
/// when it was loaded): there the video stays. That is why the menu of a blocked channel's video offers the undo, and
/// why it is also where the block is seen to have worked.
enum ChannelBlocking {
    static func isBlocked(_ channel: ChannelRef, using env: AppEnvironment) -> Bool {
        env.settings.isBlocked(channelID: channel.id)
    }

    static func block(_ channel: ChannelRef, using env: AppEnvironment) {
        var settings = env.settingsStore.settings
        guard settings.blockChannel(id: channel.id, name: channel.name) else { return }
        env.settingsStore.settings = settings
    }

    static func unblock(channelID: String, using env: AppEnvironment) {
        var settings = env.settingsStore.settings
        guard settings.unblockChannel(id: channelID) else { return }
        env.settingsStore.settings = settings
    }
}

/// "Add to playlist…" from the context menu: the local playlists, with a checkmark where the video already is,
/// and "New playlist".
private struct LocalPlaylistPickerSheet: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newTitle = ""
                        isCreating = true
                    } label: {
                        Label("New playlist", systemImage: "plus")
                    }
                }

                if !env.library.playlists.isEmpty {
                    Section("Your playlists") {
                        ForEach(env.library.playlists) { playlist in
                            Button {
                                env.library.add(video, toPlaylist: playlist.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.title).foregroundStyle(.primary)
                                        Text(playlist.videos.count == 1 ? "1 video" : "\(playlist.videos.count) videos")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if playlist.videos.contains(where: { $0.id == video.id }) {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            // Plain, so the title is not tinted like an action; the whole row stays tappable.
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New playlist", isPresented: $isCreating) {
                TextField("Title", text: $newTitle)
                Button("Create") {
                    let playlist = env.library.createPlaylist(title: newTitle)
                    env.library.add(video, toPlaylist: playlist.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    VideoRowView(video: SampleData.videos[0])
        .videoContextMenu(SampleData.videos[0])
        .padding()
        .environment(AppEnvironment.preview())
}
