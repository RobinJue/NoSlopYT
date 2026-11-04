import MediaAccessibility
import NoSlopKit
import Observation
import SwiftUI
import UIKit

/// The caption style the viewer chose in Settings > Accessibility > Subtitles & Captioning, as far as apps are meant
/// to follow it.
///
/// The system hands out every part of the style with a behaviour: `useValue` (the viewer chose this; it overrides what
/// an app would do) or `useContentIfAvailable` (the content's own styling wins, and the value is only a default). The
/// captions here are plain text without any styling of their own, so a part that the system leaves to the content
/// stays what the app has always drawn (white medium system text on 70 % black, usual size): a viewer who never touched
/// the setting sees no change. Such a part is nil here.
struct CaptionAppearance: Equatable {
    /// How the edge of the letters is drawn.
    enum Edge: Equatable {
        case none, raised, depressed, uniform, dropShadow
    }

    /// The relative character size (the system offers 0.5 to 2); nil keeps the usual size.
    var relativeSize: Double?
    /// The colour of the letters, opacity included; nil keeps white.
    var textColor: UIColor?
    /// The box behind the lines, opacity included; nil keeps black at 70 %.
    var backgroundColor: UIColor?
    /// A box behind all the lines together, opacity included; nil has none.
    var windowColor: UIColor?
    var edge: Edge = .none
    /// The font family of the style; nil keeps the system font (medium).
    var fontDescriptor: UIFontDescriptor?

    /// The look captions have without any style of the viewer's.
    static let standard = CaptionAppearance()

    /// The font at `size` points: the viewer's, or the usual system font. `CaptionOverlayView` draws it, and measures
    /// the height of the captions with it.
    func font(ofSize size: CGFloat) -> UIFont {
        if let fontDescriptor {
            // The system's own fonts have private names (".SFUI-Medium") that cannot be looked up: UIKit hands back
            // Times for them. A font the device does not have comes back as some other font as well. Either way the
            // system font is the better choice.
            let name = fontDescriptor.postscriptName
            if !name.hasPrefix(".") {
                let font = UIFont(descriptor: fontDescriptor, size: size)
                let family = fontDescriptor.object(forKey: .family) as? String
                if font.fontName == name || (family != nil && font.familyName == family) { return font }
            }
        }
        return .systemFont(ofSize: size, weight: .medium)
    }

    /// What the system says now: the viewer's own style (the `.user` domain).
    static func current() -> CaptionAppearance {
        #if DEBUG
        if let forced = forcedByLaunchArgument() { return forced }
        #endif

        // Every call reports its own behaviour; a part that is not `useValue` reads as nil.
        func value<T>(_ read: (UnsafeMutablePointer<MACaptionAppearanceBehavior>) -> T) -> T? {
            var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
            let result = read(&behavior)
            return behavior == .useValue ? result : nil
        }

        let size = value { MACaptionAppearanceGetRelativeCharacterSize(.user, $0) }
        let text = value { MACaptionAppearanceCopyForegroundColor(.user, $0).takeRetainedValue() }
        let textOpacity = value { MACaptionAppearanceGetForegroundOpacity(.user, $0) }
        let background = value { MACaptionAppearanceCopyBackgroundColor(.user, $0).takeRetainedValue() }
        let backgroundOpacity = value { MACaptionAppearanceGetBackgroundOpacity(.user, $0) }
        let window = value { MACaptionAppearanceCopyWindowColor(.user, $0).takeRetainedValue() }
        let windowOpacity = value { MACaptionAppearanceGetWindowOpacity(.user, $0) }
        let edge = value { MACaptionAppearanceGetTextEdgeStyle(.user, $0) }
        let font = value { MACaptionAppearanceCopyFontDescriptorForStyle(.user, $0, .default).takeRetainedValue() }

        return CaptionAppearance(
            relativeSize: size.map(Double.init),
            textColor: tinted(text, opacity: textOpacity, fallback: .white, defaultOpacity: 1),
            backgroundColor: tinted(background, opacity: backgroundOpacity, fallback: .black, defaultOpacity: 0.7),
            // A window the viewer has not given an opacity is no window.
            windowColor: windowOpacity.flatMap { opacity in
                opacity > 0 ? tinted(window, opacity: opacity, fallback: .black, defaultOpacity: 1) : nil
            },
            edge: edge.map(Self.edge(for:)) ?? .none,
            fontDescriptor: font.flatMap(Self.uiDescriptor(for:))
        )
    }

    /// `color` (or `fallback`) with `opacity` (or `defaultOpacity`); nil when the system has neither.
    private static func tinted(_ color: CGColor?, opacity: CGFloat?, fallback: UIColor, defaultOpacity: CGFloat) -> UIColor? {
        guard color != nil || opacity != nil else { return nil }
        let base = color.map(UIColor.init(cgColor:)) ?? fallback
        return base.withAlphaComponent(min(max(opacity ?? defaultOpacity, 0), 1))
    }

