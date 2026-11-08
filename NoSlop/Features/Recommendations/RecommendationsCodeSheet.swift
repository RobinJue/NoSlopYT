import NoSlopKit
import SwiftUI

/// The sheet that shows the sign-in code: type it on Google's page, or open the page with the code already in it.
struct RecommendationsCodeSheet: View {
    let prompt: TVSignInPrompt
    let flow: RecommendationsConnectFlow

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let failure = flow.failure {
                        failureContent(failure)
                    } else {
                        codeContent
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.failure == nil ? "Cancel" : "Close") { flow.cancel("Cancel button") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: scenePhase) { _, phase in
            TVTrace.log("sheet: scene phase \(String(describing: phase))")
            if phase == .active { flow.pollNow() }
        }
        // Going to Safari to approve the code takes the app to the background, and iOS reports the sheet as gone
        // then. That is not the person closing it: nothing here may end the sign-in.
        .onAppear { TVTrace.log("sheet: appeared") }
        .onDisappear { TVTrace.log("sheet: disappeared") }
    }

    @ViewBuilder
    private var codeContent: some View {
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

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { copyButton; openButton }
            VStack(spacing: 12) { copyButton; openButton }
        }

        TimelineView(.periodic(from: .now, by: 1)) { context in
            countdown(at: context.date)
        }

        Text("Google's page will say YouTube on TV. That's expected.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// What went wrong, in the sheet that was open when it happened, with a way to start again.
    @ViewBuilder
    private func failureContent(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

        Text(message)
            .font(.headline)
            .multilineTextAlignment(.center)

        Button {
            Task { await flow.connect(using: env) }
        } label: {
            if flow.isWorking {
                ProgressView()
            } else {
                Text("Try again")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(flow.isWorking)
    }

    private var copyButton: some View {
        Button(copied ? "Copied" : "Copy Code") {
            UIPasteboard.general.string = prompt.userCode
            copied = true
        }
        .buttonStyle(.bordered)
    }

    private var openButton: some View {
        Button("Open Google's page") {
            openURL(prompt.verificationURL)
        }
        .buttonStyle(.borderedProminent)
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
    /// Presents the code sheet while the flow has a code (it also says why the sign-in failed), and the error of a
    /// sign-in that could not even start as an alert.
    func recommendationsConnectPresentation(_ flow: RecommendationsConnectFlow) -> some View {
        sheet(
            isPresented: Binding(
                get: { flow.prompt != nil },
                set: { if !$0 { flow.cancel("sheet binding") } }
            )
        ) {
            if let prompt = flow.prompt {
                RecommendationsCodeSheet(prompt: prompt, flow: flow)
                    .id(prompt.userCode)
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
