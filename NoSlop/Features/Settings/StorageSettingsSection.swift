import NoSlopKit
import SwiftUI

/// Storage: how much space downloads use, and the cleanup actions (each one asks for confirmation first).
struct StorageSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var imageCacheBytes = 0
    /// What the downloads really take on disk, unfinished ones included; nil until it has been measured.
    @State private var downloadsBytes: Int64?

    var body: some View {
        Section {
            NavigationLink(value: Route.downloads) {
                LabeledContent("Downloads", value: downloadsBytes.map { StorageSizeText.string($0) } ?? "–")
            }
            .task(id: env.downloads.diskUsageKey) {
                downloadsBytes = await env.downloads.diskUsage()
            }

            CleanupButton(
                title: "Clear image cache",
                message: "Thumbnails and avatars download again when needed.",
                isDestructive: false
            ) {
                URLCache.shared.removeAllCachedResponses()
                refreshImageCacheSize()
            }
            .task { refreshImageCacheSize() }

            CleanupButton(
                title: "Clear watch history",
                message: "Your history and resume positions are removed. This can't be undone.",
                isDisabled: env.library.history.isEmpty
            ) {
                env.library.clearHistory()
            }

            CleanupButton(
                title: "Clear search history",
                message: "Your recent searches are removed. This can't be undone.",
                isDisabled: env.library.searchHistory.isEmpty
            ) {
                env.library.clearSearchHistory()
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Images use \(StorageSizeText.string(Int64(imageCacheBytes))) on this device. Downloads include those that are not finished. Downloaded videos are also in the Files app, in the No Slop folder.")
        }
    }

    private func refreshImageCacheSize() {
        imageCacheBytes = URLCache.shared.currentDiskUsage
    }
}

/// A settings row that asks "Clear …?" before it does anything. The confirmation is attached to the row it belongs
/// to, so it appears next to that row.
private struct CleanupButton: View {
    let title: String
    let message: String
    var isDestructive = true
    var isDisabled = false
    let action: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button(title, role: isDestructive ? .destructive : nil) {
            isConfirming = true
        }
        .disabled(isDisabled)
        .confirmationDialog("\(title)?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button(title, role: .destructive, action: action)
        } message: {
            Text(message)
        }
    }
}
