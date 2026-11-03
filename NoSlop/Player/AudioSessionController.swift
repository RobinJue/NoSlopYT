import AVFoundation
import Foundation

/// The app's audio session: category `.playback` with mode `.moviePlayback`, which is what makes sound play with the
/// silent switch on, keep playing when the app is in the background or the screen is locked (the `audio` background
/// mode is in Info.plist), and show up in Control Center and on the lock screen.
///
/// It also reports the three things a player has to react to: another app or a call taking the audio, the output
/// device going away (headphones unplugged, AirPlay dropped), and the system suggesting to resume afterwards.
@MainActor
final class AudioSessionController {
    /// Another app or a call took the audio. The system has already paused the player.
    var onInterruptionBegan: (() -> Void)?
    /// The interruption is over; `shouldResume` is true when the system suggests carrying on.
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// The output device went away: pause, like every video app does.
    var onOutputDeviceUnavailable: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var tokens: [any NSObjectProtocol] = []
    private var isActive = false

    init() {
        let center = NotificationCenter.default

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated { self?.interruption(type: type, options: options) }
        })

        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.routeChange(reason: reason) }
        })

        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        })
    }

    /// Configures and activates the session. Safe to call again; failures are not fatal (the video still plays, but
    /// the silent switch mutes it and background audio does not work).
    func activate() {
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            isActive = true
        } catch {
            isActive = false
        }
    }

    /// Gives the audio back to whoever had it (a music app resumes). Only call once the player stopped.
    func deactivate() {
        guard isActive else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    // MARK: Notifications

    private func interruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            onInterruptionEnded?(options.contains(.shouldResume))
        default:
            break
        }
    }

    private func routeChange(reason: AVAudioSession.RouteChangeReason?) {
        if reason == .oldDeviceUnavailable {
            onOutputDeviceUnavailable?()
        }
    }

    private func mediaServicesWereReset() {
        // The audio daemon restarted and forgot our configuration.
        if isActive {
            activate()
        }
    }
}