    private static func edge(for style: MACaptionAppearanceTextEdgeStyle) -> Edge {
        switch style {
        case .raised: .raised
        case .depressed: .depressed
        case .uniform: .uniform
        case .dropShadow: .dropShadow
        case .undefined, .none: .none
        @unknown default: .none
        }
    }

    private static func uiDescriptor(for descriptor: CTFontDescriptor) -> UIFontDescriptor? {
        guard let attributes = CTFontDescriptorCopyAttributes(descriptor) as? [UIFontDescriptor.AttributeName: Any] else { return nil }
        return UIFontDescriptor(fontAttributes: attributes)
    }
}

/// The caption style as it is now, kept up to date: the viewer can change it in Settings while the app runs, and the
/// captions on screen follow at once (views that read `appearance` in their `body` are redrawn).
@MainActor
@Observable
final class CaptionAppearanceStore {
    static let shared = CaptionAppearanceStore()

    private(set) var appearance: CaptionAppearance

    private init() {
        appearance = CaptionAppearance.current()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(),
            nil,
            captionAppearanceSettingsChanged,
            kMACaptionAppearanceSettingsChangedNotification,
            nil,
            .deliverImmediately
        )
    }

    /// Reads the style again.
    func reload() {
        let latest = CaptionAppearance.current()
        if latest != appearance { appearance = latest }
    }
}

/// The system's "caption settings changed" notification arrives on a C callback, off the main actor.
private nonisolated func captionAppearanceSettingsChanged(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    Task { @MainActor in
        CaptionAppearanceStore.shared.reload()
    }
}

/// What the caption views draw with: the viewer's caption style, and the viewer's text size.
struct CaptionStyle: Equatable {
    var appearance = CaptionAppearance.standard
    /// The viewer's text size against the default one (1 at Large); see `dynamicTypeScale(for:)`.
    var dynamicTypeScale = 1.0

    /// The padding of the box that surrounds all the lines, when the style has one.
    private static let windowPadding: CGFloat = 4

    /// The factor for the usual sizes (`CaptionScale`).
    var scale: Double {
        CaptionScale.scale(systemRelativeSize: appearance.relativeSize, dynamicTypeScale: dynamicTypeScale)
    }

    /// The font of captions of `size`: the usual size times `scale`.
    func font(_ size: CaptionOverlayView.Size, isLarge: Bool) -> UIFont {
        let points = CaptionScale.fontSize(size == .regular ? .regular : .compact, isLarge: isLarge, scale: scale)
        return appearance.font(ofSize: CGFloat(points))
    }

    /// Room the window takes around the lines on every side.
    var windowInset: CGFloat {
        appearance.windowColor == nil ? 0 : Self.windowPadding
    }

    /// The viewer's text size as a factor of the default one: 1 at Large, about 1.35 at xxxLarge, 3.1 at the largest
    /// accessibility size (`CaptionScale` keeps what it makes of that within bounds).
    static func dynamicTypeScale(for size: DynamicTypeSize) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17)
    }
}

#if DEBUG
extension CaptionAppearance {
    /// `-captionStyle '<parts>'` (simulator checks, where Settings cannot be changed by a script): a caption style as if
    /// the viewer had chosen it. Parts are separated by `;`: `size=<0.5...2>`, `text=<colour>`, `background=<colour>`,
    /// `window=<colour>`, `edge=<none|raised|depressed|uniform|shadow>`, `font=<family name>`. A colour is a name
    /// (white, black, yellow, red, green, blue, cyan, clear) with an optional opacity: `yellow@0.8`.
    fileprivate static func forcedByLaunchArgument() -> CaptionAppearance? {
        guard let argument = UserDefaults.standard.string(forKey: "captionStyle"), !argument.isEmpty else { return nil }
        var appearance = CaptionAppearance()
        for part in argument.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { continue }
            switch pieces[0] {
            case "size": appearance.relativeSize = Double(pieces[1])
            case "text": appearance.textColor = color(pieces[1])
            case "background": appearance.backgroundColor = color(pieces[1])
            case "window": appearance.windowColor = color(pieces[1])
            case "edge":
                let edges: [String: Edge] = ["none": .none, "raised": .raised, "depressed": .depressed, "uniform": .uniform, "shadow": .dropShadow]
                appearance.edge = edges[pieces[1]] ?? .none
            case "font": appearance.fontDescriptor = UIFontDescriptor(fontAttributes: [.family: pieces[1]])
            default: break
            }
        }
        return appearance
    }

    private static func color(_ text: String) -> UIColor? {
        let pieces = text.split(separator: "@", maxSplits: 1).map(String.init)
        let colors: [String: UIColor] = [
            "white": .white, "black": .black, "yellow": .yellow, "red": .red, "green": .green, "blue": .blue,
            "cyan": .cyan, "clear": .clear,
        ]
        guard let base = colors[pieces[0]] else { return nil }
        return pieces.count > 1 ? Double(pieces[1]).map { base.withAlphaComponent($0) } : base
    }
}
#endif
