import NoSlopKit
import SwiftUI

/// The Search tab: a search field with live suggestions and recent searches, and the results below it.
/// A pasted YouTube link opens directly. Results page in as you scroll and can be filtered.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SearchViewModel()
    @State private var showsFilters = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        content
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $model.text, prompt: "Search YouTube")
            .searchFocused($isSearchFocused)
            // Keep the toolbar (the filter button) on screen while the search field is active.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) { model.submit(model.text, using: env) }
            .task(id: model.text) { await model.loadSuggestions(using: env) }
            .onChange(of: model.text) { _, text in
                if text.isEmpty { model.clearResults() }
            }
            #if DEBUG
            .task {
                if let text = DebugLaunchHooks.takeSearchText() { model.submit(text, using: env) }
            }
            #endif
            .toolbar {
                if model.mode == .results {
                    ToolbarItem(placement: .topBarTrailing) {
                        SearchFilterButton(filter: model.results.filter) { showsFilters = true }
                    }
                }
            }
            .sheet(isPresented: $showsFilters) {
                SearchFilterSheet(filter: model.results.filter) { filter in
                    model.applyFilter(filter, using: env)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .recents:
            RecentSearchesList { search(for: $0) }
        case .suggestions:
            SuggestionsList(
                recents: model.matchingRecents(in: env),
                suggestions: model.suggestions,
                search: { search(for: $0) },
                fill: { model.text = $0 }
            )
        case .results:
            SearchResultsContent(model: model.results)
        }
    }

    /// Searches for a recent search or suggestion the user tapped. The keyboard goes away, as it does when they press
    /// the keyboard's Search key; otherwise it stays up over the results and does not go away when they scroll.
    private func search(for query: String) {
        isSearchFocused = false
        model.submit(query, using: env)
    }
}

/// What the field shows while it is empty: the recent searches (with Clear), or an invitation to search.
private struct RecentSearchesList: View {
    let search: (String) -> Void

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recents = env.library.searchHistory
        if recents.isEmpty {
            ContentUnavailableView {
                Label("Search YouTube", systemImage: "magnifyingglass")
            } description: {
                Text("Find videos, channels and playlists without ads or Shorts. You can also paste a YouTube link.")
            }
        } else {
            List {
                Section {
                    ForEach(recents, id: \.self) { query in
                        Button {
                            search(query)
                        } label: {
                            SuggestionLabel(text: query, systemImage: "clock.arrow.circlepath")
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent searches")
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                        Spacer()
                        Button("Clear") {
                            env.library.clearSearchHistory()
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .miniPlayerClearance()
            #if DEBUG
            .debugSearchScroll()
            #endif
        }
    }
}

/// What the field shows while typing: matching recent searches, then YouTube's suggestions. Tapping a row searches;
/// the arrow copies it into the field to keep editing.
private struct SuggestionsList: View {
    let recents: [String]
    let suggestions: [String]
    let search: (String) -> Void
    let fill: (String) -> Void

    var body: some View {
        let rows = rows
        List {
            ForEach(rows, id: \.text) { row in
                HStack(spacing: Theme.padding) {
                    Button {
                        search(row.text)
                    } label: {
                        SuggestionLabel(
                            text: row.text,
                            systemImage: row.isRecent ? "clock.arrow.circlepath" : "magnifyingglass"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        fill(row.text)
                    } label: {
                        Image(systemName: "arrow.up.left")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(row.text) in the search field")
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .miniPlayerClearance()
        #if DEBUG
        .debugSearchScroll()
        #endif
    }

    private struct Row {
        let text: String
        let isRecent: Bool
    }

    /// Recent matches first, then the suggestions that are not already listed.
    private var rows: [Row] {
        var seen = Set<String>()
        var result: [Row] = []
        for text in recents where seen.insert(text.lowercased()).inserted {
            result.append(Row(text: text, isRecent: true))
        }
        for text in suggestions where seen.insert(text.lowercased()).inserted {
            result.append(Row(text: text, isRecent: false))
        }
        return result
    }
}

/// A row of the recents and suggestions lists: the text in the primary colour, a quiet icon in front.
private struct SuggestionLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .environment(AppEnvironment.preview())
}
