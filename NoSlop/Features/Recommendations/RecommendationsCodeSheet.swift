import NoSlopKit
import SwiftUI

/// The sheet that shows the sign-in code: type it on Google's page, or open the page with the code already in it.
struct RecommendationsCodeSheet: View {
    let prompt: TVSignInPrompt
    let flow: RecommendationsConnectFlow

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Enter this code on Google's page")
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(prompt.userCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(prompt.userCode)")

                    HStack(spacing: 12) {
                        Button(copied ? "Copied" : "Copy Code") {
                            UIPasteboard.general.string = prompt.userCode
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        Button("Open Google's page") {
                            openURL(prompt.verificationURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        countdown(at: context.date)
                    }

                    Text("Google's page will say YouTube on TV. That's expected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { flow.cancel() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { flow.pollNow() }
        }
        .onDisappear { flow.cancel() }
    }

    @ViewBuilder
    private func countdown(at date: Date) -> some View {
        let left = max(0, Int(prompt.expiresAt.timeIntervalSince(date).rounded(.up)))
        HStack(spacing: 8) {
            ProgressView()
            Text(left > 0 ? "Waiting for approval. The code works for \(Self.clock(left))." : "The code expired. Cancel and start again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension View {
    /// Presents the code sheet while the flow has a code, and its error as an alert.
    func recommendationsConnectPresentation(_ flow: RecommendationsConnectFlow) -> some View {
        sheet(
            isPresented: Binding(
                get: { flow.prompt != nil },
                set: { if !$0 { flow.cancel() } }
            )
        ) {
            if let prompt = flow.prompt {
                RecommendationsCodeSheet(prompt: prompt, flow: flow)
            }
        }
        .alert(
            "YouTube recommendations",
            isPresented: Binding(
                get: { flow.errorMessage != nil },
                set: { if !$0 { flow.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(flow.errorMessage ?? "")
        }
    }
}
