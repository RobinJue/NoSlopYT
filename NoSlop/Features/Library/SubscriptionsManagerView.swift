import NoSlopKit
import SwiftUI

/// Every channel the feed is built from, with where the subscription lives ("YouTube" for the Google account,
/// "Local" for this device). A row opens the channel; swipe to unsubscribe; pull down to re-sync the account.
struct SubscriptionsManagerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    /// Channels whose unsubscribe is in flight, so a second swipe cannot flip them back to subscribed.
    @State private var unsubscribing: Set<String> = []
    @State private var failureMessage: String?

    var body: some View {
        let all = env.library.subscriptions
        let shown = filtered(all)

        Group {
            if all.isEmpty {
                EmptyStateView(
                    title: "No subscriptions",
                    systemImage: "person.2",
                    message: "Subscribe to channels to see their uploads in the Subscriptions tab."
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    Section {
                        ForEach(shown) { channel in
                            row(for: channel)
                        }
                    } header: {
                        Text(all.count == 1 ? "1 channel" : "\(all.count) channels")
                    } footer: {
                        Text("Swipe a channel to unsubscribe. YouTube subscriptions are changed on your account as well.")
                    }
                }
                .refreshable { await env.refreshAccount() }
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        // Always visible, so the filter can be found without pulling the list down.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search subscriptions")
        .alert(
            "Couldn't unsubscribe",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failureMessage ?? "")
        }
    }

    // MARK: Rows

    private func row(for channel: SubscribedChannel) -> some View {
        // Next to the name, the badge leaves it a few letters at accessibility text sizes. There the name wraps over the
        // width that is left of the avatar and the badge goes under it.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let name = Text(channel.name.isEmpty ? channel.id : channel.name)
            .font(.body)
            .foregroundStyle(.primary)

        return Button {
            env.show(.channel(id: channel.id))
        } label: {
            HStack(spacing: 12) {
                ChannelAvatarView(url: channel.avatarURL, size: 44)
                if stacked {
                    VStack(alignment: .leading, spacing: 6) {
                        name.lineLimit(3)
                        trailing(for: channel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    name.lineLimit(1)
                    Spacer(minLength: 8)
                    trailing(for: channel)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                unsubscribe(channel)
            } label: {
                Label("Unsubscribe", systemImage: "person.badge.minus")
            }
        }
    }

    /// A spinner while the unsubscribe runs, else where the subscription lives.
    @ViewBuilder
    private func trailing(for channel: SubscribedChannel) -> some View {
        if unsubscribing.contains(channel.id) {
            ProgressView()
        } else {
            SourceBadge(source: channel.source)
        }
    }

    private func filtered(_ channels: [SubscribedChannel]) -> [SubscribedChannel] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = text.isEmpty ? channels : channels.filter {
            $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return matching.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func unsubscribe(_ channel: SubscribedChannel) {
        // The row may be stale (a sync removed it meanwhile); toggling then would subscribe instead.
        guard env.isSubscribed(channel.id), !unsubscribing.contains(channel.id) else { return }
        unsubscribing.insert(channel.id)
        Task {
            defer { unsubscribing.remove(channel.id) }
            do {
                try await env.toggleSubscription(channel.ref)
            } catch is CancellationError {
                // The screen went away.
            } catch NoSlopError.cancelled {
                // Same, as reported by the kit.
            } catch {
                failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// "YouTube" (the subscription is on the Google account) or "Local" (kept on this device).
private struct SourceBadge: View {
    let source: SubscriptionSource

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isGoogle ? Theme.accent : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (isGoogle ? Theme.accent.opacity(0.14) : Color(.tertiarySystemFill)),
                in: Capsule()
            )
    }

    private var isGoogle: Bool {
        if case .google = source { return true }
        return false
    }

    private var title: String {
        isGoogle ? "YouTube" : "Local"
    }
}

#Preview {
    NavigationStack {
        SubscriptionsManagerView()
    }
    .environment(AppEnvironment.preview())
}

#Preview("Accessibility text size") {
    let env = AppEnvironment.preview()
    env.library.subscribe(SubscribedChannel(id: "UC1", name: "Blender Guru", source: .google(subscriptionID: "sub-1")))
    env.library.subscribe(SubscribedChannel(id: "UC2", name: "A channel with a rather long name", source: .local))
    return NavigationStack {
        SubscriptionsManagerView()
    }
    .environment(env)
    .dynamicTypeSize(.accessibility2)
}
