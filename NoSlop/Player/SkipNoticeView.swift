import NoSlopKit
import SwiftUI

/// "Skipped sponsor · Undo": the toast shown for a few seconds after SponsorBlock jumped over a segment.
///
/// A fixed 28 pt tall, so that `PlayerOverlayTexts` can place it in the strip below the top bar without touching the
/// centre buttons. Its text follows the viewer's text size up to a limit that keeps it that size.
struct SkipNoticeView: View {
    let notice: PlayerController.SkipNotice
    let undo: () -> Void

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "forward.end.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Skipped \(notice.segment.category.displayName.lowercased())")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.white.opacity(0.6))
            Button(action: undo) {
                Text("Undo")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .underline()
                    .padding(.horizontal, 6)
                    .frame(height: Self.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo skip")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ZStack {
        Color.gray
        SkipNoticeView(
            notice: PlayerController.SkipNotice(id: SampleData.segments[0].id, segment: SampleData.segments[0]),
            undo: {}
        )
    }
}
