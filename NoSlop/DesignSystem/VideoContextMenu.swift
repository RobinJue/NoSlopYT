import NoSlopKit
import SwiftUI

extension View {
    /// The long-press menu for a video: Watch Later, Add to playlist, Download, Don't show this channel (Show this
    /// channel again, once it is blocked), Share. `homeCard` is true only for a card of YouTube's Home, the one place
    /// where Not interested and the account-wide effect of Don't show this channel are offered.
    func videoContextMenu(_ video: VideoSummary, homeCard: Bool = false) -> some View {
        modifier(VideoContextMenuModifier(video: video, homeCard: homeCard))
    }
}

private struct VideoContextMenuModifier: ViewModifier {
    let video: VideoSummary
    let homeCard: Bool

    @Environment(AppEnvironment.self) private var env
    @State private var isPickingPlaylist = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .sheet(isPresented: $isPickingPlaylist) {
                LocalPlaylistPickerSheet(video: video)
            }
    }

    /// Only a card shown on YouTube's Home (it has a menu there), while the connection and its switches are on. The
    /// same video in a search, a channel, the library or the queue does not get it: the surface decides, not the id.
    private var offersNotInterested: Bool {
        homeCard && env.recommendationsAccount != nil && env.settings.showYouTubeHome && env.settings.tellYouTubeAboutHiding
            && env.recommendationCardIDs.contains(video.id)
    }

    /// Hides the card at once and tells YouTube in the background. What YouTube answers goes to Diagnostics only.
    private func notInterested() {
        let id = video.id
        HomeCardDismissals.shared.dismiss(id)
        let env = env
        Task(priority: .utility) {
            do {
                try await env.recommendations.notInterested(videoID: id)
            } catch NoSlopError.recommendationsNotConnected {
                await env.reconcileRecommendationsAccount()
            } catch {}
            await env.refreshRecommendationsDiagnostics()
        }
    }

    /// Blocking the channel of a card of YouTube's Home also tells YouTube, in the background.
    private func dontRecommend(_ channel: ChannelRef) {
        guard offersNotInterested else { return }
        let id = video.id
        let channelID = channel.id.isEmpty ? nil : channel.id
        let name = channel.name
        let env = env
        Task(priority: .utility) {
            do {
                _ = try await env.recommendations.dontRecommendChannel(videoID: id, channelID: channelID, channelName: name)
            } catch NoSlopError.recommendationsNotConnected {
                await env.reconcileRecommendationsAccount()
            } catch {}
            await env.refreshRecommendationsDiagnostics()
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

        if offersNotInterested {
            Button {
                notInterested()
            } label: {
                Label("Not interested", systemImage: "hand.thumbsdown")
            }
        }

        // A channel without an id (a tile of YouTube's Home) is looked up when it is blocked; one without a name either
        // has nothing to be recognised by.
        if let channel = video.channel, !channel.id.isEmpty || !channel.name.isEmpty {
            if let blocked = ChannelBlocking.blockedChannel(channel, using: env) {
                // Library lists (also as the "Playing from ..." queue under the player, the list as it was when it was
                // opened) and the channel's own page show a blocked channel's videos on purpose, so the menu is where the
                // block is seen to have worked, and where it is undone. The player's Up next is not one of them: it
                // follows the settings and drops the channel at once.
                Button {
                    ChannelBlocking.unblock(channelID: blocked.id, using: env)
                } label: {
                    Label("Show this channel again", systemImage: "checkmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    ChannelBlocking.block(channel, of: video, using: env)
                    dontRecommend(channel)
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
/// filtered list that is on screen (feeds, search, channels, playlists, the player's Up next, the account's liked
/// videos and playlists) listens to the settings and drops the channel's videos at once. Not so History, Watch Later
/// and your own playlists (they show everything you put there), the channel's own page (it would be empty) and the
/// queue that plays under the player, "Playing from ..." (the list as it was when it was opened): there the video
/// stays. That is why the menu of a blocked channel's video offers the undo, and why it is also where the block is
/// seen to have worked.
enum ChannelBlocking {
    static func isBlocked(_ channel: ChannelRef, using env: AppEnvironment) -> Bool {
        blockedChannel(channel, using: env) != nil
    }

    static func blockedChannel(_ channel: ChannelRef, using env: AppEnvironment) -> BlockedChannel? {
        env.settings.blockedChannel(matching: channel)
    }

    /// Blocks the channel of `video`. A channel that came without an id (a tile of YouTube's Home) is first resolved
    /// through the video's watch page, so the block holds by id; when that fails nothing is blocked.
    static func block(_ channel: ChannelRef, of video: VideoSummary? = nil, using env: AppEnvironment) {
        if !channel.id.isEmpty {
            add(channel, using: env)
            return
        }
        guard let video else { return }
        Task {
            guard let details = try? await env.youTube.videoDetails(id: video.id), !details.channel.id.isEmpty else { return }
            add(ChannelRef.resolvedForBlocking(details: details.channel, tile: channel), using: env)
        }
    }

    private static func add(_ channel: ChannelRef, using env: AppEnvironment) {
        var settings = env.settingsStore.settings
        guard settings.blockChannel(id: channel.id, name: channel.name, handle: channel.handle) else { return }
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
