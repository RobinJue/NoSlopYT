import Foundation

/// A short trace of the TV sign-in, for finding out why a sign-in did not finish. A line carries steps and outcome names
/// only: never a token, a code, a client value or an address.
///
/// Once the app has called `keep(in:)`, the last lines are kept in that file (they survive the app being closed), and with
/// `-tvTrace YES` at launch every line also goes to standard error.
public enum TVTrace {
    /// Whether lines are also written to standard error (`-tvTrace YES`).
    public static let echoes: Bool = UserDefaults.standard.bool(forKey: "tvTrace")

    private static let sink = Sink()

    /// Starts keeping the trace in `file`, with the lines it already holds.
    public static func keep(in file: URL) {
        sink.keep(in: file)
    }

    public static func log(_ line: @autoclosure () -> String) {
        let text = line()
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        sink.append("\(stamp) \(text)")
        if echoes { fputs("[tvtrace] \(text)\n", stderr) }
    }

    /// The lines kept so far, oldest first.
    public static func lines() -> [String] {
        sink.snapshot()
    }

    /// An error as a short phrase for the trace: our own plain sentences, or just the domain and code of a foreign one.
    public static func describe(_ error: any Error) -> String {
        if let known = error as? NoSlopError { return "NoSlopError(\(known.errorDescription ?? "?"))" }
        if error is CancellationError { return "CancellationError" }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    /// An OAuth error name from a reply, kept only if it looks like one (letters, digits, underscore; at most 40).
    public static func oauthName(_ value: String?) -> String {
        guard let value else { return "none" }
        let allowed = value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        return allowed && value.count <= 40 ? value : "other"
    }

    final class Sink: @unchecked Sendable {
        private static let limit = 200

        private let lock = NSLock()
        private var file: URL?
        private var kept: [String] = []

        func keep(in url: URL) {
            lock.withLock {
                file = url
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    kept = text.split(separator: "\n").map(String.init) + kept
                    trim()
                }
            }
        }

        func append(_ line: String) {
            lock.withLock {
                kept.append(line)
                trim()
                guard let file else { return }
                try? Data(kept.joined(separator: "\n").appending("\n").utf8).write(to: file, options: .atomic)
            }
        }

        func snapshot() -> [String] {
            lock.withLock { kept }
        }

        private func trim() {
            if kept.count > Self.limit { kept.removeFirst(kept.count - Self.limit / 2) }
        }
    }
}
