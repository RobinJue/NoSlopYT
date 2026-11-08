import SwiftUI

/// The legal notice: what the app is and is not, how it reaches YouTube, what happens to your data, and what it builds
/// on. The wording follows the README's "Credits and disclaimer", so the two say the same.
struct LegalNoticeView: View {
    var body: some View {
        List {
            notice("About this app", [
                "No Slop is a personal, non-commercial project, made for the author's own use. Its source code is in the repository linked at the bottom of this page.",
            ])

            notice("YouTube and Google", [
                "No Slop is not affiliated with, endorsed by or sponsored by YouTube, Google or Alphabet. YouTube and Google are trademarks of Google LLC, and other names belong to their owners. They appear here only to say what the app works with.",
            ])

            notice("Unofficial access", [
                "No Slop reaches YouTube through the same web interfaces the YouTube website uses, not through an official API, and it plays videos without ads. That may go against YouTube's Terms of Service, and YouTube can change or block it at any time. If you use it, you do so at your own risk, and you are responsible for following the terms that apply to you.",
                "Only the optional Google sign-in uses an official API (the YouTube Data API, with your own Google project). The optional YouTube recommendations connection is not official: it presents itself to YouTube as YouTube's TV app, which is also against YouTube's terms, and may get the account restricted.",
            ])

            notice("Videos and downloads", [
                "No Slop hosts no videos. Videos, titles, thumbnails, channel names and comments belong to YouTube and the people who made them. Downloads are for your own offline use on this device. Do not share or redistribute them, and follow the copyright law that applies to you.",
            ])

            notice("No warranty", [
                "No Slop is provided as it is, without any warranty. As far as the law allows, the author is not liable for damage that comes from using it, including a limit or closure of your Google or YouTube account.",
            ])

            notice("Your data", [
                "No Slop has no account of its own and contains no analytics, crash reporter, tracker or third-party package. Your subscriptions, history, playlists, downloads and settings stay on this device.",
                "The app talks to YouTube and Google, and to SponsorBlock and DeArrow, which are asked about a short hash of a video ID, never the ID itself. If you connect YouTube recommendations, YouTube sees what you hide and, unless you switch it off in Settings, what you watch.",
            ])

            Section {
                Text("SponsorBlock (skip segments) and DeArrow (better titles) are by Ajay Ramachandran and their communities. Their data is licensed CC BY-NC-SA 4.0.")
                ExternalLinkRow(title: "SponsorBlock", destination: ProjectLinks.sponsorBlock)
                ExternalLinkRow(title: "DeArrow", destination: ProjectLinks.deArrow)
                ExternalLinkRow(title: "CC BY-NC-SA 4.0", destination: ProjectLinks.dataLicense)
            } header: {
                Text("Credits")
            }

            Section {
                ExternalLinkRow(title: "Repository", destination: ProjectLinks.repository)
                ExternalLinkRow(title: "Report a problem", destination: ProjectLinks.issues)
            } header: {
                Text("Source code and contact")
            }
        }
        .headerProminence(.increased)
        // On an iPad the paragraphs would run across the whole screen: a reading column in the middle instead.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .miniPlayerClearance()
        .navigationTitle("Legal notice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func notice(_ title: String, _ paragraphs: [String]) -> some View {
        Section {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
            }
        } header: {
            Text(title)
        }
    }
}

#Preview {
    NavigationStack {
        LegalNoticeView()
    }
    .environment(AppEnvironment.preview())
}
