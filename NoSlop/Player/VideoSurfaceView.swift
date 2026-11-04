import AVFoundation
import SwiftUI
import UIKit

/// The `AVPlayerLayer`-backed surface that shows the video. The layer is registered with
/// `PictureInPictureController`, which binds Picture in Picture to it and detaches the player from it when the app
/// goes to the background (so the audio keeps playing).
///
/// Several surfaces can exist at once (the expanded player and the mini player during a transition); they all show
/// the same `AVPlayer`.
///
/// The surface is transparent. Until the first frame is drawn, and wherever the picture does not reach (the bars of a
/// video that is not 16:9), what the caller put underneath shows: the thumbnail as a poster, on a black base. So every
/// caller draws its own black base below the surface; an opaque black surface would hide the poster for the seconds a
/// video takes to load.
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer
    /// Without it the surface just shows the player (no Picture in Picture, no background detaching).
    var pictureInPicture: PictureInPictureController?
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.isOpaque = false
        // Touches belong to the SwiftUI controls drawn on top of the video.
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.playerLayer.videoGravity = videoGravity
        view.pictureInPicture = pictureInPicture
        if let pictureInPicture {
            pictureInPicture.register(view.playerLayer)
        } else {
            view.playerLayer.player = player
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
        if pictureInPicture == nil, view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.pictureInPicture?.unregister(view.playerLayer)
    }
}

/// A view whose backing layer is an `AVPlayerLayer`.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    /// Kept so the surface can unregister itself when SwiftUI removes it.
    var pictureInPicture: PictureInPictureController?

    var playerLayer: AVPlayerLayer {
        // `layerClass` guarantees the type.
        layer as! AVPlayerLayer
    }
}
