import NoSlopKit
import SwiftUI

/// All preferences, bound straight to `env.settingsStore.settings` (the store saves every change).
///
/// Sections follow the spec: Playback, SponsorBlock, De-clickbait titles, Feed filters, Account, Storage, About.
/// Each section is a view of its own so a change in one never re-evaluates the others.
struct SettingsView: View {
    var body: some View {
        Form {
            PlaybackSettingsSection()
            SponsorBlockSettingsSection()
            TitleSettingsSection()
            FeedFilterSettingsSection()
            AccountSettingsSection()
            StorageSettingsSection()
            AboutSettingsSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Playback

private struct PlaybackSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    /// The speeds the player offers.
    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        @Bindable var store = env.settingsStore

        Section {
            Picker("Quality on Wi-Fi", selection: $store.settings.wifiQuality) {
                ForEach(QualityPreference.allCases, id: \.self) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            Picker("Quality on cellular", selection: $store.settings.cellularQuality) {
                ForEach(QualityPreference.allCases, id: \.self) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            Picker("Default speed", selection: $store.settings.defaultPlaybackRate) {
                ForEach(speedOptions(including: store.settings.defaultPlaybackRate), id: \.self) { speed in
                    Text(Self.label(forSpeed: speed)).tag(speed)
                }
            }
            Toggle("Autoplay next video", isOn: $store.settings.autoplayNext)
            Toggle("Background playback", isOn: $store.settings.backgroundPlayback)
            Toggle("Picture in Picture automatically", isOn: $store.settings.autoPictureInPicture)
        } header: {
            Text("Playback")
        } footer: {
            Text("Auto picks the best quality your connection can keep up with. Background playback keeps the sound going when you leave the app or lock the screen; Picture in Picture starts by itself when you leave the app during a video.")
        }
    }

    /// The standard speeds, plus the saved one when an older build or a hand-edited file left a different value.
    private func speedOptions(including saved: Double) -> [Double] {
        Self.speeds.contains(saved) ? Self.speeds : (Self.speeds + [saved]).sorted()
    }

    private static func label(forSpeed speed: Double) -> String {
        if speed == 1 { return "Normal" }
        return speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// MARK: - Titles

private struct TitleSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settingsStore

        Section {
            Toggle("De-clickbait titles", isOn: $store.settings.deArrowTitles)
        } header: {
            Text("Titles")
        } footer: {
            Text("Swaps a clickbait title for the plain one written by the DeArrow community, when there is one. Lookups send only a short hash of the video ID.")
        }
    }
}

// MARK: - About

private struct AboutSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: versionText)
            creditLink("SponsorBlock by Ajay Ramachandran", "https://sponsor.ajay.app/")
            creditLink("DeArrow by Ajay Ramachandran", "https://dearrow.ajay.app/")
            creditLink("Data license: CC BY-NC-SA 4.0", "https://creativecommons.org/licenses/by-nc-sa/4.0/")
        } header: {
            Text("About")
        } footer: {
            Text("Sponsor segments and better titles come from the SponsorBlock and DeArrow databases, made by their communities.\n\nNo Slop is a personal project. It is not affiliated with, endorsed by or sponsored by YouTube or Google.")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private func creditLink(_ title: String, _ address: String) -> some View {
        if let url = URL(string: address) {
            Link(destination: url) {
                HStack {
                    Text(title)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppEnvironment.preview())
}
