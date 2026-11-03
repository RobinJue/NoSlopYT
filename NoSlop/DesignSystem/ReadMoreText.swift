import SwiftUI

/// A block of text cut off after a few lines, with "more" / "Show less" when there is something to reveal.
/// Tapping the text or the button toggles it. Short text shows no button.
struct ReadMoreText: View {
    let text: String
    var lineLimit = 3

    @State private var isExpanded = false
    /// Whether the text needs more room than `lineLimit` lines. Measured while collapsed and kept while expanded.
    @State private var isTruncated = false
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .lineLimit(isExpanded ? nil : lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    limitedHeight = height
                    updateTruncation()
                }
                .background {
                    // The same text at its natural height, invisible, only to learn whether the limit cuts it off.
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            fullHeight = height
                            updateTruncation()
                        }
                }

            if isTruncated {
                Text(isExpanded ? "Show less" : "more")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isTruncated else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTruncated ? .isButton : [])
        .accessibilityHint(isTruncated ? (isExpanded ? "Shows less" : "Shows the full text") : "")
    }

    private func updateTruncation() {
        // While expanded the visible text is as tall as the full text, so the answer from the collapsed state stays.
        guard !isExpanded else { return }
        isTruncated = fullHeight > limitedHeight + 1
    }
}

#Preview("Read more") {
    ReadMoreText(text: String(repeating: "A long description that goes on and on. ", count: 12))
        .padding()
}
