import NoSlopKit
import SwiftUI

/// Account: which Google project signs you in (the app's shared one by default, or your own with its OAuth client ID,
/// checked with `GoogleOAuthConfig`), sign in / sign out, and the setup guide for your own project.
/// "Sign in with Google" is only available for a client ID that passes that check.
struct AccountSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var flow = GoogleSignInFlow()

    var body: some View {
        @Bindable var store = env.settingsStore
        let signedInAccount = env.googleAccount

        Section {
            if let account = signedInAccount {
                signedInRow(account)
            }

            // The first row that is always there; the sign-in alert is presented from it, because the section itself is
            // not a view that can host a presentation and the client ID row below is not always shown.
            Group {
                if GoogleOAuthConfig.hasSharedProject {
                    Toggle("Use my own Google project", isOn: $store.settings.useOwnGoogleProject)
                        .disabled(signedInAccount != nil)
                } else {
                    clientIDField(signedIn: signedInAccount != nil, binding: $store.settings.googleClientID)
                }
            }
            .alert(
                "Google sign-in",
                isPresented: Binding(
                    get: { flow.errorMessage != nil },
                    set: { if !$0 { flow.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.errorMessage ?? "")
            }

            if GoogleOAuthConfig.hasSharedProject {
                if usesOwnProject {
                    clientIDField(signedIn: signedInAccount != nil, binding: $store.settings.googleClientID)
                } else {
                    Text("Signing in goes through the Google project of No Slop's author. Google will say that it hasn't verified the app: that is expected, and you can continue. The project's daily limit is shared by everyone who uses it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if signedInAccount == nil {
                Button {
                    Task { await flow.signIn(using: env) }
                } label: {
                    HStack {
                        Text("Sign in with Google")
                        Spacer(minLength: 8)
                        if flow.isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(status != .valid || flow.isWorking)
            }

            if usesOwnProject {
                NavigationLink {
                    GoogleSetupGuideView()
                } label: {
                    Label("How to set up Google sign-in", systemImage: "questionmark.circle")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text(
                signedInAccount == nil
                    ? "Optional. Signing in shows your own subscriptions, playlists and liked videos, and lets you subscribe and like on your account. Without it everything else works."
                    : "Sign out to change the Google project."
            )
        }
    }

    // MARK: Client ID

    /// Whether sign-in uses a project of the user's own: chosen, or the only choice when there is no shared project.
    private var usesOwnProject: Bool {
        env.settings.useOwnGoogleProject || !GoogleOAuthConfig.hasSharedProject
    }

    private var status: GoogleClientIDStatus {
        GoogleClientIDStatus(clientID: env.effectiveGoogleClientID)
    }

    private func clientIDField(signedIn: Bool, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The field below is named for VoiceOver (it would otherwise be announced by its example text), so this
            // visible name is not read a second time.
            Text("OAuth client ID")
                .font(.subheadline)
                .accessibilityHidden(true)
            TextField("1234-abcd.apps.googleusercontent.com", text: binding)
                .accessibilityLabel("OAuth client ID")
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .disabled(signedIn)
                .foregroundStyle(signedIn ? Color.secondary : Color.primary)
            validationLabel
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch status {
        case .empty:
            Text("Paste the client ID of the iOS OAuth client you created in Google Cloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .valid:
            Label("Looks like a valid client ID", systemImage: "checkmark.circle.fill")
                .labelStyle(.tight)
                .font(.footnote)
                .foregroundStyle(.green)
        case .invalid:
            Label("A client ID ends with .apps.googleusercontent.com", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.tight)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Signed in

    private func signedInRow(_ account: GoogleAccount) -> some View {
        // Side by side, "Sign out" leaves the name a few letters at accessibility text sizes. There the name and email
        // wrap over the whole width and the button goes under them.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            HStack(spacing: 12) {
                ChannelAvatarView(url: account.pictureURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name ?? account.email ?? "Google account")
                        .font(.body)
                        .lineLimit(stacked ? nil : 1)
                    if account.name != nil, let email = account.email {
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(stacked ? nil : 1)
                    }
                }
            }
            if !stacked {
                Spacer(minLength: 8)
            }
            // The button keeps its width; a long name is what gets cut.
            GoogleSignOutButton(flow: flow)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
