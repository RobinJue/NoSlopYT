import CoreText
import SwiftUI
import UIKit

/// The current caption line, in the strip `PlayerOverlayTexts` gives it (along the bottom edge while the controls are
/// hidden, above the bottom bar while they show).
///
/// Without a caption style of the viewer's it is white text on a translucent black background, as it has always been.
/// The style from Settings > Accessibility > Subtitles & Captioning (size, font, colours, edge) is followed where the
/// system says it is meant for apps, and the text follows the viewer's text size (`CaptionStyle`, `CaptionScale`).
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
    var style = CaptionStyle()

    var body: some View {
        let appearance = style.appearance

        Text(size == .oneLine ? Self.singleLine(text) : text)
            .font(Font(style.font(size, isLarge: isLarge) as CTFont))
            .multilineTextAlignment(.center)
            .lineLimit(size == .oneLine ? 1 : nil)
            .minimumScaleFactor(size == .oneLine ? 0.75 : 1)
            .foregroundStyle(appearance.textColor.map(Color.init(uiColor:)) ?? .white)
            .captionEdge(appearance.edge)
            .padding(.horizontal, 8)
            .padding(.vertical, Self.verticalPadding(size))
            .background(
                appearance.backgroundColor.map(Color.init(uiColor:)) ?? Color.black.opacity(0.7),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .padding(style.windowInset)
            .background {
                if let window = appearance.windowColor {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(uiColor: window))
                }
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            .accessibilityLabel("Caption: \(text)")
    }

    static func verticalPadding(_ size: Size) -> CGFloat {
        size == .regular ? 3 : 2
    }

    /// The height of `lines` lines of caption at `size`, background (and window) included. The font is the one the
    /// caption is drawn with, so that `PlayerOverlayTexts` knows what fits between the controls.
    static func height(lines: Int, size: Size, isLarge: Bool, style: CaptionStyle = CaptionStyle()) -> CGFloat {
        let font = style.font(size, isLarge: isLarge)
        return ceil(font.lineHeight) * CGFloat(lines) + 2 * verticalPadding(size) + 2 * style.windowInset
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

private extension View {
    /// The edge of the letters, as the caption style asks for it. Shadows only: a hard one for raised and depressed,
    /// four of them for an outline, a soft one for a drop shadow.
    @ViewBuilder
    func captionEdge(_ edge: CaptionAppearance.Edge) -> some View {
        switch edge {
        case .none:
            self
        case .raised:
            shadow(color: .black, radius: 0, x: 1, y: 1)
        case .depressed:
            shadow(color: .black, radius: 0, x: -1, y: -1)
        case .uniform:
            shadow(color: .black, radius: 0, x: 1, y: 0)
                .shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1)
                .shadow(color: .black, radius: 0, x: 0, y: -1)
        case .dropShadow:
            shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 2)
        }
    }
}

/// The caption at the largest size that fits the height it is given: the usual size, then smaller, then on one line,
/// and nothing when not even that fits (a caption on top of a button is worse than a missing one).
struct FittingCaptionView: View {
    let text: String
    var isLarge = false
    var style = CaptionStyle()

    var body: some View {
        ViewThatFits(in: .vertical) {
            CaptionOverlayView(text: text, isLarge: isLarge, size: .regular, style: style)
            CaptionOverlayView(text: text, isLarge: isLarge, size: .compact, style: style)
            CaptionOverlayView(text: text, isLarge: isLarge, size: .oneLine, style: style)
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

#Preview("Large captions") {
    ZStack {
        Color.gray
        FittingCaptionView(
            text: "We're no strangers to love\nYou know the rules and so do I",
            style: CaptionStyle(
                appearance: CaptionAppearance(relativeSize: 2, textColor: .yellow, backgroundColor: .clear, edge: .dropShadow)
            )
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
}
