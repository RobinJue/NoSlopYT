import NoSlopKit
import SwiftUI

/// Feed filters: what Home, Subscriptions, search results, channels, playlists, suggestions and the liked videos and
/// YouTube playlists of the account leave out.
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
            // The two filters that need YouTube's own marks cannot work on the uploads that come from channel feeds
            // (RSS): those carry no members-only, live or upcoming mark.
            Text("Applies to Home, Subscriptions, search results, channels, playlists, suggested videos and your liked videos. History, Watch Later, your own playlists and downloads show everything you put there.\n\nMembers-only and live or upcoming videos are hidden only where YouTube marks them, such as in search, on channel pages and in suggestions. The Subscriptions tab and the subscription uploads on Home come from the channels\u{2019} feeds, which carry no such marks.")
        }
    }

    private func countText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }
}

/// The channels hidden with "Don't show this channel". Swipe a row to unblock it, or choose "Show this channel again"
/// in the menu of one of its videos.
struct BlockedChannelsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let channels = env.settings.blockedChannels

        Group {
            if channels.isEmpty {
                EmptyStateView(
                    title: "No blocked channels",
                    systemImage: "nosign",
                    message: "Choose \u{201C}Don't show this channel\u{201D} in a video's menu to hide a channel from your feeds, searches and playlists."
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
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Blocked channels")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unblock(_ channel: BlockedChannel) {
        ChannelBlocking.unblock(channelID: channel.id, using: env)
    }
}

/// Words and phrases that hide a video when its title contains them (case and accents are ignored). A short word of
/// up to three letters or digits only counts as a whole word (`ContentFilter`).
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
                Text("Videos whose title contains one of these words or phrases are hidden; case and accents don\u{2019}t matter. Words of up to three letters or digits, such as \u{201C}AI\u{201D}, only match whole words. Longer words and phrases also match inside other words.")
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
        .miniPlayerClearance()
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
