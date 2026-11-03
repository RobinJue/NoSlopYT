import NoSlopKit
import SwiftUI

/// Feed filters: what Home, Subscriptions, search results and suggestions leave out.
struct FeedFilterSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settingsStore

        Section {
            Toggle("Hide Shorts", isOn: $store.settings.hideShorts)
            Toggle("Hide members-only videos", isOn: $store.settings.hideMembersOnly)
            Toggle("Hide live and upcoming", isOn: $store.settings.hideLiveAndUpcoming)
            Toggle("Hide watched in Subscriptions", isOn: $store.settings.hideWatchedInSubscriptions)

            NavigationLink {
                BlockedChannelsView()
            } label: {
                LabeledContent("Blocked channels", value: countText(store.settings.blockedChannels.count))
            }
            NavigationLink {
                BlockedKeywordsView()
            } label: {
                LabeledContent("Blocked keywords", value: countText(store.settings.blockedKeywords.count))
            }
        } header: {
            Text("Feed filters")
        } footer: {
            Text("Applies to Home, Subscriptions, search results and suggested videos.")
        }
    }

    private func countText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }
}

/// The channels hidden with "Don't show this channel". Swipe a row to unblock it.
struct BlockedChannelsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let channels = env.settings.blockedChannels

        Group {
            if channels.isEmpty {
                EmptyStateView(
                    title: "No blocked channels",
                    systemImage: "nosign",
                    message: "Choose \u{201C}Don't show this channel\u{201D} in a video's menu to hide a channel everywhere."
                )
            } else {
                List {
                    Section {
                        ForEach(channels) { channel in
                            Text(channel.name.isEmpty ? channel.id : channel.name)
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        unblock(channel)
                                    } label: {
                                        Label("Unblock", systemImage: "checkmark.circle")
                                    }
                                    .tint(Theme.accent)
                                }
                        }
                    } footer: {
                        Text("Swipe a channel to show it again.")
                    }
                }
            }
        }
        .navigationTitle("Blocked channels")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unblock(_ channel: BlockedChannel) {
        env.settingsStore.settings.blockedChannels.removeAll { $0.id == channel.id }
    }
}

/// Words and phrases that hide a video when its title contains them (case and accents are ignored).
struct BlockedKeywordsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft = ""

    var body: some View {
        let keywords = env.settings.blockedKeywords

        List {
            Section {
                HStack(spacing: 12) {
                    TextField("Add a word or phrase", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(addDraft)
                    Button("Add", action: addDraft)
                        .buttonStyle(.borderless)
                        .disabled(trimmedDraft.isEmpty)
                }
            } footer: {
                Text("Videos whose title contains one of these words or phrases are hidden.")
            }

            if !keywords.isEmpty {
                Section("Blocked") {
                    ForEach(Array(keywords.enumerated()), id: \.offset) { _, keyword in
                        Text(keyword)
                    }
                    .onDelete { offsets in
                        env.settingsStore.settings.blockedKeywords.remove(atOffsets: offsets)
                    }
                }
            }
        }
        .navigationTitle("Blocked keywords")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addDraft() {
        let keyword = trimmedDraft
        guard !keyword.isEmpty else { return }
        let alreadyBlocked = env.settings.blockedKeywords.contains {
            $0.compare(keyword, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !alreadyBlocked {
            env.settingsStore.settings.blockedKeywords.append(keyword)
        }
        draft = ""
    }
}
