import SwiftUI

/// How a video card sits in its column; `FeedGrid` sets it and `VideoCardView` and `SearchItemRow` read it.
enum VideoCardLayout: Sendable {
    /// One column on a phone in portrait: thumbnails run edge to edge, the text is inset (as in the YouTube app).
    case edgeToEdge
    /// One of several columns (iPad, phone in landscape): the card is inset as a whole and its thumbnail is rounded.
    case inset
}

extension EnvironmentValues {
    @Entry var videoCardLayout: VideoCardLayout = .edgeToEdge
}

/// A vertical feed of cards that uses the width it is given: a single edge-to-edge column when the screen is
/// phone-sized, several columns of rounded cards when there is room. Lazy, so long feeds stay cheap.
///
///     ScrollView { FeedGrid { ForEach(videos) { VideoCardView(video: $0) } } }
struct FeedGrid<Content: View>: View {
    private let content: Content

    /// nil until the first layout pass has measured the width; one column until then.
    @State private var availableWidth: CGFloat?

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let count = Self.columnCount(forWidth: availableWidth)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top), count: count),
            spacing: Theme.feedSpacing
        ) {
            content
        }
        .padding(.horizontal, count > 1 ? Theme.padding : 0)
        .environment(\.videoCardLayout, count > 1 ? .inset : .edgeToEdge)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if availableWidth != width { availableWidth = width }
        }
    }

    private static var columnSpacing: CGFloat { 16 }

    /// How many columns of at least `Theme.feedColumnMinimumWidth` fit next to each other (with outer padding).
    static func columnCount(forWidth width: CGFloat?) -> Int {
        guard let width, width.isFinite else { return 1 }
        let usable = width - 2 * Theme.padding
        let count = Int(((usable + columnSpacing) / (Theme.feedColumnMinimumWidth + columnSpacing)).rounded(.down))
        return min(4, max(1, count))
    }
}

/// A press effect for a tappable card or row: it dims while the finger is down, without the tint a plain `Button`
/// would give its label.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableCardStyle {
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
}

extension View {
    /// Leaves room under a scrolling screen for the mini player while it is showing, so the last row can be scrolled
    /// clear of it.
    func miniPlayerClearance() -> some View {
        modifier(MiniPlayerClearance())
    }
}

private struct MiniPlayerClearance: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        let inset = env.player.presentation == .minimized ? Theme.miniPlayerInset : 0
        content
            .contentMargins(.bottom, inset, for: .scrollContent)
            .animation(.snappy, value: inset)
    }
}
