import NoSlopKit
import SwiftUI

/// Account: the Google OAuth client ID (checked with `GoogleOAuthConfig`), sign in / sign out, and the setup guide.
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

            VStack(alignment: .leading, spacing: 8) {
                // The field below is named for VoiceOver (it would otherwise be announced by its example text), so this
                // visible name is not read a second time.
                Text("OAuth client ID")
                    .font(.subheadline)
                    .accessibilityHidden(true)
                TextField("1234-abcd.apps.googleusercontent.com", text: $store.settings.googleClientID)
                    .accessibilityLabel("OAuth client ID")
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .disabled(signedInAccount != nil)
                    .foregroundStyle(signedInAccount != nil ? Color.secondary : Color.primary)
                validationLabel
            }
            .padding(.vertical, 2)
            // Presented from this row: the section itself is not a view that can host a presentation.
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

            NavigationLink {
                GoogleSetupGuideView()
            } label: {
                Label("How to set up Google sign-in", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Account")
        } footer: {
            Text(
                signedInAccount == nil
                    ? "Optional. Signing in shows your own subscriptions, playlists and liked videos, and lets you subscribe and like on your account. Without it everything else works."
                    : "Sign out to change the client ID."
            )
        }
    }

    // MARK: Client ID

    private var status: GoogleClientIDStatus {
        GoogleClientIDStatus(clientID: env.settings.googleClientID)
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
