import NoSlopKit
import SwiftUI

/// The results of one search as a scrolling feed: videos as cards, channels and playlists as rows, with loading
/// placeholders, an error with Retry, an empty state, and infinite scroll. Shared by the Search tab and the pushed
/// `SearchResultsView`; the model decides what is searched.
struct SearchResultsContent: View {
    let model: SearchResultsModel

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            content
                .padding(.vertical, Theme.padding)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh(using: env) }
        .miniPlayerClearance()
        // "Don't show this channel" (or any other feed filter) takes effect on the results on screen, not after a new
        // search. Also when the screen comes back: the filter may have changed on a screen above it.
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
            PlaceholderList(style: .cards)

        case .failed(let error):
            ErrorStateView(error: error) { model.retry(using: env) }

        case .loaded:
            if !model.list.items.isEmpty {
                results
            } else if let error = model.list.loadMoreError {
                // The filters hid the first page and the next one failed to load.
                ErrorStateView(error: error) { model.retryLoadMore(using: env) }
            } else if model.list.isPaused {
                // The filters hid several pages in a row and paging stopped; nothing is on its way.
                FeedPausedView { model.loadMore(using: env) }
                    .padding(.top, 40)
            } else if model.list.hasMore || model.list.isLoadingMore {
                // The filters hid the first page; the next one is on its way.
                PlaceholderList(style: .cards)
            } else {
                noResults
            }
        }
    }

    private var results: some View {
        LazyVStack(spacing: 0) {
            FeedGrid {
                ForEach(model.list.items) { item in
                    SearchItemRow(item: item)
                        .onAppear { model.rowAppeared(item, using: env) }
                }
            }

            if model.list.hasMore || model.list.loadMoreError != nil {
                FeedFooter(
                    error: model.list.loadMoreError,
                    retry: { model.retryLoadMore(using: env) },
                    onReachEnd: { model.loadMore(using: env) },
                    isPaused: model.list.isPaused
                )
            }
        }
    }

    @ViewBuilder
    private var noResults: some View {
        ContentUnavailableView {
            Label("No results", systemImage: "magnifyingglass")
        } description: {
            if model.filter.isDefault {
                Text("Nothing found for \u{201C}\(model.query)\u{201D}. Check the spelling or try other words.")
            } else {
                Text("Nothing found for \u{201C}\(model.query)\u{201D} with these filters.")
            }
        } actions: {
            if !model.filter.isDefault {
                Button("Reset filters") {
                    model.apply(filter: SearchFilter(), using: env)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 40)
    }
}

#Preview {
    let model = SearchResultsModel()
    NavigationStack {
        SearchResultsContent(model: model)
            .navigationTitle("blender")
            .navigationBarTitleDisplayMode(.inline)
    }
    .environment(AppEnvironment.preview())
    .task { model.loadIfNeeded(query: "blender", using: AppEnvironment.preview()) }
}
