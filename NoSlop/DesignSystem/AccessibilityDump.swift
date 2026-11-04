#if DEBUG
import OSLog
import UIKit

/// `-axDump '<seconds>,<seconds>...'`: that long after launch, writes what VoiceOver would walk through, in the order it
/// would visit it, to `<Documents>/ax-<seconds>.txt` (and to the log, category `ax`). For simulator checks of the
/// accessibility tree, where VoiceOver itself cannot run: which elements exist, what they say, and which ones a
/// `.accessibilityHidden` or a modal panel has taken out. Needs the accessibility machinery of the simulator on, once:
///
///     xcrun simctl spawn <udid> defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
///
/// The walk follows UIKit's rules: a view that is `accessibilityElementsHidden` (or hidden) takes its whole subtree
/// out, an accessibility element is a leaf, a container hands out its `accessibilityElements`, and any other view is
/// walked through its subviews. A view that is `accessibilityViewIsModal` is marked, so that the elements after it can
/// be told from the ones it shields. Compiled out of Release builds.
@MainActor
enum AccessibilityDump {
    private static var isStarted = false
    private static let log = Logger(subsystem: "com.robinjungerich.noslopyt", category: "ax")

    static func runIfRequested() {
        guard !isStarted, let argument = UserDefaults.standard.string(forKey: "axDump"), !argument.isEmpty else { return }
        isStarted = true
        let times = argument.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        Task { @MainActor in
            var waited = 0.0
            for time in times {
                try? await Task.sleep(for: .seconds(max(0, time - waited)))
                waited = time
                write(tag: String(format: "%g", time))
            }
        }
    }

    /// Writes the dump of this moment to `<Documents>/ax-<tag>.txt`.
    static func write(tag: String) {
        var lines: [String] = []
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) where !window.isHidden {
            lines.append("window \(type(of: window)) level=\(window.windowLevel.rawValue)")
            walk(window, depth: 1, into: &lines)
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: documents.appendingPathComponent("ax-\(tag).txt"), atomically: true, encoding: .utf8)
        }
        log.info("[ax] dump \(tag, privacy: .public): \(lines.count) lines")
    }

    /// The two-finger scrub (escape) of VoiceOver, with the focus on the element labelled `label`: asks that element
    /// and then every container above it to `accessibilityPerformEscape`, until one handles it. True when one did.
    static func performEscape(startingAtLabel label: String) -> Bool {
        var found: NSObject?
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) where !window.isHidden && found == nil {
            find(label: label, in: window, found: &found)
        }
        var current = found
        while let object = current {
            if object.accessibilityPerformEscape() {
                log.info("[ax] escape handled by \(String(describing: type(of: object)), privacy: .public)")
                return true
            }
            current = container(of: object)
        }
        log.info("[ax] escape not handled (started at \(found == nil ? "nothing" : label, privacy: .public))")
        return false
    }

    /// The container of an accessibility element (SwiftUI's nodes keep it where UIKit's elements do), or the superview.
    private static func container(of object: NSObject) -> NSObject? {
        let selector = NSSelectorFromString("accessibilityContainer")
        if object.responds(to: selector), let container = object.perform(selector)?.takeUnretainedValue() as? NSObject {
            return container
        }
        return (object as? UIView)?.superview
    }

    private static func find(label: String, in object: NSObject, found: inout NSObject?) {
        guard found == nil else { return }
        if let view = object as? UIView, view.accessibilityElementsHidden || view.isHidden || view.alpha < 0.01 { return }
        if object.isAccessibilityElement {
            if object.accessibilityLabel == label { found = object }
            return
        }
        if let children = object.accessibilityElements, !children.isEmpty {
            for case let child as NSObject in children { find(label: label, in: child, found: &found) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject { find(label: label, in: child, found: &found) }
            }
            return
        }
        if let view = object as? UIView {
            for subview in view.subviews { find(label: label, in: subview, found: &found) }
        }
    }

    private static func walk(_ object: NSObject, depth: Int, into lines: inout [String]) {
        if let view = object as? UIView, view.accessibilityElementsHidden || view.isHidden || view.alpha < 0.01 { return }
        if object.accessibilityViewIsModal {
            lines.append(indent(depth) + "-- modal: \(type(of: object)) --")
        }
        if object.isAccessibilityElement {
            lines.append(indent(depth) + describe(object))
            return
        }
        if let children = object.accessibilityElements, !children.isEmpty {
            for case let child as NSObject in children { walk(child, depth: depth + 1, into: &lines) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject { walk(child, depth: depth + 1, into: &lines) }
            }
            return
        }
        if let view = object as? UIView {
            for subview in view.subviews { walk(subview, depth: depth + 1, into: &lines) }
        }
    }

    private static func describe(_ object: NSObject) -> String {
        let label = object.accessibilityLabel.map { "\"\($0)\"" } ?? "nil"
        var text = "[\(type(of: object))] label=\(label)"
        if let value = object.accessibilityValue, !value.isEmpty { text += " value=\"\(value)\"" }
        if let hint = object.accessibilityHint, !hint.isEmpty { text += " hint=\"\(hint)\"" }
        let traits = object.accessibilityTraits
        let names: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.header, "header"), (.adjustable, "adjustable"), (.image, "image"), (.link, "link"),
            (.staticText, "text"), (.selected, "selected"), (.notEnabled, "disabled"), (.updatesFrequently, "updates"),
        ]
        let found = names.filter { traits.contains($0.0) }.map(\.1)
        if !found.isEmpty { text += " traits=\(found.joined(separator: ","))" }
        if let actions = object.accessibilityCustomActions, !actions.isEmpty {
            text += " actions=\(actions.map(\.name).joined(separator: "|"))"
        }
        let frame = object.accessibilityFrame
        text += " frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        return text
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: " ", count: depth * 2)
    }
}
#endif
