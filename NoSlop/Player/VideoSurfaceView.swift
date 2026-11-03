import AVFoundation
import SwiftUI
import UIKit

/// PLACEHOLDER (Task 1B). Task 10 owns this file: the `AVPlayerLayer`-backed surface that shows the video, which
/// it also registers with Picture in Picture. The type name is final; the initializer is Task 10's to define.
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// A view whose backing layer is an `AVPlayerLayer`.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // `layerClass` guarantees the type.
        layer as! AVPlayerLayer
    }
}
