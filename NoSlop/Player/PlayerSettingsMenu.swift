import NoSlopKit
import SwiftUI

/// The gear in the player's top bar. It opens a small popover with quality (Auto/1080p/720p/480p/360p), playback speed
/// (0.5x-2x) and the caption track, each a menu with the current choice ticked, and the switch that zooms the picture in
/// to fill the player (off: the whole picture, with black bars where it does not fit). All of it is for this video only.
///
/// A popover rather than a `Menu`, because the controls must not fade out while the viewer is choosing, and only a
/// popover says when it is open (`onPresentationChange`).
struct PlayerSettingsMenu: View {
    @Environment(AppEnvironment.self) private var env

    /// Called with true when the popover opens and false when it closes.
    var onPresentationChange: (Bool) -> Void = { _ in }

    @State private var isPresented = false

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        @Bindable var player = env.player

        Button {
            isPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
        .popover(isPresented: $isPresented, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
            VStack(spacing: 0) {
                row("Quality") {
                    Picker("Quality", selection: $player.quality) {
                        ForEach(QualityPreference.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                Divider()

                row("Speed") {
                    Picker("Playback speed", selection: $player.rate) {
                        ForEach(Self.speeds, id: \.self) { speed in
                            Text(Self.speedLabel(speed)).tag(speed)
                        }
                    }
                }

                Divider()

                Toggle(isOn: $player.fillsScreen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zoom to fill")
                        Text("Off shows the whole picture, with black bars where it does not fit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 48)

                if !player.captionTracks.isEmpty {
                    Divider()

                    row("Captions") {
                        Picker("Captions", selection: $player.selectedCaption) {
                            Text("Off").tag(CaptionTrack?.none)
                            ForEach(player.captionTracks) { track in
                                Text(track.name).tag(Optional(track))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isPresented) { _, presented in
            onPresentationChange(presented)
        }
    }

    /// A settings row: the title on the left, the picker's current value (a menu) on the right.
    private func row<Content: View>(_ title: String, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            picker()
                .labelsHidden()
                .pickerStyle(.menu)
        }
        .frame(minHeight: 48)
    }

    /// "Normal", "0.75×", "1.5×".
    static func speedLabel(_ speed: Float) -> String {
        if speed == 1 { return "Normal" }
        return String(format: "%g×", Double(speed))
    }
}
