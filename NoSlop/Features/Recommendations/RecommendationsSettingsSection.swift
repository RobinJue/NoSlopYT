import NoSlopKit
import SwiftUI

/// Settings: the YouTube recommendations connection, its three switches and the Diagnostics screen.
struct RecommendationsSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var flow = RecommendationsConnectFlow()
    @State private var isConfirmingDisconnect = false
    @State private var isDisconnecting = false
    @State private var disconnectNotice: String?

    var body: some View {
        @Bindable var store = env.settingsStore
        let account = env.recommendationsAccount

        Section {
            statusRow(account)

            if account == nil {
                Button {
                    Task { await flow.connect(using: env) }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer(minLength: 8)
                        if flow.isWorking { ProgressView() }
                    }
                }
                .disabled(flow.isWorking)
            } else {
                Button("Disconnect", role: .destructive) {
                    isConfirmingDisconnect = true
                }
                .disabled(isDisconnecting)
                .confirmationDialog(
                    "Disconnect YouTube recommendations?",
                    isPresented: $isConfirmingDisconnect,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) {
                        isDisconnecting = true
                        Task {
                            let result = await env.disconnectRecommendations()
                            isDisconnecting = false
                            disconnectNotice = Self.notice(for: result)
                        }
                    }
                } message: {
                    Text("Home goes back to the mix made on this device.")
                }
            }

            Toggle("Show YouTube's Home", isOn: $store.settings.showYouTubeHome)
            Toggle("Tell YouTube when I hide a video or a channel from Home", isOn: $store.settings.tellYouTubeAboutHiding)
            Toggle("Send what I watch to YouTube", isOn: $store.settings.sendWatchesToYouTube)
                .onChange(of: store.settings.sendWatchesToYouTube) { _, isOn in
                    // Off means nothing about the watches is kept or sent later, not even what was waiting to be sent.
                    if !isOn { Task { await env.watchReporter.sharingTurnedOff() } }
                }

            NavigationLink {
                RecommendationsDiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        } header: {
            Text("YouTube recommendations")
        } footer: {
            Text("Uses YouTube's TV sign-in, not an official API, separate from the Google sign-in above. It can be another Google account and it can stop working when YouTube changes something.")
        }
        .recommendationsConnectPresentation(flow)
        .alert("Disconnected", isPresented: Binding(get: { disconnectNotice != nil }, set: { if !$0 { disconnectNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(disconnectNotice ?? "")
        }
    }

    /// Nil when Google confirmed the revoke and the sign-in is gone from the device; otherwise what the owner still has
    /// to do. The grant is named as the README does: YouTube TV.
    private static func notice(for result: TVDisconnectResult) -> String? {
        let reach = "Remove YouTube TV under Google Account, Security, third-party connections, to end the access."
        if !result.clearedLocally {
            return "The sign-in could not be removed from this device. \(reach)"
        }
        if !result.revoked {
            return "Disconnected on this device. Google could not be reached to end the access. \(reach)"
        }
        return nil
    }

    private func statusRow(_ account: TVAccount?) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text("Status")
            if !stacked { Spacer(minLength: 8) }
            Text(statusText(account))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(stacked ? .leading : .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ account: TVAccount?) -> String {
        guard let account else { return "Not connected" }
        if let name = account.name, !name.isEmpty { return "Connected · \(name)" }
        return "Connected"
    }
}
