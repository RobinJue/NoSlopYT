import NoSlopKit
import SwiftUI

/// "Save to playlist": the playlists on this device (tap to add the video or take it out again), a way to create a
/// new one, and, when signed in, the playlists of the YouTube account (tap to add the video to that playlist).
struct AddToPlaylistSheet: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum RemoteState {
        case idle
        case loading
        case loaded([PlaylistSummary])
        case failed(Error)
    }

    @State private var remote: RemoteState = .idle
    /// YouTube playlists the video is known to be in: where it was added from this sheet, or where a tap found it
    /// already. The sheet does not look into every playlist when it opens (a request each), but adding does, and
    /// adds nothing to a playlist that holds the video: a row tapped again later just turns to a checkmark.
    @State private var addedRemote: Set<String> = []
    @State private var addingRemote: Set<String> = []
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newTitle = ""
                        isCreating = true
                    } label: {
                        Label("New playlist", systemImage: "plus")
                    }
                }

                if !env.library.playlists.isEmpty {
                    Section("On this device") {
                        ForEach(env.library.playlists) { playlist in
                            localRow(playlist)
                        }
                    }
                }

                if env.googleAccount != nil {
                    remoteSection
                }
            }
            .navigationTitle("Save to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New playlist", isPresented: $isCreating) {
                TextField("Title", text: $newTitle)
                Button("Create") {
                    let playlist = env.library.createPlaylist(title: newTitle)
                    env.library.add(video, toPlaylist: playlist.id)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Couldn't add the video",
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
        .presentationDetents([.medium, .large])
        .task(id: env.googleAccount?.id) { await loadRemotePlaylists() }
    }

    // MARK: This device

    private func localRow(_ playlist: LocalPlaylist) -> some View {
        let contains = playlist.videos.contains { $0.id == video.id }
        return Button {
            if contains {
                env.library.remove(videoID: video.id, fromPlaylist: playlist.id)
            } else {
                env.library.add(video, toPlaylist: playlist.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .foregroundStyle(.primary)
                    Text(playlist.videos.count == 1 ? "1 video" : "\(playlist.videos.count) videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: contains ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(contains ? Theme.accent : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playlist.title)
        .accessibilityValue(contains ? "Contains this video" : "Does not contain this video")
    }

    // MARK: YouTube account

    @ViewBuilder
    private var remoteSection: some View {
        Section {
            switch remote {
            case .idle, .loading:
                HStack {
                    ProgressView()
                    Text("Loading your YouTube playlists")
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                VStack(alignment: .leading, spacing: 8) {
                    Text((error as? LocalizedError)?.errorDescription ?? "Couldn't load your YouTube playlists.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadRemotePlaylists() }
                    }
                    .buttonStyle(.borderless)
                }
            case .loaded(let playlists):
                if playlists.isEmpty {
                    Text("You have no playlists on YouTube yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlists) { playlist in
                        remoteRow(playlist)
                    }
                }
            }
        } header: {
            Text("On YouTube")
        } footer: {
            Text("Adds the video to the playlist on your YouTube account.")
        }
    }

    private func remoteRow(_ playlist: PlaylistSummary) -> some View {
        let isAdded = addedRemote.contains(playlist.id)
        let isAdding = addingRemote.contains(playlist.id)
        return Button {
            Task { await addToRemote(playlist) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .foregroundStyle(.primary)
                    if let count = playlist.videoCountText ?? playlist.videoCount.map({ $0 == 1 ? "1 video" : "\($0) videos" }) {
                        Text(count)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isAdding {
                    ProgressView()
                } else {
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isAdded ? Theme.accent : Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded || isAdding)
        .accessibilityLabel(playlist.title)
        .accessibilityValue(isAdded ? "Added" : "")
    }

    private func loadRemotePlaylists() async {
        guard env.googleAccount != nil else {
            remote = .idle
            return
        }
        remote = .loading
        do {
            let playlists = try await env.viaAccount { try await $0.myPlaylists() }
            guard !Task.isCancelled else { return }
            remote = .loaded(playlists)
        } catch {
            guard !Task.isCancelled else { return }
            remote = .failed(error)
        }
    }

    private func addToRemote(_ playlist: PlaylistSummary) async {
        guard !addingRemote.contains(playlist.id), !addedRemote.contains(playlist.id) else { return }
        addingRemote.insert(playlist.id)
        defer { addingRemote.remove(playlist.id) }
        do {
            try await env.viaAccount { try await $0.addToPlaylist(videoID: video.id, playlistID: playlist.id) }
            addedRemote.insert(playlist.id)
        } catch {
            failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
