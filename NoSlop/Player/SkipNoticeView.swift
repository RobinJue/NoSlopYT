import NoSlopKit
import SwiftUI

/// "Skipped sponsor · Undo": the toast shown for a few seconds after SponsorBlock jumped over a segment.
struct SkipNoticeView: View {
    let notice: PlayerController.SkipNotice
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "forward.end.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Skipped \(notice.segment.category.displayName.lowercased())")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
            Text("·")
                .foregroundStyle(.white.opacity(0.6))
            Button(action: undo) {
                Text("Undo")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .underline()
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo skip")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
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
