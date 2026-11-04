import NoSlopKit
import SwiftUI

/// The question asked before downloaded data is thrown away: deleting a download, and cancelling one that is running or
/// waiting (which discards what it has fetched). It is worded the same on the Downloads screen and in the quality sheet.
struct DownloadRemoval: Identifiable {
    enum Kind {
        case delete
        case cancel
    }

    let kind: Kind
    let item: DownloadItem

    var id: String { "\(kind)-\(item.id)" }

    var title: String {
        switch kind {
        case .delete: "Delete this download?"
        case .cancel: "Cancel this download?"
        }
    }

    var message: String {
        switch (kind, item.state) {
        case (.delete, .completed): "You can download the video again later."
        case (.cancel, .merging): "The video is downloaded and is being finished. Cancelling discards it."
        default: "The partial download is discarded."
        }
    }

    /// The destructive button.
    var confirmTitle: String {
        switch kind {
        case .delete: "Delete"
        case .cancel: "Cancel Download"
        }
    }

    /// The button that leaves everything as it is. (Not "Cancel" when the question is about cancelling.)
    var dismissTitle: String {
        switch kind {
        case .delete: "Cancel"
        case .cancel: "Keep Downloading"
        }
    }

    func perform(on downloads: DownloadManager) {
        switch kind {
        case .delete: downloads.delete(id: item.id)
        case .cancel: downloads.cancel(id: item.id)
        }
    }
}

extension View {
    /// Asks the question of `removal` while it is set, and carries it out when the person confirms. An alert, shown from
    /// the view it is attached to: attach it to a list, not to a row (a swipe action closes its row, and a dialog
    /// attached to that row would be lost with it).
    func confirmingDownloadRemoval(_ removal: Binding<DownloadRemoval?>) -> some View {
        modifier(DownloadRemovalAlert(removal: removal))
    }
}

private struct DownloadRemovalAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var removal: DownloadRemoval?

    func body(content: Content) -> some View {
        content.alert(
            removal?.title ?? "",
            isPresented: Binding(
                get: { removal != nil },
                set: { if !$0 { removal = nil } }
            ),
            presenting: removal
        ) { removal in
            Button(removal.confirmTitle, role: .destructive) {
                removal.perform(on: env.downloads)
            }
            Button(removal.dismissTitle, role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
    }
}
