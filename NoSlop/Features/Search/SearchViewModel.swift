import Foundation
import NoSlopKit
import Observation

/// The state behind the Search tab: the text in the search field, the live suggestions, and the results of the last
/// submitted search.
///
/// What the screen shows follows from the text: empty → recent searches; text that differs from the submitted
/// query → suggestions; text equal to the submitted query → its results. A pasted YouTube link is opened directly
/// instead of searched; any other text, including text that merely contains a domain ("asp.net tutorial"), is a
/// search (`SearchInput` decides which).
@MainActor
@Observable
final class SearchViewModel {
    /// Bound to the search field.
    var text = ""

    private(set) var suggestions: [String] = []
    /// The query whose results (or loading placeholders) are on screen; nil when none are.
    private(set) var submittedQuery: String?
    let results = SearchResultsModel()

    @ObservationIgnored private var submitTask: Task<Void, Never>?

    enum Mode {
        case recents, suggestions, results
    }

    /// What the screen shows for the text in the field.
    var mode: Mode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .recents }
        if trimmed == submittedQuery { return .results }
        return .suggestions
    }

    // MARK: Suggestions

    /// Fetches suggestions for the text 250 ms after the last keystroke. Call it from `.task(id: text)`: a new
    /// keystroke cancels the previous call, which is what debounces. Failures are ignored; suggestions are a
    /// convenience and the previous ones stay on screen.
    func loadSuggestions(using env: AppEnvironment) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query != submittedQuery else {
            suggestions = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let found = try await env.youTube.suggestions(for: query)
            guard !Task.isCancelled else { return }
            suggestions = found
        } catch {
            // Cancelled by the next keystroke, or the suggestions could not be fetched: keep what is shown.
        }
    }

    /// Recent searches that start with or contain what is typed, to show above the suggestions.
    func matchingRecents(in env: AppEnvironment) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        return env.library.searchHistory
            .filter { $0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame }
            .prefix(3)
            .map { $0 }
    }

    // MARK: Submitting

    /// Runs the search for `raw` (the keyboard's Search key, a tapped suggestion or a recent search). A YouTube link
    /// opens what it points at instead.
    func submit(_ raw: String, using env: AppEnvironment) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        submitTask?.cancel()
        text = query
        suggestions = []

        switch SearchInput(query) {
        case .search:
            startSearch(query, using: env)

        case .appLink(let link):
            openDirectly(link, using: env)

        case .link(let url):
            // Show the placeholders (not the results of an earlier search) while the link is looked up; it may turn
            // out to be ordinary text.
            results.clear()
            submittedQuery = query
            submitTask = Task { [weak self] in
                let resolved = await Self.resolvedLink(for: url, using: env)
                // Dropped when the field was edited or cleared while the link was being looked up.
                guard let self, !Task.isCancelled,
                      self.text.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                if let resolved {
                    self.open(resolved, using: env)
                } else {
                    self.startSearch(query, using: env)
                }
            }
        }
    }

    /// The user cleared the field or left the search: forget the results.
    func clearResults() {
        submitTask?.cancel()
        submittedQuery = nil
        results.clear()
    }

    func applyFilter(_ filter: SearchFilter, using env: AppEnvironment) {
        results.apply(filter: filter, using: env)
    }

    private func startSearch(_ query: String, using env: AppEnvironment) {
        env.library.recordSearch(query)
        submittedQuery = query
        results.search(query, using: env)
    }

    private func open(_ resolved: ResolvedURL, using env: AppEnvironment) {
        switch resolved {
        case .search(let query):
            // A YouTube results link is just a search.
            text = query
            startSearch(query, using: env)
        case .video, .videoInPlaylist, .channel, .playlist:
            guard let link = resolved.appLink else { return }
            openDirectly(link, using: env)
        }
    }

    /// Opens an app link and leaves the field empty, so coming back to this tab starts a new search.
    private func openDirectly(_ link: URL, using env: AppEnvironment) {
        text = ""
        submittedQuery = nil
        results.clear()
        // In a task of its own (`handleOpenURL` is async): emptying the field cancels `submitTask`, which must not
        // cancel the open that follows.
        Task { await env.handleOpenURL(link) }
    }

    /// What a link points at: decided locally when possible, else asked of YouTube (a `@handle` needs the network).
    /// `SearchInput` only hands over YouTube links and the app's own, and a YouTube host is the only one worth a request.
    private static func resolvedLink(for url: URL, using env: AppEnvironment) async -> ResolvedURL? {
        if let local = YouTubeURL.resolveLocally(url) {
            return local
        }
        guard SearchInput.isYouTubeHost(of: url) else { return nil }
        return try? await env.youTube.resolve(url: url)
    }
}
