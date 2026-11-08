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
///
/// Unless a session is passed in, requests go through `defaultSession`, which neither stores nor sends cookies and
/// keeps nothing in `URLCache`: YouTube's own endpoints (`sw.js_data`, the suggestions) answer with tracking cookies,
/// and the app has no use for them.
public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    /// The one session behind every client made with `init()`.
    static let defaultSession = URLSession(configuration: makeDefaultConfiguration())

    /// `.default` without cookies and without a cache, and with timeouts that fit small API requests.
    static func makeDefaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Answers are small, differ from request to request, and the services that want to reuse one cache it themselves.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A request that has produced nothing for half a minute is not going to; a whole exchange is over in seconds.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return configuration
    }

    public init() {
        self.session = Self.defaultSession
    }

    /// A client with a session of its own, made from the same cookie-free, cache-free configuration as the default one.
    /// The TV connection uses it, so nothing it does shares connections, cookies or cache with anonymous traffic.
    ///
    /// It never follows a redirect: the 3xx comes back as the answer. A followed redirect could re-send the
    /// Authorization header, the visitor id and the body to a host nobody checked.
    public static func isolated() -> URLSessionHTTPClient {
        isolated(protocolClasses: nil)
    }

    /// `isolated()` with stub protocols in front, for tests.
    static func isolated(protocolClasses: [AnyClass]?) -> URLSessionHTTPClient {
        let configuration = makeDefaultConfiguration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSessionHTTPClient(session: URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil))
    }

    /// For tests, which pass a session with a stub protocol.
    public init(session: URLSession) {
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

/// Answers every redirect with "do not follow", so the redirect response itself is returned to the caller.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
