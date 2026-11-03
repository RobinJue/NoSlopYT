import Foundation
import NoSlopKit
import Observation

/// What one tab of a channel page (Videos, Live, Playlists) has loaded.
@MainActor
@Observable
final class ChannelTabContent {
    enum Phase {
        case loading
        case loaded
        case failed(Error)
    }

    fileprivate(set) var phase: Phase = .loading
    let list = FeedPages<SearchItem>()
}

/// Loads a channel page for `ChannelView`: the header and the Videos tab in one request, then the other tabs when
/// they are first opened, each paging with `channelMore`.
///
/// Loads run in tasks of the model's own, so leaving the screen and coming back does not cancel or restart them.
/// Pull to refresh reloads the page and keeps the old one on screen until the new one is there.
@MainActor
@Observable
final class ChannelViewModel {
    enum Phase {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    let channelID: String
    private(set) var phase: Phase = .idle
    private(set) var header: ChannelHeader?
    private(set) var availableTabs: [ChannelTabKind] = [.videos]
    private(set) var selectedTab: ChannelTabKind = .videos
    /// The tabs that were opened so far.
    private(set) var content: [ChannelTabKind: ChannelTabContent] = [:]

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var tabTasks: [ChannelTabKind: Task<Void, Never>] = [:]

    init(channelID: String) {
        self.channelID = channelID
    }

    /// The link to the channel on YouTube (for sharing and "Open on YouTube").
    var webURL: URL? {
        URL(string: "https://www.youtube.com/channel/\(channelID)")
    }

    // MARK: The page

    /// Loads the page the first time the screen appears. A failed load waits for `retry`.
    func loadIfNeeded(using env: AppEnvironment) {
        guard case .idle = phase else { return }
        load(using: env, showsPlaceholders: true)
    }

    func retry(using env: AppEnvironment) {
        load(using: env, showsPlaceholders: true)
    }

    /// Pull to refresh. Suspends until the page is reloaded; a failure keeps the page that is on screen.
    func refresh(using env: AppEnvironment) async {
        load(using: env, showsPlaceholders: header == nil)
        await loadTask?.value
    }

    private func load(using env: AppEnvironment, showsPlaceholders: Bool) {
        loadTask?.cancel()
        for task in tabTasks.values { task.cancel() }
        tabTasks = [:]
        generation += 1
        let thisGeneration = generation
        if showsPlaceholders {
            phase = .loading
            header = nil
            content = [:]
        }

        let id = channelID
        loadTask = Task { [weak self] in
            do {
                let page = try await env.youTube.channel(id: id)
                guard let self, self.generation == thisGeneration else { return }
                self.loadTask = nil
                self.show(page, using: env)
            } catch {
                guard let self, self.generation == thisGeneration else { return }
                self.loadTask = nil
                if FeedError.isCancellation(error) {
                    if self.header == nil { self.phase = .idle }
                } else if self.header == nil {
                    self.phase = .failed(error)
                }
                // A failed refresh leaves the page that is on screen, and with it the tabs the refresh had cancelled.
                if self.header != nil { self.restartUnfinishedTabs(using: env) }
            }
        }
    }

    /// A refresh cancels the loads of tabs that were still opening. When the refresh then fails the old page stays, and
    /// those tabs would show placeholders for ever (selecting a tab that has content never loads it). The tab on screen
    /// starts over; the others are forgotten, so they load when they are selected.
    private func restartUnfinishedTabs(using env: AppEnvironment) {
        for (tab, tabContent) in content {
            guard case .loading = tabContent.phase else { continue }
            if tab == selectedTab {
                loadTab(tab, using: env)
            } else {
                content[tab] = nil
            }
        }
    }

    private func show(_ page: ChannelPage, using env: AppEnvironment) {
        header = page.header
        availableTabs = page.availableTabs.isEmpty ? [.videos] : page.availableTabs
        if !availableTabs.contains(selectedTab) {
            selectedTab = availableTabs[0]
        }

        // The page already carries the first page of the Videos tab.
        let videos = ChannelTabContent()
        videos.list.reset(with: page.videos, filter: contentFilter(for: .videos, env))
        videos.phase = .loaded
        content = [.videos: videos]
        phase = .loaded

        if videos.list.items.isEmpty { loadMore(.videos, using: env) }
        if selectedTab != .videos { loadTab(selectedTab, using: env) }
    }

    // MARK: Tabs

    func select(_ tab: ChannelTabKind, using env: AppEnvironment) {
        guard availableTabs.contains(tab) else { return }
        selectedTab = tab
        if content[tab] == nil {
            loadTab(tab, using: env)
        }
    }

    func retryTab(_ tab: ChannelTabKind, using env: AppEnvironment) {
        loadTab(tab, using: env)
    }

    private func loadTab(_ tab: ChannelTabKind, using env: AppEnvironment) {
        tabTasks[tab]?.cancel()
        let tabContent = ChannelTabContent()
        content[tab] = tabContent
        let thisGeneration = generation
        let id = channelID
        tabTasks[tab] = Task { [weak self, weak tabContent] in
            do {
                let page = try await env.youTube.channelTab(channelID: id, tab: tab)
                guard let self, let tabContent, self.generation == thisGeneration else { return }
                self.tabTasks[tab] = nil
                tabContent.list.reset(with: page, filter: self.contentFilter(for: tab, env))
                tabContent.phase = .loaded
                if tabContent.list.items.isEmpty { self.loadMore(tab, using: env) }
            } catch {
                guard let self, let tabContent, self.generation == thisGeneration else { return }
                self.tabTasks[tab] = nil
                if FeedError.isCancellation(error) {
                    // Forget the half-opened tab, so selecting it again starts over.
                    self.content[tab] = nil
                } else {
                    tabContent.phase = .failed(error)
                }
            }
        }
    }

    // MARK: Paging

    func rowAppeared(_ item: SearchItem, tab: ChannelTabKind, using env: AppEnvironment) {
        guard let tabContent = content[tab], case .loaded = tabContent.phase else { return }
        tabContent.list.rowAppeared(item, fetch: fetch(env), filter: contentFilter(for: tab, env))
    }

    func loadMore(_ tab: ChannelTabKind, using env: AppEnvironment) {
        guard let tabContent = content[tab], case .loaded = tabContent.phase else { return }
        tabContent.list.loadMore(fetch: fetch(env), filter: contentFilter(for: tab, env))
    }

    func retryLoadMore(_ tab: ChannelTabKind, using env: AppEnvironment) {
        guard let tabContent = content[tab], case .loaded = tabContent.phase else { return }
        tabContent.list.retryLoadMore(fetch: fetch(env), filter: contentFilter(for: tab, env))
    }

    private func fetch(_ env: AppEnvironment) -> FeedPages<SearchItem>.Fetch {
        { token in try await env.youTube.channelMore(continuation: token) }
    }

    /// The feed filters, adjusted for a screen the user opened on purpose: a channel they blocked still shows its own
    /// page (it would otherwise be empty), and the Live tab shows live and upcoming streams even when feeds hide them.
    private func contentFilter(for tab: ChannelTabKind, _ env: AppEnvironment) -> FeedPages<SearchItem>.Filter {
        { items in
            var settings = env.settings
            settings.blockedChannels = []
            if tab == .live { settings.hideLiveAndUpcoming = false }
            return ContentFilter(settings: settings).filter(items)
        }
    }
}
