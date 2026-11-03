import Foundation

/// The single network seam of the kit. Production code uses `URLSessionHTTPClient`; tests use a mock.
///
/// Implementations return the response for *any* HTTP status (a 404 is a normal return value); callers map
/// statuses to `NoSlopError.http(status:)` themselves. Transport failures throw `NoSlopError`.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `HTTPClient` backed by a `URLSession`.
///
/// - `URLError.cancelled` (and Swift task cancellation) becomes `NoSlopError.cancelled`.
/// - Any other `URLError` becomes `NoSlopError.network(localizedDescription)`.
/// - A response that is not HTTP becomes `NoSlopError.network`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NoSlopError.network("The server did not send an HTTP response.")
            }
            return (data, http)
        } catch let error as NoSlopError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw NoSlopError.cancelled }
            throw NoSlopError.network(error.localizedDescription)
        } catch is CancellationError {
            throw NoSlopError.cancelled
        } catch {
            throw NoSlopError.network(error.localizedDescription)
        }
    }
}
