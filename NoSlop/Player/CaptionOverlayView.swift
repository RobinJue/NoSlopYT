import SwiftUI
import UIKit

/// The current caption line: white text on a translucent black background, centred in the strip `PlayerOverlayTexts`
/// gives it (along the bottom edge while the controls are hidden, above the bottom bar while they show).
struct CaptionOverlayView: View {
    enum Size {
        /// The usual size.
        case regular
        /// Smaller, for a strip that cannot hold two lines of the usual one.
        case compact
        /// Compact, on a single line (line breaks become spaces; what still does not fit is scaled down, then cut).
        case oneLine
    }

    let text: String
    var isLarge = false
    var size: Size = .regular

    var body: some View {
        Text(size == .oneLine ? Self.singleLine(text) : text)
            .font(.system(size: Self.fontSize(size, isLarge: isLarge), weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(size == .oneLine ? 1 : nil)
            .minimumScaleFactor(size == .oneLine ? 0.75 : 1)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, Self.verticalPadding(size))
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            .accessibilityLabel("Caption: \(text)")
    }

    static func fontSize(_ size: Size, isLarge: Bool) -> CGFloat {
        switch size {
        case .regular: isLarge ? 22 : 14
        case .compact, .oneLine: isLarge ? 16 : 12
        }
    }

    static func verticalPadding(_ size: Size) -> CGFloat {
        size == .regular ? 3 : 2
    }

    /// The height of `lines` lines of caption at `size`, background included.
    static func height(lines: Int, size: Size, isLarge: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize(size, isLarge: isLarge), weight: .medium)
        return ceil(font.lineHeight) * CGFloat(lines) + 2 * verticalPadding(size)
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// The caption at the largest size that fits the height it is given: the usual size, then smaller, then on one line,
/// and nothing when not even that fits (a caption on top of a button is worse than a missing one).
struct FittingCaptionView: View {
    let text: String
    var isLarge = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            CaptionOverlayView(text: text, isLarge: isLarge, size: .regular)
            CaptionOverlayView(text: text, isLarge: isLarge, size: .compact)
            CaptionOverlayView(text: text, isLarge: isLarge, size: .oneLine)
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

#Preview {
    ZStack {
        Color.gray
        FittingCaptionView(text: "We're no strangers to love\nYou know the rules and so do I")
            .frame(maxHeight: .infinity, alignment: .bottom)
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
}
