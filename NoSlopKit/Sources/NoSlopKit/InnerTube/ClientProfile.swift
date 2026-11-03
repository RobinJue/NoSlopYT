import Foundation

/// How we present ourselves to InnerTube: which client, version, headers and extra `context.client` fields.
///
/// The two profiles come straight from the design spec's table. Metadata (search, next, browse, resolve_url) uses
/// `web`; `player` uses `visionOS`, the client that needs neither a PO token nor JavaScript deciphering.
public struct ClientProfile: Sendable, Hashable {
    public var clientName: String
    public var clientVersion: String
    /// The numeric id sent as `X-YouTube-Client-Name`.
    public var clientNameID: Int
    public var userAgent: String
    /// Extra fields merged into `context.client` (device make/model, OS name/version, ...).
    public var extraClientFields: [String: String]

    public init(
        clientName: String,
        clientVersion: String,
        clientNameID: Int,
        userAgent: String,
        extraClientFields: [String: String] = [:]
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientNameID = clientNameID
        self.userAgent = userAgent
        self.extraClientFields = extraClientFields
    }

    /// Metadata: search, next, browse, navigation/resolve_url.
    public static let web = ClientProfile(
        clientName: "WEB",
        clientVersion: "2.20261030.02.00",
        clientNameID: 1,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15,gzip(gfe)"
    )

    /// Streams: `player`. Needs no PO token and no JavaScript deciphering.
    public static let visionOS = ClientProfile(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientNameID: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extraClientFields: [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
        ]
    )
}
