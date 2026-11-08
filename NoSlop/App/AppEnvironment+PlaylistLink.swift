import Foundation
import NoSlopKit

extension AppEnvironment {
    /// Pages after the first that are read to find the video of a playlist link; the first page is usually enough.
    private static let playlistLinkExtraPages = 3

    /// Queues the playlist of a link `watch?v=<videoID>&list=<playlistID>` behind the video that plays, the way "Play all"
    /// from that row would: the playlist's title names the queue, the videos after this one follow, and the pages not
    /// loaded yet come as the queue runs low. A playlist that cannot be loaded (a generated Mix, a private list, no
    /// network) leaves the video playing alone, without an error.
    func queuePlaylist(_ playlistID: String, behind videoID: String) {
        // A Mix ("RD…") is generated per viewer and YouTube does not list it as a playlist.
        guard !playlistID.hasPrefix("RD") else { return }
        Task { [weak self] in
            await self?.loadPlaylistQueue(playlistID, behind: videoID)
        }
    }

    private func loadPlaylistQueue(_ playlistID: String, behind videoID: String) async {
        do {
            let page = try await youTube.playlist(id: playlistID)
            var items = page.videos.items
            var seen = Set(items.map(\.id))
            var token = page.videos.continuation
            var extraPages = 0
            while !seen.contains(videoID), let current = token, extraPages < Self.playlistLinkExtraPages {
                // The player has moved on: nobody waits for this playlist any more.
                guard player.currentVideo?.id == videoID else { return }
                let more = try await youTube.playlistMore(continuation: current)
                token = more.continuation == current ? nil : more.continuation
                items += more.items.filter { seen.insert($0.id).inserted }
                extraPages += 1
            }
            guard player.currentVideo?.id == videoID else { return }

            let start = PlaylistQueueStart.make(videoID: videoID, in: items) { [weak self] videos in
                self?.contentFilter.filter(videos) ?? videos
            }
            let source = token.map { token in
                QueueSource(
                    continuation: token,
                    knownIDs: seen,
                    expectedTotal: page.info.videoCount,
                    fetch: { [weak self] token in
                        guard let self else { return Page() }
                        return try await self.youTube.playlistMore(continuation: token)
                    },
                    // Built per page, so a channel blocked while the queue plays counts from the next page on.
                    filter: { [weak self] videos in self?.contentFilter.filter(videos) ?? videos }
                )
            }
            let title = page.info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            player.joinPlaylist(
                ofVideo: videoID,
                position: start.position,
                queue: start.queued,
                more: source,
                named: title.isEmpty ? nil : title
            )
        } catch {
            // The playlist could not be read: the video plays on alone, as it was opened.
        }
    }
}
