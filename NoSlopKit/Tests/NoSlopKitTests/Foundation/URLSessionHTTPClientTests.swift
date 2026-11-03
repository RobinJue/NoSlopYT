import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

/// Answers requests to the hosts that tests registered, so a real `URLSession` can be exercised without a network.
/// Every test registers a host name of its own, which keeps tests that run in parallel apart.
private final class HTTPClientStubProtocol: URLProtocol {
    enum Reply: Sendable {
        case response(status: Int, body: Data)
        case notHTTP
        case failure(URLError.Code)
    }

    private static let replies = Mutex<[String: Reply]>([:])

    static func register(_ reply: Reply) -> String {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        replies.withLock { $0[host] = reply }
        return host
    }

    private static func reply(for request: URLRequest) -> Reply? {
        guard let host = request.url?.host else { return nil }
        return replies.withLock { $0[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        reply(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let reply = Self.reply(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .notHTTP:
            client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .response(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite struct URLSessionHTTPClientTests {
    // MARK: Privacy

    @Test func theDefaultSessionStoresAndSendsNoCookies() {
        let configuration = URLSessionHTTPClient.defaultSession.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }

    @Test func theDefaultSessionKeepsNothingInTheURLCache() {
        let configuration = URLSessionHTTPClient.defaultSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func theDefaultSessionHasTimeoutsThatFitSmallAPIRequests() {
        let configuration = URLSessionHTTPClient.defaultSession.configuration
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 120)
        #expect(!configuration.waitsForConnectivity, "offline must fail at once, not wait")
    }

    @Test func theConfigurationIsAFreshDefaultOneNotTheSharedOrEphemeralOne() {
        let configuration = URLSessionHTTPClient.makeDefaultConfiguration()
        #expect(configuration.identifier == nil, "not a background session")
        #expect(configuration.httpCookieStorage == nil && configuration.urlCache == nil)
        // Making one does not change the system's default configuration for everybody else.
        #expect(URLSessionConfiguration.default.httpCookieStorage != nil)
    }

    @Test func everyClientMadeWithoutASessionSharesTheDefaultSession() {
        #expect(URLSessionHTTPClient().session === URLSessionHTTPClient.defaultSession)
        #expect(URLSessionHTTPClient().session === URLSessionHTTPClient().session)
    }

    @Test func aSessionCanStillBeInjected() {
        let session = URLSession(configuration: .ephemeral)
        #expect(URLSessionHTTPClient(session: session).session === session)
    }

    // MARK: Sending

    private func client(for reply: HTTPClientStubProtocol.Reply) -> (client: URLSessionHTTPClient, host: String) {
        let host = HTTPClientStubProtocol.register(reply)
        let configuration = URLSessionHTTPClient.makeDefaultConfiguration()
        configuration.protocolClasses = [HTTPClientStubProtocol.self]
        return (URLSessionHTTPClient(session: URLSession(configuration: configuration)), host)
    }

    @Test func aResponseComesBackWhateverItsStatus() async throws {
        for status in [200, 404, 500] {
            let (client, host) = client(for: .response(status: status, body: Data("{}".utf8)))
            let (data, response) = try await client.send(URLRequest(url: URL(string: "https://\(host)/x")!))
            #expect(response.statusCode == status)
            #expect(data == Data("{}".utf8))
        }
    }

    @Test func cancellationAndNetworkErrorsAreMapped() async throws {
        let (cancelled, cancelledHost) = client(for: .failure(.cancelled))
        await #expect(throws: NoSlopError.cancelled) {
            _ = try await cancelled.send(URLRequest(url: URL(string: "https://\(cancelledHost)/x")!))
        }

        let (offline, offlineHost) = client(for: .failure(.notConnectedToInternet))
        do {
            _ = try await offline.send(URLRequest(url: URL(string: "https://\(offlineHost)/x")!))
            Issue.record("expected a network error")
        } catch let error as NoSlopError {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }

    @Test func aResponseThatIsNotHTTPIsANetworkError() async throws {
        let (client, host) = client(for: .notHTTP)
        do {
            _ = try await client.send(URLRequest(url: URL(string: "https://\(host)/x")!))
            Issue.record("expected a network error")
        } catch let error as NoSlopError {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }
}
