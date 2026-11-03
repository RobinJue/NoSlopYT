import NoSlopKit
import SwiftUI

/// The results of a search for `query` as a screen of its own, pushed with `.searchResults(query:)` (a topic chip
/// on Home, a YouTube search link). It is the same results list as in the Search tab, with the same filters.
struct SearchResultsView: View {
    let query: String

    @Environment(AppEnvironment.self) private var env
    @State private var model = SearchResultsModel()
    @State private var showsFilters = false

    var body: some View {
        SearchResultsContent(model: model)
            .navigationTitle(query)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchFilterButton(filter: model.filter) { showsFilters = true }
                }
            }
            .sheet(isPresented: $showsFilters) {
                SearchFilterSheet(filter: model.filter) { filter in
                    model.apply(filter: filter, using: env)
                }
            }
            .task { model.loadIfNeeded(query: query, using: env) }
    }
}

#Preview {
    NavigationStack {
        SearchResultsView(query: "blender")
    }
    .environment(AppEnvironment.preview())
}
