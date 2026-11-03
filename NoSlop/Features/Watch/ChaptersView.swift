import NoSlopKit
import SwiftUI

/// The chapters of the video as a horizontal row of cards. Tapping one seeks the player to it; the chapter that is
/// playing is outlined.
struct ChaptersView: View {
    let chapters: [Chapter]

    @Environment(AppEnvironment.self) private var env

    private static let cardWidth: CGFloat = 150

    var body: some View {
        let current = currentIndex()

        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters")
                .font(.headline)
                .padding(.horizontal, Theme.padding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            env.player.seek(to: chapter.startSeconds)
                        } label: {
                            card(for: chapter, isCurrent: index == current)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapter.title), \(timeText(chapter))")
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Theme.padding)
            }
        }
    }

    private func card(for chapter: Chapter, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail(for: chapter)
                .frame(width: Self.cardWidth, height: Self.cardWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: isCurrent ? 2 : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    // Without a picture the start time is the card's content (see `thumbnail(for:)`).
                    if chapter.thumbnailURL != nil {
                        Text(timeText(chapter))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(6)
                    }
                }

            Text(chapter.title)
                .font(.caption)
                .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: Self.cardWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func thumbnail(for chapter: Chapter) -> some View {
        if let url = chapter.thumbnailURL {
            RemoteImage(url: url, contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    Text(timeText(chapter))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// "1:00". A start time that is not a sane number (parsed from a web page) shows as 0:00 instead of trapping.
    private func timeText(_ chapter: Chapter) -> String {
        let start = chapter.startSeconds
        let seconds = start.isFinite ? min(max(0, start), 360_000) : 0
        return DurationFormatter.string(seconds: Int(seconds))
    }

    /// The last chapter that has started; nil while this video is not the one playing.
    private func currentIndex() -> Int? {
        guard env.player.currentVideo != nil else { return nil }
        let time = env.player.currentTime
        return chapters.lastIndex { $0.startSeconds <= time }
    }
}

#Preview {
    ChaptersView(chapters: SampleData.chapters)
        .environment(AppEnvironment.preview())
}
