import SwiftUI

/// A label whose icon sits right next to its title, in the surrounding foreground style.
///
/// Inside a `List` or `Form` the standard label style reserves a wide icon column and tints the icon with the
/// accent colour, which leaves a gap in a small "icon text" caption and makes the icon of an accent-filled button
/// invisible. This style does neither. Use it as `.labelStyle(.tight)`.
struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == TightLabelStyle {
    static var tight: TightLabelStyle { TightLabelStyle() }
}
