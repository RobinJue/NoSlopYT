import NoSlopKit
import SwiftUI

/// The downloads, in three groups: running (progress, cancel), stopped (failed or paused: retry, delete) and
/// finished (tap to play offline, swipe to delete), with the space they use at the bottom.
struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var itemToDelete: DownloadItem?

    var body: some View {
        let items = env.downloads.items
        let running = items.filter { Self.runningStates.contains($0.state) }
        let stopped = items.filter { $0.state == .failed || $0.state == .paused }
        let finished = items.filter { $0.state == .completed }

        Group {
            if items.isEmpty {
                EmptyStateView(
                    title: "No downloads",
                    systemImage: "arrow.down.circle",
                    message: "Download a video from its page to watch it without a connection."
                )
            } else {
                List {
                    if !running.isEmpty {
                        Section("Downloading") {
                            ForEach(running) { item in
                                RunningDownloadRow(item: item)
                            }
                        }
                    }

                    if !stopped.isEmpty {
                        Section("Failed or paused") {
                            ForEach(stopped) { item in
                                StoppedDownloadRow(item: item) {
                                    itemToDelete = item
                                }
                            }
                        }
                    }

                    if !finished.isEmpty {
                        Section("Downloaded") {
                            ForEach(finished) { item in
                                FinishedDownloadRow(item: item) {
                                    itemToDelete = item
                                }
                            }
                        }
                    }

                    Section {
                        LabeledContent("Space used", value: StorageSizeText.string(env.downloads.bytesOnDisk))
                    } footer: {
                        Text("Downloaded videos are also in the Files app, in the No Slop folder.")
                    }
                }
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        // An alert, shown from the list itself: a swipe action closes its row, and a dialog attached to that row
        // would be lost with it.
        .alert(
            "Delete this download?",
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button("Delete", role: .destructive) {
                env.downloads.delete(id: item.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.state == .completed ? "You can download the video again later." : "The partial download is discarded.")
        }
    }

    private static let runningStates: [DownloadState] = [.queued, .downloading, .merging]
}

// MARK: - Rows

/// The small thumbnail, the title and the quality/status lines every download row shares.
private struct DownloadRowLayout<Trailing: View, Detail: View>: View {
    let item: DownloadItem
    let trailing: Trailing
    let detail: Detail

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(item: DownloadItem, @ViewBuilder trailing: () -> Trailing, @ViewBuilder detail: () -> Detail) {
        self.item = item
        self.trailing = trailing()
        self.detail = detail()
    }

    var body: some View {
        // Side by side, the thumbnail and the button leave the title a few characters at accessibility text sizes.
        // There the row is a stack: thumbnail, then the text with the whole width, then the button.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))

        layout {
            RemoteImage(url: item.video.displayThumbnails.best(minWidth: 320)?.url, contentMode: .fill)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: stacked ? Theme.rowThumbnailWidth : 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                VideoTitleText(video: item.video, lineLimit: stacked ? nil : 2)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        // The divider starts at the thumbnail's edge instead of at whichever text the list finds first.
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
    }
}

/// Queued, downloading or merging: a progress bar, how much is done, and Cancel.
private struct RunningDownloadRow: View {
    let item: DownloadItem
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        DownloadRowLayout(item: item) {
            Button {
                env.downloads.cancel(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            // Plain, not borderless: the borderless style would tint the symbol with the accent colour.
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
        } detail: {
            ProgressView(value: min(1, max(0, item.progress)))
                .tint(Theme.accent)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "720p · 12.3 MB of 45.6 MB", "720p · Waiting to start", "720p · Finishing up"
    private var statusText: String {
        let quality = item.quality.label
        switch item.state {
        case .queued:
            return "\(quality) · Waiting to start"
        case .merging:
            return "\(quality) · Finishing up"
        default:
            let done = StorageSizeText.string(item.bytesDownloaded)
            if let total = item.bytesTotal, total > 0 {
                return "\(quality) · \(done) of \(StorageSizeText.string(total))"
            }
            let percent = Int((min(1, max(0, item.progress)) * 100).rounded())
            return "\(quality) · \(percent)%"
        }
    }
}

/// Failed or paused: why, and Retry. Swipe to delete it.
private struct StoppedDownloadRow: View {
    let item: DownloadItem
    let onDelete: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        DownloadRowLayout(item: item) {
            Button {
                env.downloads.retry(id: item.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.tight)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } detail: {
            Text(item.quality.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                .lineLimit(2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var reason: String {
        if item.state == .paused { return "Paused. Retry to continue." }
        return item.errorMessage ?? "The download failed."
    }
}

/// A finished download: tap to play it (the player prefers the file over streaming), swipe to delete.
private struct FinishedDownloadRow: View {
    let item: DownloadItem
    let onDelete: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button {
            env.open(item.video)
        } label: {
            DownloadRowLayout(item: item) {
                EmptyView()
            } detail: {
                if let name = item.video.channel?.name, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(sizeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityHint("Plays the downloaded video")
    }

    /// "720p · 45.6 MB"
    private var sizeLine: String {
        let bytes = item.bytesTotal ?? item.bytesDownloaded
        return bytes > 0 ? "\(item.quality.label) · \(StorageSizeText.string(bytes))" : item.quality.label
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .environment(AppEnvironment.preview())
}
