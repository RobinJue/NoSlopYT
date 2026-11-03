import NoSlopKit
import SwiftUI

/// Account: the Google OAuth client ID (checked with `GoogleOAuthConfig`), sign in / sign out, and the setup guide.
struct AccountSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var flow = GoogleSignInFlow()

    private enum ClientIDStatus {
        case empty, valid, invalid
    }

    var body: some View {
        @Bindable var store = env.settingsStore
        let signedInAccount = env.googleAccount

        Section {
            if let account = signedInAccount {
                signedInRow(account)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OAuth client ID")
                    .font(.subheadline)
                TextField("1234-abcd.apps.googleusercontent.com", text: $store.settings.googleClientID)
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
                .disabled(status == .empty || flow.isWorking)
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

    private var status: ClientIDStatus {
        let text = env.settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        return GoogleOAuthConfig(clientID: text) != nil ? .valid : .invalid
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
        HStack(spacing: 12) {
            ChannelAvatarView(url: account.pictureURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name ?? account.email ?? "Google account")
                    .font(.body)
                    .lineLimit(1)
                if account.name != nil, let email = account.email {
                    Text(email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            GoogleSignOutButton(flow: flow)
        }
    }
}
