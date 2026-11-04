import NoSlopKit
import SwiftUI

/// Picks the quality of a download. The choices come from the formats the video offers
/// (`downloads.availableOptions(for:)`) with their estimated sizes; a quality that was already started shows its
/// progress, or "Downloaded", and can be cancelled, retried or removed from here.
struct DownloadOptionsSheet: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded([DownloadOption])
        case failed(Error)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Download")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task { await loadOptions() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            LoadingView()
        case .failed(let error):
            ErrorStateView(error: error, openURL: video.watchURL) {
                await loadOptions()
            }
        case .loaded(let options):
            if options.isEmpty {
                EmptyStateView(
                    title: "Can't be downloaded",
                    systemImage: "arrow.down.circle.dotted",
                    message: "YouTube offers no downloadable version of this video. Live streams can't be downloaded."
                )
            } else {
                list(of: options)
            }
        }
    }

    private func list(of options: [DownloadOption]) -> some View {
        List {
            Section {
                ForEach(options) { option in
                    OptionRow(video: video, option: option) {
                        dismiss()
                    }
                }
            } header: {
                Text(video.title.isEmpty ? "Choose a quality" : video.title)
                    .lineLimit(2)
                    .textCase(nil)
                    .font(.subheadline)
            } footer: {
                Text("Downloads play offline in the No Slop player, even without a connection. Sizes are estimates. The files are also in the Files app, in the No Slop folder.")
            }
        }
    }

    private func loadOptions() async {
        phase = .loading
        do {
            let info = try await env.streams.streamInfo(videoID: video.id)
            guard !Task.isCancelled else { return }
            phase = .loaded(env.downloads.availableOptions(for: info))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error)
        }
    }
}

/// One quality: its label and size, and what the download of it is doing.
private struct OptionRow: View {
    let video: VideoSummary
    let option: DownloadOption
    /// Called after a download was started or restarted, to close the sheet.
    let onStarted: () -> Void

    @Environment(AppEnvironment.self) private var env

    /// The download that is this row's rendition, whatever it was asked for as: a video that stops at 144p downloaded as
    /// "up to 720p" (from the context menu) is the 144p row's download.
    private var item: DownloadItem? {
        env.downloads.item(for: option, videoID: video.id)
    }

    var body: some View {
        if let item {
            existing(item)
        } else {
            Button {
                env.downloads.enqueue(video: video, quality: option.quality)
                onStarted()
            } label: {
                HStack {
                    titleAndSize
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(option.label)")
        }
    }

    private var titleAndSize: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.label)
                .font(.body)
            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sizeText: String {
        guard let bytes = option.estimatedBytes, bytes > 0 else { return "Size unknown" }
        return "About " + StorageSizeText.string(bytes)
    }

    // MARK: A download that exists

    @ViewBuilder
    private func existing(_ item: DownloadItem) -> some View {
        switch item.state {
        case .completed:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body)
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .labelStyle(.tight)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                Button("Delete", role: .destructive) {
                    env.downloads.delete(id: item.id)
                }
                .buttonStyle(.borderless)
            }

        case .queued, .downloading, .merging:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(option.label)
                        .font(.body)
                    Spacer(minLength: 8)
                    Button("Cancel", role: .destructive) {
                        env.downloads.cancel(id: item.id)
                    }
                    .buttonStyle(.borderless)
                }
                ProgressView(value: min(1, max(0, item.progress)))
                    .tint(Theme.accent)
                Text(progressText(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed, .paused:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body)
                    Text(item.state == .paused ? "Paused" : (item.errorMessage ?? "Download failed"))
                        .font(.caption)
                        .foregroundStyle(item.state == .paused ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Retry") {
                    env.downloads.retry(id: item.id)
                    onStarted()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func progressText(for item: DownloadItem) -> String {
        switch item.state {
        case .queued: return "Waiting to start"
        case .merging: return "Finishing up"
        default:
            let percent = Int((min(1, max(0, item.progress)) * 100).rounded())
            return "\(percent)%"
        }
    }
}
