import NoSlopKit
import SwiftUI

/// "Subscribe" (filled) or "Subscribed" (gray). Tapping toggles the subscription through
/// `AppEnvironment.toggleSubscription`: on the Google account when signed in, locally otherwise.
struct SubscribeButton: View {
    let channel: ChannelRef

    @Environment(AppEnvironment.self) private var env
    @State private var isWorking = false
    @State private var failure: Error?

    var body: some View {
        let subscribed = env.isSubscribed(channel.id)
        Button {
            toggle()
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
        .accessibilityHint(subscribed ? "Double tap to unsubscribe" : "")
        .alert(
            "Couldn't update the subscription",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((failure as? LocalizedError)?.errorDescription ?? failure?.localizedDescription ?? "")
        }
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
