import SwiftUI

/// A list row that opens a web address outside the app: the title and a small arrow at the trailing edge.
struct ExternalLinkRow: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                ExternalLinkArrow()
            }
        }
    }
}

/// The small up-right arrow that marks a row as leaving the app.
struct ExternalLinkArrow: View {
    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
