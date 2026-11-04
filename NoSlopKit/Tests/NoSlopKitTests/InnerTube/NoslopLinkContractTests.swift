import Foundation
import Testing
@testable import NoSlopKit

/// What the app's own links promise (the contract written down in `AppLink`, in the app target, which reads them with
/// `YouTubeURL`): an incomplete or malformed link is not a link, and a start time that cannot be read is no reason to
/// refuse one. The web links of the same videos behave the same way (`YouTubeURLTests`).
@Suite struct NoslopLinkContractTests {
    private func resolve(_ text: String) -> ResolvedURL? {
        URL(string: text).flatMap(YouTubeURL.resolveLocally)
    }

    // MARK: A start time that cannot be read

    @Test(arguments: ["abc", "-5", "1.5", "99999999999999999999", "", "1:2:3:4"])
    func aStartTimeThatCannotBeReadIsIgnoredAndTheVideoStillOpens(value: String) {
        #expect(resolve("noslop://watch?v=dQw4w9WgXcQ&t=\(value)") == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test(arguments: [("90", 90), ("42s", 42), ("1m5s", 65), ("1:05", 65)])
    func aStartTimeThatCanBeReadIsKept(value: String, seconds: Int) {
        #expect(resolve("noslop://watch?v=dQw4w9WgXcQ&t=\(value)") == .video(id: "dQw4w9WgXcQ", startSeconds: seconds))
    }

    // MARK: A link that is not a link

    @Test(arguments: [
        "noslop://watch",
        "noslop://watch?v=",
        "noslop://watch?v=dQw4w9WgXc",
        "noslop://watch?v=dQw4w9WgXcQQ",
        "noslop://watch?v=dQw4w9WgXc!&t=5",
        "noslop://channel",
        "noslop://playlist",
        "noslop://search",
        "noslop://search?q=",
        "noslop://search?q=%20%20",
        "noslop://somewhere/else",
    ])
    func anIncompleteOrMalformedLinkIsNotALink(text: String) {
        #expect(resolve(text) == nil)
    }
}
