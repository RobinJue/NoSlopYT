import Foundation

/// The InnerTube transport: obtains and caches `visitorData`, builds the request context for a client profile,
/// POSTs JSON and returns the parsed response.
///
/// STUB (Task 1A). Task 2 owns this file: the throwing members throw `NoSlopError.notImplemented`.
public actor InnerTubeClient {
    /// Immutable, so it is `nonisolated`: readable from any module without `await`.
    public nonisolated let config: InnerTubeConfig

    public init(
        http: any HTTPClient,
        config: InnerTubeConfig,
        visitorStore: any VisitorDataStoring = UserDefaultsVisitorDataStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
    }

    public func visitorData(forceRefresh: Bool = false) async throws -> String {
        throw NoSlopError.notImplemented("InnerTubeClient.visitorData")
    }

    public func post(endpoint: String, profile: ClientProfile, body: [String: JSON]) async throws -> JSON {
        throw NoSlopError.notImplemented("InnerTubeClient.post")
    }
}
