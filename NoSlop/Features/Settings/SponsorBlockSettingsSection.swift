import NoSlopKit
import SwiftUI

/// SponsorBlock: the master switch and, per segment category, what the player does with it
/// (skip it by itself, only mark it on the seek bar, or ignore it).
struct SponsorBlockSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settingsStore
        // Read here so this section updates when a behaviour changes.
        let behaviors = store.settings.segmentBehaviors

        Section {
            Toggle("SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)

            if store.settings.sponsorBlockEnabled {
                ForEach(SponsorCategory.allCases, id: \.self) { category in
                    SegmentBehaviorPicker(category: category, stored: behaviors[category]) { newValue in
                        env.settingsStore.settings.segmentBehaviors[category] = newValue
                    }
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Skips sponsor reads, intros and other parts that viewers marked in the SponsorBlock database. Auto-skip jumps over a part and offers Undo; Show in bar only marks it on the seek bar. Lookups send only a short hash of the video ID.")
        }
    }
}

/// One category row: its SponsorBlock colour, its name, and a menu with the behaviours that make sense for it.
private struct SegmentBehaviorPicker: View {
    let category: SponsorCategory
    let stored: SegmentBehavior?
    let onChange: (SegmentBehavior) -> Void

    var body: some View {
        Picker(
            selection: Binding(get: { selected }, set: { onChange($0) })
        ) {
            ForEach(options, id: \.self) { option in
                Text(Self.title(for: option)).tag(option)
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Self.color(fromHex: category.colorHex))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(category.displayName)
            }
        }
    }

    /// Highlights (points of interest) are never skipped, so "Auto-skip" is not offered for them.
    private var options: [SegmentBehavior] {
        category == .poiHighlight ? [.showInBar, .ignore] : [.autoSkip, .showInBar, .ignore]
    }

    /// The saved behaviour, or the default; one the picker does not offer for this category shows as "Show in bar",
    /// which is what the player does with it.
    private var selected: SegmentBehavior {
        let value = stored ?? AppSettings.defaultSegmentBehaviors[category] ?? .showInBar
        return options.contains(value) ? value : .showInBar
    }

    private static func title(for behavior: SegmentBehavior) -> String {
        switch behavior {
        case .autoSkip: return "Auto-skip"
        case .showInBar: return "Show in bar"
        case .ignore: return "Ignore"
        }
    }

    /// "#RRGGBB" to a colour; grey for anything unreadable.
    private static func color(fromHex hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
