import NoSlopKit
import SwiftUI

/// A channel page: header, then Videos / Live / Playlists in a segmented control that stays pinned while the list
/// scrolls. Every tab pages in as you scroll.
struct ChannelView: View {
    let channelID: String

    @Environment(AppEnvironment.self) private var env
    @State private var model: ChannelViewModel

    init(channelID: String) {
        self.channelID = channelID
        _model = State(initialValue: ChannelViewModel(channelID: channelID))
    }

    var body: some View {
        ScrollView {
            content
        }
        .refreshable { await model.refresh(using: env) }
        .miniPlayerClearance()
        .navigationTitle(model.header?.name ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = model.webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url)
                }
            }
        }
        .task { model.loadIfNeeded(using: env) }
        // A feed filter that changes (Shorts, members-only, keywords) takes effect on the tabs on screen right away.
        // Also when the screen comes back: it may have changed on a screen above it.
        .onChange(of: env.settings) {
            model.filtersChanged(using: env)
        }
        .onAppear {
            model.filtersChanged(using: env)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: Theme.feedSpacing) {
                ChannelHeaderPlaceholder()
                PlaceholderList(style: .cards, count: 2)
            }

        case .failed(let error):
            ErrorStateView(error: error, openURL: model.webURL) { model.retry(using: env) }
                .padding(.top, 60)

        case .loaded:
            if let header = model.header {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ChannelHeaderView(header: header)

                    Section {
                        tabBody
                    } header: {
                        if model.availableTabs.count > 1 {
                            tabPicker
                        }
                    }
                }
                // Like the other lists: the last row ends `padding` above the end of the page.
                .padding(.bottom, Theme.padding)
            }
        }
    }

    // MARK: Tabs

    private var tabPicker: some View {
        Picker("Channel section", selection: Binding(
            get: { model.selectedTab },
            set: { model.select($0, using: env) }
        )) {
            ForEach(model.availableTabs, id: \.self) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 8)
        // Opaque, so the list scrolls cleanly underneath while the picker is pinned.
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var tabBody: some View {
        let tab = model.selectedTab
        if let tabContent = model.content[tab] {
            switch tabContent.phase {
            case .loading:
                PlaceholderList(style: tab == .playlists ? .rows : .cards, count: 3)
                    .padding(.top, Theme.padding)

            case .failed(let error):
                ErrorStateView(error: error) { model.retryTab(tab, using: env) }
                    .padding(.top, 30)

            case .loaded:
                let list = tabContent.list
                if !list.items.isEmpty {
                    items(of: tabContent, tab: tab)
                } else if let error = list.loadMoreError {
                    ErrorStateView(error: error) { model.retryLoadMore(tab, using: env) }
                        .padding(.top, 30)
                } else if list.isPaused {
                    FeedPausedView { model.loadMore(tab, using: env) }
                        .padding(.top, 30)
                } else if list.hasMore || list.isLoadingMore {
                    PlaceholderList(style: tab == .playlists ? .rows : .cards, count: 3)
                        .padding(.top, Theme.padding)
                } else {
                    emptyTab(tab)
                }
            }
        }
    }

    private func items(of tabContent: ChannelTabContent, tab: ChannelTabKind) -> some View {
        let list = tabContent.list
        return LazyVStack(spacing: 0) {
            FeedGrid {
                ForEach(list.items) { item in
                    SearchItemRow(item: item)
                        .onAppear { model.rowAppeared(item, tab: tab, using: env) }
                }
            }
            .padding(.top, Theme.padding)

            if list.hasMore || list.loadMoreError != nil {
                FeedFooter(
                    error: list.loadMoreError,
                    retry: { model.retryLoadMore(tab, using: env) },
                    onReachEnd: { model.loadMore(tab, using: env) },
                    isPaused: list.isPaused
                )
            }
        }
    }

    private func emptyTab(_ tab: ChannelTabKind) -> some View {
        Group {
            switch tab {
            case .videos:
                EmptyStateView(title: "No videos", systemImage: "play.slash", message: "This channel has no videos to show.")
            case .live:
                EmptyStateView(title: "No live streams", systemImage: "dot.radiowaves.left.and.right", message: "This channel has no live or past streams to show.")
            case .playlists:
                EmptyStateView(title: "No playlists", systemImage: "list.bullet.rectangle", message: "This channel has not made any playlists.")
            }
        }
        .padding(.top, 30)
    }
}

extension ChannelTabKind {
    /// The title in the segmented control.
    var label: String {
        switch self {
        case .videos: return "Videos"
        case .live: return "Live"
        case .playlists: return "Playlists"
        }
    }
}

#Preview {
    NavigationStack {
        ChannelView(channelID: SampleData.blender.id)
    }
    .environment(AppEnvironment.preview())
}
