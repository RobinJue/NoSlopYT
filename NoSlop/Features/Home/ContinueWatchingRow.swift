import NoSlopKit
import SwiftUI

/// "Continue watching": a horizontal row of 260 pt cards for the videos that were started and not finished. A card
/// shows the thumbnail with its red progress bar, the title and "Channel · 12 min left"; tapping it resumes.
struct ContinueWatchingRow: View {
    let entries: [HistoryEntry]

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue watching")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Theme.padding)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.padding) {
                    ForEach(entries) { entry in
                        Button {
                            // The player resumes from the saved position by itself.
                            env.open(entry.video)
                        } label: {
                            ContinueWatchingCard(entry: entry)
                        }
                        .buttonStyle(.pressableCard)
                        .videoContextMenu(entry.video)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.padding)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "12 min left" under the title says how much is watched; the thumbnail need not say it a second time.
            ThumbnailView(video: entry.video, speaksProgress: false)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                VideoTitleText(video: entry.video, lineLimit: 2)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Theme.continueWatchingCardWidth, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// "Channel · 12 min left"; parts that are unknown are left out.
    private var detail: String {
        var parts: [String] = []
        if let name = entry.video.channel?.name, !name.isEmpty {
            parts.append(name)
        }
        let length = entry.durationSeconds ?? entry.video.durationSeconds.map(Double.init) ?? 0
        if let left = Formatting.timeLeft(seconds: length - entry.progressSeconds) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ContinueWatchingRow(
        entries: SampleData.videos.prefix(3).map {
            HistoryEntry(video: $0, lastWatchedAt: Date(), progressSeconds: 120, durationSeconds: Double($0.durationSeconds ?? 600))
        }
    )
    .environment(AppEnvironment.preview())
}
