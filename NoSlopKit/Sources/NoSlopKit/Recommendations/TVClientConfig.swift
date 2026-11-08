import Foundation

/// The two looks the TV client can take on: YouTube's current TV app and the older Cobalt build some accounts still answer.
public enum TVProfile: Sendable, Hashable {
    case tv, legacy

    public var clientVersion: String {
        switch self {
        case .tv: return TVClientConfig.tvClientVersion
        case .legacy: return TVClientConfig.legacyClientVersion
        }
    }

    public var userAgent: String {
        switch self {
        case .tv: return TVClientConfig.tvUserAgent
        case .legacy: return TVClientConfig.legacyUserAgent
        }
    }
}

/// One way of asking for YouTube's Home: the browse id and the host it goes to (the recipe ladder of the recommendations service).
public struct TVHomeRecipe: Sendable, Hashable {
    public let browseID: String
    public let host: String

    public init(browseID: String, host: String) {
        self.browseID = browseID
        self.host = host
    }
}

/// The constants of YouTube's TV interface, copied by the Mac probe (`scripts/tv-probe`) from MIT and Unlicense sources.
public enum TVClientConfig {
    public static let tvClientVersion = "7.20260901.15.00"
    public static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    public static let legacyClientVersion = "5.20260901"
    public static let legacyUserAgent = "Mozilla/5.0 (DirectFB; Linux x86_64) Cobalt/4.13031-qa (unlike Gecko) Starboard/1"
    public static let referer = "https://www.youtube.com/tv"

    /// The only hosts a TV request (and so the Authorization header) may go to.
    public static let allowedHosts: Set<String> = ["www.youtube.com", "youtubei.googleapis.com", "oauth2.googleapis.com"]

    /// Home, in the order the ladder tries it.
    public static let homeRecipes: [TVHomeRecipe] = [
        TVHomeRecipe(browseID: "FEwhat_to_watch", host: "www.youtube.com"),
        TVHomeRecipe(browseID: "default", host: "www.youtube.com"),
        TVHomeRecipe(browseID: "FEwhat_to_watch", host: "youtubei.googleapis.com"),
    ]

    /// The request context of the probe's "full" variant, which follows SmartTube's TV browse body.
    public static func context(_ profile: TVProfile, visitorData: String?, language: String, region: String) -> JSON {
        var client: [String: JSON] = [
            "clientName": "TVHTML5",
            "clientVersion": .string(profile.clientVersion),
            "clientScreen": "WATCH",
            "userAgent": .string(profile.userAgent),
            "hl": .string(language),
            "gl": .string(region),
            "tvAppInfo": ["appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": true],
        ]
        if let visitorData, !visitorData.isEmpty {
            client["visitorData"] = .string(visitorData)
        }
        return ["client": .object(client)]
    }
}
