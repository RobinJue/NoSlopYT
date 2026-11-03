import AVFoundation
import AVKit
import Foundation
import UIKit

/// Picture in Picture for the one `AVPlayer`, and the registry of the video layers that show it.
///
/// Every `VideoSurfaceView` registers its `AVPlayerLayer` here. The most recent layer is the one Picture in Picture
/// is bound to (the expanded player and the mini player take turns). The registry is also how the player detaches
/// the video from every layer when the app goes to the background without PiP: iOS pauses a player that still renders
/// into a layer then, and detaching is the documented way to keep the audio going.
@MainActor
final class PictureInPictureController: NSObject, AVPictureInPictureControllerDelegate {
    /// PiP became active or inactive.
    var onActiveChange: ((Bool) -> Void)?
    /// `isPossible` changed.
    var onPossibleChange: ((Bool) -> Void)?
    /// The user tapped the "restore" button of the PiP window: bring the full player back.
    var onRestoreUserInterface: (() -> Void)?

    /// Picture in Picture is on screen.
    private(set) var isActive = false
    /// The system announced that PiP is about to start (for example automatically when the app goes to the background).
    private(set) var isStarting = false
    /// PiP could start right now.
    private(set) var isPossible = false

    /// Whether PiP should start by itself when the app goes to the background while the video plays inline.
    var startsAutomaticallyFromInline = false {
        didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline }
    }

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private let player: AVPlayer
    private var controller: AVPictureInPictureController?
    private weak var boundLayer: AVPlayerLayer?
    private var possibleObservation: NSKeyValueObservation?
    private let layers = NSHashTable<AVPlayerLayer>.weakObjects()
    private var surfacesAttached = true

    init(player: AVPlayer) {
        self.player = player
        super.init()
    }

    // MARK: Layer registry

    /// Called by `VideoSurfaceView` when it creates its layer.
    func register(_ layer: AVPlayerLayer) {
        layers.add(layer)
        layer.player = surfacesAttached ? player : nil
        bind(to: layer)
    }

    /// Called by `VideoSurfaceView` when it goes away.
    func unregister(_ layer: AVPlayerLayer) {
        layers.remove(layer)
        guard boundLayer === layer else { return }
        if isActive || isStarting {
            // PiP keeps running on the layer it was started with; re-bind once it ends.
            return
        }
        if let latest = layers.allObjects.last {
            bind(to: latest)
        } else {
            teardown()
        }
    }

    /// Detaches the player from every video layer (false) or attaches it again (true).
    func setSurfacesAttached(_ attached: Bool) {
        surfacesAttached = attached
        for layer in layers.allObjects {
            layer.player = attached ? player : nil
        }
    }

    // MARK: Control

    func start() {
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: Binding

    private func bind(to layer: AVPlayerLayer) {
        guard Self.isSupported else { return }
        if isActive || isStarting { return }
        if boundLayer === layer, controller != nil { return }

        possibleObservation = nil
        controller = nil
        boundLayer = nil
        setPossible(false)

        guard let created = AVPictureInPictureController(playerLayer: layer) else { return }
        created.delegate = self
        created.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline
        possibleObservation = created.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in self?.setPossible(possible) }
        }
        controller = created
        boundLayer = layer
    }

    private func teardown() {
        possibleObservation = nil
        controller = nil
        boundLayer = nil
        setPossible(false)
    }

    private func setPossible(_ possible: Bool) {
        guard isPossible != possible else { return }
        isPossible = possible
        onPossibleChange?(possible)
    }

    /// After PiP ended: the layer on screen now may not be the one PiP was bound to.
    private func rebindToLatestLayer() {
        guard !isActive, !isStarting else { return }
        if let latest = layers.allObjects.last {
            bind(to: latest)
        } else {
            teardown()
        }
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = true
        onActiveChange?(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isStarting = false
        isActive = false
        onActiveChange?(false)
        rebindToLatestLayer()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = false
        onActiveChange?(false)
        rebindToLatestLayer()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onRestoreUserInterface?()
        completionHandler(true)
    }
}
