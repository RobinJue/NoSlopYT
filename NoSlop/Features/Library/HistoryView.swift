import NoSlopKit
import SwiftUI

/// Everything watched, newest first, in sections by day. A row plays the video (resuming where it stopped); swipe to
/// remove one entry, "Clear all" to forget everything.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isConfirmingClear = false

    var body: some View {
        let history = env.library.history

        Group {
            if history.isEmpty {
                EmptyStateView(
                    title: "No watch history",
                    systemImage: "clock.arrow.circlepath",
                    message: "Videos you watch show up here, so you can pick up where you left off."
                )
            } else {
                List {
                    ForEach(HistoryGrouping.groups(for: history)) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
                                LibraryVideoRow(video: entry.video) {
                                    env.open(entry.video)
                                }
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        env.library.removeFromHistory(videoID: entry.id)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear all", role: .destructive) {
                        isConfirmingClear = true
                    }
                    // Attached to the button, so the confirmation appears next to it.
                    .confirmationDialog("Clear watch history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                        Button("Clear watch history", role: .destructive) {
                            env.library.clearHistory()
                        }
                    } message: {
                        Text("Your history and resume positions are removed. This can't be undone.")
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
    .environment(AppEnvironment.preview())
}
