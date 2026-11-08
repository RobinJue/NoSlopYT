import NoSlopKit
import SwiftUI
import UIKit

/// The one-time setup for Google sign-in, step by step: a Google Cloud project with the YouTube Data API, a consent
/// screen, an iOS OAuth client for this app's bundle ID, and pasting the client ID into Settings.
///
/// Pushed from Settings → Account, or shown in a sheet from the Library (`GoogleSetupGuideSheet`), where
/// `openSettings` adds an "Open Settings" button to the last step.
///
/// Pushed in a tab's navigation stack it leaves room under its last step for the mini player, which sits over that
/// stack. A sheet covers the mini player, so there it adds nothing (`leavesRoomForMiniPlayer`).
struct GoogleSetupGuideView: View {
    var openSettings: (() -> Void)?
    /// Whether the guide leaves room at the bottom for the mini player: true when it is pushed in a navigation stack that
    /// sits under it, false in a sheet.
    var leavesRoomForMiniPlayer: Bool

    @State private var hasCopiedBundleID = false

    init(openSettings: (() -> Void)? = nil, leavesRoomForMiniPlayer: Bool = true) {
        self.openSettings = openSettings
        self.leavesRoomForMiniPlayer = leavesRoomForMiniPlayer
    }

    /// With a shared project signing in needs no setup, so these steps are for the user who wants a project of their own.
    private var introduction: String {
        let what = "Signing in is optional. It lets No Slop show your YouTube subscriptions, playlists and liked videos, and subscribe or like on your real account."
        if GoogleOAuthConfig.hasSharedProject {
            return what + " By default it uses the Google project of No Slop's author and needs no setup. Follow these steps only to use a project of your own instead: then nothing goes through anyone else's project, and its daily limit is yours alone. It takes about five minutes, once."
        }
        return what + " You create your own Google project, so nothing goes through anyone else's servers. It takes about five minutes, once."
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.robinjungerich.noslopyt"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(introduction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GuideStepRow(
                    number: 1,
                    title: "Create a project",
                    detail: "Open the Google Cloud console and create a new project. Any name works, for example No Slop."
                ) {
                    guideLink("Open Google Cloud console", "https://console.cloud.google.com/projectcreate")
                }

                GuideStepRow(
                    number: 2,
                    title: "Enable the YouTube Data API",
                    detail: "In **APIs & Services → Library**, search for **YouTube Data API v3** and press **Enable**.\n\nSigning in works without this step, but nothing else does: if the app later says the YouTube Data API isn't turned on, this is the step to check. A change can take a minute to take effect."
                ) {
                    EmptyView()
                }

                GuideStepRow(
                    number: 3,
                    title: "Set up the consent screen",
                    detail: "Under **OAuth consent screen** (Google Auth platform), choose **External** and fill in an app name and your email. Add your own Google account as a **test user**.\n\nIn Testing mode Google signs you out every 7 days. To avoid that, publish the app (**In production**). It does not need verification for personal use; Google just shows an \"unverified app\" notice when you sign in."
                ) {
                    EmptyView()
                }

                GuideStepRow(
                    number: 4,
                    title: "Create an iOS client",
                    detail: "Under **Credentials**, choose **Create credentials → OAuth client ID**. Set the application type to **iOS** and enter this bundle ID:"
                ) {
                    bundleIDRow
                }

                GuideStepRow(
                    number: 5,
                    title: "Paste the client ID",
                    detail: "Copy the client ID (it ends in .apps.googleusercontent.com) and paste it into **Settings → Account**. Then tap **Sign in with Google**."
                ) {
                    if let openSettings {
                        Button("Open Settings", action: openSettings)
                            .buttonStyle(.borderedProminent)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("No Slop only uses the official YouTube Data API, with the permission you grant. Your sign-in stays in this device's Keychain, and you can revoke access at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    guideLink("Review Google account permissions", "https://myaccount.google.com/permissions")
                        .font(.footnote)
                }
            }
            .padding(Theme.padding + 4)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .modifier(OptionalMiniPlayerClearance(applies: leavesRoomForMiniPlayer))
        .navigationTitle("Set up Google sign-in")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var bundleIDRow: some View {
        HStack(spacing: 10) {
            Text(bundleID)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = bundleID
                hasCopiedBundleID = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    hasCopiedBundleID = false
                }
            } label: {
                Label(hasCopiedBundleID ? "Copied" : "Copy", systemImage: hasCopiedBundleID ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func guideLink(_ title: String, _ address: String) -> some View {
        if let url = URL(string: address) {
            Link(destination: url) {
                Label(title, systemImage: "arrow.up.right.square")
            }
        }
    }
}

/// `miniPlayerClearance()` when `applies`, nothing otherwise.
private struct OptionalMiniPlayerClearance: ViewModifier {
    let applies: Bool

    func body(content: Content) -> some View {
        if applies {
            content.miniPlayerClearance()
        } else {
            content
        }
    }
}

/// One numbered step: a badge, a title, an explanation (with **bold** markup) and optional actions underneath.
private struct GuideStepRow<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    let actions: Actions

    init(number: Int, title: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.number = number
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: Circle())
                .accessibilityLabel("Step \(number)")

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                // Instructions the reader has to follow exactly: full contrast, not the grey of a caption.
                Text(LocalizedStringKey(detail))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The guide in a sheet of its own, for the Library tab: a "Done" button, and "Open Settings" on the last step. The sheet
/// covers the mini player, so the guide leaves no room for it.
struct GoogleSetupGuideSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GoogleSetupGuideView(
                openSettings: {
                    dismiss()
                    env.show(.settings)
                },
                leavesRoomForMiniPlayer: false
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        GoogleSetupGuideView()
    }
    .environment(AppEnvironment.preview())
}
