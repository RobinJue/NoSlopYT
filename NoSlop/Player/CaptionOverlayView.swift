import SwiftUI

/// The current caption line: white text on a translucent black background, centred at the bottom of the video.
/// `liftsAboveControls` moves it up while the playback controls are on screen so the two never overlap.
struct CaptionOverlayView: View {
    let text: String
    var isLarge = false
    var liftsAboveControls = false

    var body: some View {
        Text(text)
            .font(.system(size: isLarge ? 22 : 14, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, liftsAboveControls ? (isLarge ? 84 : 66) : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut(duration: 0.2), value: liftsAboveControls)
            .allowsHitTesting(false)
            .accessibilityLabel("Caption: \(text)")
    }
}

#Preview {
    ZStack {
        Color.gray
        CaptionOverlayView(text: "We're no strangers to love\nYou know the rules and so do I")
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
}
