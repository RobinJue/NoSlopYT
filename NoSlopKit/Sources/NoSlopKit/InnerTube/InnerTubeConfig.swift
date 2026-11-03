import Foundation

/// Content language (`hl`) and region (`gl`) sent with every InnerTube request.
public struct InnerTubeConfig: Sendable, Hashable {
    public var hl: String
    public var gl: String

    public init(hl: String, gl: String) {
        self.hl = hl
        self.gl = gl
    }

    /// `hl` from the locale's language code and `gl` from its region, defaulting to "en" / "US".
    public static func fromLocale(_ locale: Locale = .current) -> InnerTubeConfig {
        InnerTubeConfig(
            hl: locale.language.languageCode?.identifier ?? "en",
            gl: locale.region?.identifier ?? "US"
        )
    }
}
