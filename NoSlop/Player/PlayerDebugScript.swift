#if DEBUG
import Foundation
import NoSlopKit

/// Checks in the simulator that links cannot reach, driven by a launch argument. Debug builds only.
///
///     xcrun simctl launch <udid> com.robinjungerich.noslopyt -mockServices YES \
///         -openURL 'noslop://watch?v=aqz-KE-bpKQ' -playerScript 'wait=8;quality=360;wait=6;log=after'
///
/// The steps run in order, separated by `;`, once the first video plays:
///
/// - `wait=<seconds>`, `waitPlaying` (until the video plays), `waitVideo` (until another video is the current one)
/// - `quality=<auto|1080|720|480|360>` (a pick), `capQuality=<...>` (only the cap, as the connection sets it),
///   `rate=<speed>`, `pause`, `play`
/// - `systemPause`, `systemPlay` reach the `AVPlayer` directly, as the Picture in Picture window or an AirPlay remote
///   does, without `pause()` and `play()` of the controller
/// - `fail` ends the video with the error screen, `retry` is its Retry button, `reopen` opens the current video again
///   (a link to it), `openStaleLive=<video id>` opens a video whose saved copy still says live and upcoming (a row
///   of Watch Later after the broadcast ended)
/// - `seek=<seconds>`, `seekEnd=<seconds before the end>`, `undo` (the skip notice's Undo)
/// - `captions=<on|off>`, `fullscreen`, `minimize`, `expand`, `autoplay=<on|off>`, `sponsorBlock=<on|off>`,
///   `deArrow=<on|off>` ("De-clickbait titles"), `notice` (shows the skip notice and leaves it up)
/// - `segment=<start>-<end>[@<length>]` adds a SponsorBlock segment (`@` is the length of the video it was submitted
///   for), `endSegment=<seconds before the end>[,<seconds past it>]` adds one that runs to the end of the video
/// - `log=<tag>` writes the state of the player to the log, `watch=<seconds>` does so every second meanwhile
@MainActor
enum PlayerDebugScript {
    static func runIfRequested(on player: PlayerController) {
        guard let script = UserDefaults.standard.string(forKey: "playerScript"), !script.isEmpty else { return }
        Task { @MainActor in
            await run(script, on: player)
        }
    }

    private static func run(_ script: String, on player: PlayerController) async {
        await wait(until: { player.state == .playing }, upTo: 120)

        for step in script.split(separator: ";") {
            let parts = step.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            if name != "log", name != "watch", !name.hasPrefix("wait") {
                player.debugLogSnapshot("before \(name)=\(value)")
            }

            switch name {
            case "wait":
                try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "watch":
                for second in 0..<Int(Double(value) ?? 5) {
                    player.debugLogSnapshot("watch+\(second)")
                    try? await Task.sleep(for: .seconds(1))
                }
            case "waitPlaying":
                await wait(until: { player.state == .playing })
            case "waitVideo":
                let before = player.currentVideo?.id
                await wait(until: { player.currentVideo?.id != before })
            case "quality":
                let options: [String: QualityPreference] = ["auto": .auto, "1080": .p1080, "720": .p720, "480": .p480, "360": .p360]
                if let quality = options[value] { player.quality = quality }
            case "capQuality":
                let options: [String: QualityPreference] = ["auto": .auto, "1080": .p1080, "720": .p720, "480": .p480, "360": .p360]
                if let quality = options[value] { player.debugApplyCapOnly(quality) }
            case "rate":
                if let rate = Float(value) { player.rate = rate }
            case "pause":
                player.pause()
            case "play":
                player.play()
            case "systemPause":
                player.avPlayer.pause()
            case "systemPlay":
                player.avPlayer.play()
            case "fail":
                player.debugFail()
            case "retry":
                player.retry()
            case "reopen":
                player.debugReopen()
            case "openStaleLive":
                player.debugOpenStaleLive(id: value)
            case "seek":
                if let seconds = Double(value) { player.seek(to: seconds) }
            case "seekEnd":
                if let seconds = Double(value) { player.seek(to: player.duration - seconds) }
            case "undo":
                player.undoSkip()
            case "captions":
                if (value == "on") == (player.selectedCaption == nil) { player.toggleCaptions() }
            case "fullscreen":
                player.toggleFullscreen()
            case "minimize":
                player.minimize()
            case "expand":
                player.expand()
            case "notice":
                player.debugPinNotice()
            case "autoplay":
                player.debugSettingsStore.settings.autoplayNext = value == "on"
            case "sponsorBlock":
                player.debugSettingsStore.settings.sponsorBlockEnabled = value == "on"
            case "deArrow":
                player.debugSettingsStore.settings.deArrowTitles = value == "on"
            case "segment":
                let parts = value.split(separator: "@", maxSplits: 1)
                let range = (parts.first ?? "").split(separator: "-").compactMap { Double($0) }
                let length = parts.count > 1 ? Double(parts[1]) : nil
                if range.count == 2 { player.debugAddSegment(start: range[0], end: range[1], videoDuration: length) }
            case "endSegment":
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                if let before = numbers.first {
                    let end = player.duration + (numbers.count > 1 ? numbers[1] : 0)
                    player.debugAddSegment(start: player.duration - before, end: end)
                }
            case "log":
                break
            default:
                break
            }

            if name != "watch", !name.hasPrefix("wait") {
                player.debugLogSnapshot("after \(name)=\(value)")
            }
        }
    }

    /// Returns when `condition` holds, or after `limit` seconds.
    private static func wait(until condition: () -> Bool, upTo limit: Double = 90) async {
        var waited = 0.0
        while !condition(), waited < limit {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
    }
}
#endif
