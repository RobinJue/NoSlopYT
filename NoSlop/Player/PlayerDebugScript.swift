#if DEBUG
import Foundation
import MediaAccessibility
import NoSlopKit
import UIKit

/// Checks in the simulator that links cannot reach, driven by a launch argument. Debug builds only.
///
///     xcrun simctl launch <udid> com.robinjungerich.noslopyt -mockServices YES \
///         -openURL 'noslop://watch?v=aqz-KE-bpKQ' -playerScript 'wait=8;quality=360;wait=6;log=after'
///
/// The steps run in order, separated by `;`, once the first video plays:
///
/// - `wait=<seconds>`, `waitPlaying` (until the video plays), `waitVideo` (until another video is the current one;
///   `waitVideo=<seconds>` gives up after that long)
/// - `hops=<count>[,<seconds before the end>]` plays on from video to video: for each hop it waits until the video plays,
///   jumps to the end (2 s before it unless told otherwise), waits up to 25 s for another video to start and logs the
///   state (`hop <n>`). It stops at the first hop that no video follows.
/// - `next` is the Next button of the controls and of the lock screen (`playNext`: the next queued video, or without a
///   queue the first unwatched Up next video), `jump=<n>` a tap on the n-th row of "Playing from ..." on the watch page (1
///   is the next video of the queue), `watched=<video id>[,<video id>...]` records a minute of each sample video in the
///   history, so that autoplay passes it over, `scrollPage=<points>` scrolls the watch page
/// - `quality=<auto|1080|720|480|360>` (a pick), `capQuality=<...>` (only the cap, as the connection sets it),
///   `rate=<speed>`, `pause`, `play`
/// - `systemPause`, `systemPlay` reach the `AVPlayer` directly, as the Picture in Picture window or an AirPlay remote
///   does, without `pause()` and `play()` of the controller
/// - `fail` ends the video with the error screen (`failLong`: with the long reason YouTube gives for an age-restricted
///   video; `failGone`: for a video YouTube will not hand out, whose screen has no Retry), `retry` is its Retry button, `reopen` opens the current video again
///   (a link to it), `openStaleLive=<video id>` opens a video whose saved copy still says live and upcoming (a row
///   of Watch Later after the broadcast ended)
/// - `failNotYet` and `failVerdict` end the video with the error that YouTube's `player` endpoint gives for a live event that
///   has not begun (`notPlayableYet`: Retry) and for a video it will not hand out (`unplayable`: no Retry), whatever copy of the
///   video was opened. `failDecode` is a playback failure of the item that cannot be decoded (`PlaybackFailure.decode`: no
///   Retry, except for a download, whose Retry streams the video instead)
/// - `seek=<seconds>`, `seekEnd=<seconds before the end>`, `undo` (the skip notice's Undo)
/// - `playerServices=<on|off>` switches the connection of the services the player asks (stream info, SponsorBlock,
///   captions; see `-offlinePlayerServices`), for example to let the live answers arrive while a download plays with the
///   ones it kept
/// - `captions=<on|off>`, `fullscreen`, `minimize`, `expand`, `autoplay=<on|off>`, `sponsorBlock=<on|off>`,
///   `deArrow=<on|off>` ("De-clickbait titles"), `notice` (shows the skip notice and leaves it up)
/// - `segment=<start>-<end>[@<length>]` adds a SponsorBlock segment (`@` is the length of the video it was submitted
///   for), `endSegment=<seconds before the end>[,<seconds past it>]` adds one that runs to the end of the video,
///   `highlight=<seconds>` adds a highlight (a moment, `poi_highlight`) at that second
/// - `terminate` ends the process the way iOS does when it is about to end it: the notice that the process will end is
///   posted from the main run loop, with no dispatch queue around it (as UIKit posts it), and the process exits in the
///   same breath. What the app saved by then is all that survives, so this is the last step of a script. In a mock run
///   the library is in the app's `tmp` folder (`NoSlop-Preview-<id>/Library`).
/// - `log=<tag>` writes the state of the player to the log, `watch=<seconds>` does so every second meanwhile,
///   `axdump=<tag>` writes the accessibility elements of this moment to `<Documents>/ax-<tag>.txt` (see
///   `AccessibilityDump`), `axescape` is the two-finger scrub of VoiceOver with the focus on the video,
///   `captionStyle=<parts separated by |>` changes the caption style the way Settings does while the app runs (see
///   `-captionStyle`: `captionStyle=size=2|text=yellow`), `captionStyle=` puts the standard look back
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
                await wait(until: { player.currentVideo?.id != before }, upTo: Double(value) ?? 90)
            case "hops":
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                let secondsBeforeEnd = numbers.count > 1 ? numbers[1] : 2
                for hop in 1...max(Int(numbers.first ?? 1), 1) {
                    await wait(until: { player.state == .playing }, upTo: 20)
                    let current = player.currentVideo?.id
                    player.seek(to: player.duration - secondsBeforeEnd)
                    await wait(until: { player.currentVideo?.id != current }, upTo: 25)
                    player.debugLogSnapshot("hop \(hop)")
                    if player.currentVideo?.id == current { break }
                }
            case "next":
                _ = player.playNext()
            case "jump":
                if let number = Int(value), number >= 1, number <= player.queue.count {
                    player.playQueued(at: number - 1, expecting: player.queue[number - 1].id)
                }
            case "scrollPage":
                if let points = Double(value) { DebugLaunchHooks.scrollWatchPage(to: points) }
            case "watched":
                for id in value.split(separator: ",") { player.debugMarkWatched(String(id)) }
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
            case "failLong":
                player.debugFail(
                    message: "This video may be inappropriate for some users. Sign in to confirm your age, or open it on YouTube "
                        + "in a browser where you are signed in. Videos like this one cannot be played in No Slop."
                )
            case "failGone":
                player.debugFail(message: "This video is private.", isWorthRetrying: false)
            case "failNotYet":
                player.debugFail(with: NoSlopError.notPlayableYet(reason: "This live event will begin in 2 hours."))
            case "failVerdict":
                player.debugFail(with: NoSlopError.unplayable(reason: "This video is private."))
            case "failDecode":
                player.debugFailPlayback(.decode)
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
            case "playerServices":
                DebugLaunchHooks.playerConnection.isOnline = value == "on"
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
            case "highlight":
                if let seconds = Double(value) { player.debugAddHighlight(at: seconds) }
            case "endSegment":
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                if let before = numbers.first {
                    let end = player.duration + (numbers.count > 1 ? numbers[1] : 0)
                    player.debugAddSegment(start: player.duration - before, end: end)
                }
            case "axdump":
                AccessibilityDump.write(tag: value)
            case "captionStyle":
                // What Settings does: the style changes and the system tells the apps with this notification.
                UserDefaults.standard.set(value.replacingOccurrences(of: "|", with: ";"), forKey: "captionStyle")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetLocalCenter(),
                    CFNotificationName(kMACaptionAppearanceSettingsChangedNotification),
                    nil,
                    nil,
                    true
                )
            case "axescape":
                _ = AccessibilityDump.performEscape(startingAtLabel: value.isEmpty ? "Video" : value)
            case "terminate":
                let noticeName = UIApplication.willTerminateNotification
                let block: @convention(block) () -> Void = {
                    NotificationCenter.default.post(name: noticeName, object: nil)
                    exit(0)
                }
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
                CFRunLoopWakeUp(CFRunLoopGetMain())
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
