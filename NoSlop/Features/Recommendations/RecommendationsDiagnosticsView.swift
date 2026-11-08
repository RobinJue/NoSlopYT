import NoSlopKit
import SwiftUI

/// What the YouTube recommendations connection did last, in plain rows. Only presence flags, counts and short words:
/// no token, code or tracking value is ever shown or saved here.
struct RecommendationsDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var savedMessage: String?
    @State private var isSaving = false

    var body: some View {
        let d = env.recommendationsDiagnostics

        List {
            Section("Connection") {
                row("Connected", yesNo(env.recommendationsAccount != nil))
                row("Access token", d.tokenSecondsLeft.map { $0 > 0 ? "valid, \(Self.minutes($0)) left" : "expired" } ?? "none")
                row("Reporting", d.pausedReporting ? "paused" : "on")
            }

            Section("Last Home load") {
                if let home = d.lastHome {
                    row("When", Self.time(home.at))
                    row("Recipe", home.recipe)
                    row("Status", home.status.map(String.init) ?? "none")
                    row("Signed in on YouTube", home.loggedIn.map(yesNo) ?? "unknown")
                    row("Videos", String(home.videos))
                    row("Shorts left out", String(home.shorts))
                    row("Shown", home.usedYouTube ? "YouTube's Home" : "the mix on this device")
                    if !home.skipped.isEmpty {
                        row("Left out", Self.counts(home.skipped))
                    }
                    if !home.unknown.isEmpty {
                        row("Not recognised", Self.counts(home.unknown))
                    }
                } else {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
            }

            Section("Last Home card action") {
                if let action = d.lastCardAction {
                    row("When", Self.time(action.at))
                    row("Action", action.kind)
                    row("Status", action.status.map(String.init) ?? "none")
                    row("Accepted", yesNo(action.accepted))
                } else {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
            }

            Section("Last watch report") {
                if let report = d.lastReport {
                    row("When", Self.time(report.at))
                    row("Result", report.status)
                    row("Player reply", report.playerStatus ?? "none")
                    row("Report data present", [report.hasEI ? "ei" : nil, report.hasVM ? "vm" : nil, report.hasOF ? "of" : nil]
                        .compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "none")
                    row("Pings", report.pingStatuses.isEmpty ? "none" : report.pingStatuses.map(String.init).joined(separator: ", "))
                } else {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Save diagnostics")
                        Spacer(minLength: 8)
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(isSaving)
            } footer: {
                Text(savedMessage ?? "Saves a short file with the same flags and counts. It has no tokens or account details, but it lists the video and channel ids of YouTube's recent Home. It is removed when you disconnect.")
            }
        }
        .miniPlayerClearance()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.refreshRecommendationsDiagnostics() }
        .refreshable { await env.refreshRecommendationsDiagnostics() }
    }

    // MARK: Rows

    private func row(_ title: String, _ value: String) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title)
            if !stacked { Spacer(minLength: 8) }
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(stacked ? .leading : .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func minutes(_ seconds: Int) -> String {
        seconds >= 120 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static func counts(_ values: [String: Int]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    // MARK: Save

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        await env.refreshRecommendationsDiagnostics()
        var object: [String: JSON] = (await env.recommendations.diagnosticsSample()).object ?? [:]
        object["connected"] = .bool(env.recommendationsAccount != nil)
        object["tokenSecondsLeft"] = env.recommendationsDiagnostics.tokenSecondsLeft.map { .number(Double($0)) } ?? .null
        object["pausedReporting"] = .bool(env.recommendationsDiagnostics.pausedReporting)
        object["showYouTubeHome"] = .bool(env.settings.showYouTubeHome)
        object["tellYouTubeAboutHiding"] = .bool(env.settings.tellYouTubeAboutHiding)
        object["sendWatchesToYouTube"] = .bool(env.settings.sendWatchesToYouTube)
        object["savedAt"] = .string(ISO8601DateFormatter().string(from: Date()))

        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "recommendations-\(formatter.string(from: Date())).json"
            let folder = URL.documentsDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSON.object(object).data()
            // The last gate: nothing that looks like a token, a header or an address goes to disk.
            guard TVScrubber.leaks(String(decoding: data, as: UTF8.self)).isEmpty else {
                savedMessage = "The file was not saved: it held something that looks like a token or an address."
                return
            }
            try data.write(to: folder.appending(path: name), options: .atomic)
            savedMessage = "Saved as Documents/Diagnostics/\(name) in this app's folder."
        } catch {
            savedMessage = "The file couldn't be saved."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
