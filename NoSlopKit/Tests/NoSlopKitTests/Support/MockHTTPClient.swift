import Foundation
@testable import NoSlopKit

/// A scripted `HTTPClient` for tests.
///
/// Queue replies with `enqueue` / `enqueueError`; each request is answered by the first queued reply whose `match`
/// is a substring of the request URL. Replies for the same `match` are served in FIFO order, and the last one left
/// is reused for every further request. A request that matches nothing throws `NoSlopError.http(status: 404)`.
/// Every request (matched or not) is recorded in `requests`.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private enum Reply {
        case response(status: Int, body: Data, headers: [String: String])
        case failure(any Error)
    }

    private struct Entry {
        let match: String
        let reply: Reply
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var received: [URLRequest] = []

    init() {}

    func enqueue(_ match: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        lock.withLock {
            entries.append(Entry(match: match, reply: .response(status: status, body: body, headers: headers)))
        }
    }

    func enqueueError(_ match: String, _ error: Error) {
        lock.withLock {
            entries.append(Entry(match: match, reply: .failure(error)))
        }
    }

    /// Every request received so far, in order.
    var requests: [URLRequest] {
        lock.withLock { received }
    }

    /// The JSON body of `request`, or nil when it has none or it is not JSON.
    func bodyJSON(of request: URLRequest) -> JSON? {
        guard let body = request.httpBody, !body.isEmpty else { return nil }
        return try? JSON(data: body)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            received.append(request)
            let url = request.url?.absoluteString ?? ""
            guard let index = entries.firstIndex(where: { url.contains($0.match) }) else { return nil }
            let entry = entries[index]
            // FIFO per match; the last reply for a match stays queued so it can answer repeated requests.
            if entries.filter({ $0.match == entry.match }).count > 1 {
                entries.remove(at: index)
            }
            return entry.reply
        }

        guard let reply else { throw NoSlopError.http(status: 404) }
        switch reply {
        case .failure(let error):
            throw error
        case .response(let status, let body, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw NoSlopError.network("MockHTTPClient could not build a response for \(request.url?.absoluteString ?? "nil").")
            }
            return (body, response)
        }
    }
}
