import NoSlopKit
import SwiftUI

/// Runs "Sign in with Google" and "Sign out" for the Library header and the Settings account section, so both
/// show the same busy state and the same error message. It also keeps the web authenticator alive while the
/// sign-in page is open.
@MainActor
@Observable
final class GoogleSignInFlow {
    private(set) var isWorking = false
    /// Set when a sign-in fails (not when the user simply closes the page); the screen shows it in an alert.
    var errorMessage: String?

    @ObservationIgnored private let authenticator = ASWebAuthenticator()

    func signIn(using env: AppEnvironment) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await env.signIn(authenticator: authenticator)
        } catch NoSlopError.cancelled {
            // The user closed the sign-in page.
        } catch is CancellationError {
            // The screen went away.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut(using env: AppEnvironment) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await env.signOut()
    }
}

/// What the OAuth client ID typed into Settings is good for. It is judged by `GoogleOAuthConfig`, the check the
/// sign-in itself makes, so no button starts a sign-in that is certain to fail.
enum GoogleClientIDStatus {
    case empty, valid, invalid

    init(clientID: String) {
        let text = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            self = .empty
        } else {
            self = GoogleOAuthConfig(clientID: text) != nil ? .valid : .invalid
        }
    }
}

/// "Sign out" with its confirmation. The confirmation is attached to the button so it appears next to it.
struct GoogleSignOutButton: View {
    let flow: GoogleSignInFlow

    @Environment(AppEnvironment.self) private var env
    @State private var isConfirming = false

    var body: some View {
        Button("Sign out") {
            isConfirming = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(flow.isWorking)
        .confirmationDialog("Sign out of Google?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await flow.signOut(using: env) }
            }
        } message: {
            Text("Your subscriptions stay on this device.")
        }
    }
}

/// The top of the Library tab: a "Sign in with Google" call to action, or the signed-in account with "Sign out".
///
/// Signing in needs the OAuth client ID from Settings; while it is empty or not a client ID at all (see
/// `GoogleClientIDStatus`), tapping the call to action opens the setup guide instead of the sign-in page. Meant to sit
/// in a `List` section.
struct AccountHeaderView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var flow = GoogleSignInFlow()
    @State private var isShowingGuide = false

    var body: some View {
        Group {
            if let account = env.googleAccount {
                signedIn(account)
            } else {
                signedOut
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            GoogleSetupGuideSheet()
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
    }

    // MARK: Signed out

    /// A client ID that can start a sign-in; an empty or malformed one needs the guide instead.
    private var isConfigured: Bool {
        GoogleClientIDStatus(clientID: env.settings.googleClientID) == .valid
    }

    private var signedOut: some View {
        Button {
            if isConfigured {
                Task { await flow.signIn(using: env) }
            } else {
                isShowingGuide = true
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in with Google")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(
                        isConfigured
                            ? "Bring your YouTube subscriptions, playlists and likes."
                            : "Optional. Set up Google sign-in to bring your subscriptions, playlists and likes."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if flow.isWorking {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(flow.isWorking)
        .accessibilityHint(isConfigured ? "Opens the Google sign-in page" : "Opens the setup guide")
    }

    // MARK: Signed in

    private func signedIn(_ account: GoogleAccount) -> some View {
        HStack(spacing: 14) {
            ChannelAvatarView(url: account.pictureURL, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: account))
                    .font(.headline)
                    .lineLimit(1)
                if account.name != nil, let email = account.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("Signed in with Google")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            GoogleSignOutButton(flow: flow)
        }
    }

    private func displayName(for account: GoogleAccount) -> String {
        if let name = account.name, !name.isEmpty { return name }
        if let email = account.email, !email.isEmpty { return email }
        return "Google account"
    }
}

#Preview("Signed out") {
    List { Section { AccountHeaderView() } }
        .environment(AppEnvironment.preview())
}
