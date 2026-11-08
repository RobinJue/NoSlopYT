import Foundation
import Observation

/// The videos the viewer sent "Not interested" for from YouTube's Home during this launch. Home leaves them out of the
/// cards it shows at once, whatever YouTube answers; nothing undoes it, and nothing is stored on disk.
@MainActor
@Observable
final class HomeCardDismissals {
    static let shared = HomeCardDismissals()

    private(set) var ids: Set<String> = []

    func dismiss(_ id: String) {
        ids.insert(id)
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }
}
