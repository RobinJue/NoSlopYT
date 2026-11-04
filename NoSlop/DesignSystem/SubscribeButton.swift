import NoSlopKit
import SwiftUI

/// "Subscribe" (filled) or "Subscribed" (gray). Tapping toggles the subscription through
/// `AppEnvironment.toggleSubscription`: on the Google account when signed in, locally otherwise.
///
/// Subscribing is one tap. Unsubscribing asks first, as the YouTube app does: the grey "Subscribed" capsule looks like a
/// status label and sits at the edge of rows that open the channel, and for a subscription on the Google account the
/// unsubscribe is made on the real account, with no undo.
struct SubscribeButton: View {
    let channel: ChannelRef

    @Environment(AppEnvironment.self) private var env
    @State private var isWorking = false
    @State private var isConfirmingUnsubscribe = false
    @State private var failure: Error?

    var body: some View {
        let subscribed = env.isSubscribed(channel.id)
        Button {
            if subscribed {
                isConfirmingUnsubscribe = true
            } else {
                toggle()
            }
        } label: {
            Text(subscribed ? "Subscribed" : "Subscribe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(subscribed ? Color.primary : Color(.systemBackground))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    subscribed ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(Color.primary),
                    in: Capsule()
                )
                .opacity(isWorking ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(subscribed ? "Subscribed to \(channel.name)" : "Subscribe to \(channel.name)")
        .accessibilityHint(subscribed ? "Asks you to confirm, then unsubscribes" : "")
        // On the button itself, so that on an iPad the popover points at it.
        .confirmationDialog(
            "Unsubscribe from \(channel.name.isEmpty ? "this channel" : channel.name)?",
            isPresented: $isConfirmingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                // The subscription may be gone while the dialog was open (a sync removed it); toggling would then
                // subscribe instead of unsubscribing.
                if env.isSubscribed(channel.id) { toggle() }
            }
        } message: {
            if isOnGoogleAccount {
                Text("This also removes the subscription from your YouTube account.")
            }
        }
        .alert(
            "Couldn't update the subscription",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((failure as? LocalizedError)?.errorDescription ?? failure?.localizedDescription ?? "")
        }
    }

    /// The subscription lives on the signed-in Google account, so unsubscribing reaches it too.
    private var isOnGoogleAccount: Bool {
        guard env.googleAccount != nil, let subscription = env.library.subscriptions.first(where: { $0.id == channel.id }) else {
            return false
        }
        if case .google = subscription.source { return true }
        return false
    }

    private func toggle() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await env.toggleSubscription(channel)
            } catch is CancellationError {
                // The screen went away; nothing to report.
            } catch NoSlopError.cancelled {
                // Same, as reported by the kit.
            } catch {
                failure = error
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SubscribeButton(channel: SampleData.blender.ref)
        SubscribeButton(channel: SampleData.blenderGuru.ref)
    }
    .environment(AppEnvironment.preview())
    .padding()
}
