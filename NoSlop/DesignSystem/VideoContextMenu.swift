import NoSlopKit
import SwiftUI

extension View {
    /// The long-press menu for a video: Watch Later, Add to playlist, Download, Don't show this channel, Share.
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
            Button("720p") { env.downloads.enqueue(video: video, quality: .video(maxHeight: 720)) }
            Button("360p") { env.downloads.enqueue(video: video, quality: .video(maxHeight: 360)) }
            Button("Audio only") { env.downloads.enqueue(video: video, quality: .audioOnly) }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        if let channel = video.channel {
            Button(role: .destructive) {
                block(channel)
            } label: {
                Label("Don't show this channel", systemImage: "nosign")
            }
        }

        ShareLink(item: video.watchURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func block(_ channel: ChannelRef) {
        var settings = env.settingsStore.settings
        guard !settings.blockedChannels.contains(where: { $0.id == channel.id }) else { return }
        settings.blockedChannels.append(BlockedChannel(id: channel.id, name: channel.name))
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
