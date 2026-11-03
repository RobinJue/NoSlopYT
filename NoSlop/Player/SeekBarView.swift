import NoSlopKit
import SwiftUI

/// The scrubber: played part in the accent colour, buffered part lighter, SponsorBlock segments in their category
/// colours, a tick at every chapter start. Dragging scrubs (a bubble shows the time and the chapter title) and the
/// seek happens when the finger lifts.
struct SeekBarView: View {
    let currentTime: Double
    let duration: Double
    let bufferedTime: Double
    let segments: [SponsorSegment]
    let chapters: [Chapter]
    /// Called with true when a scrub starts and false when it ends, so the controls stay on screen meanwhile.
    var onScrubbing: (Bool) -> Void = { _ in }
    var onSeek: (Double) -> Void

    @State private var scrubTime: Double?

    /// The bar's touch target; the controls' layout (and the strips the captions use) count on it.
    static let height: CGFloat = 36
    private static let bubbleWidth: CGFloat = 200

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let isScrubbing = scrubTime != nil
            let shown = scrubTime ?? currentTime
            let trackHeight: CGFloat = isScrubbing ? 6 : 3
            let thumbSize: CGFloat = isScrubbing ? 18 : 12
            let thumbX = width * fraction(shown)

            ZStack(alignment: .leading) {
                track(width: width, shown: shown)
                    .frame(height: trackHeight)
                    .clipShape(Capsule())

                Circle()
                    .fill(Theme.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: thumbX - thumbSize / 2)
                    .opacity(duration > 0 ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: isScrubbing)
            .overlay(alignment: .topLeading) {
                if let scrubTime {
                    bubble(for: scrubTime, thumbX: thumbX, width: width)
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seek")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, currentTime + 10))
            case .decrement: onSeek(max(0, currentTime - 10))
            @unknown default: break
            }
        }
    }

    // MARK: Drawing

    private func track(width: CGFloat, shown: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.3))
            Rectangle().fill(.white.opacity(0.5))
                .frame(width: width * fraction(bufferedTime))
            Rectangle().fill(Theme.accent)
                .frame(width: width * fraction(shown))

            ForEach(segments) { segment in
                let start = fraction(segment.start)
                let end = fraction(segment.end)
                if end > start {
                    Rectangle()
                        .fill(Color(sponsorBlockHex: segment.category.colorHex))
                        .frame(width: max(2, width * (end - start)))
                        .offset(x: width * start)
                }
            }

            ForEach(chapterStarts, id: \.self) { start in
                Rectangle()
                    .fill(.black.opacity(0.75))
                    .frame(width: 2)
                    .offset(x: width * fraction(start) - 1)
            }
        }
    }

    /// Chapter starts to mark (the first chapter starts at the left edge and needs no tick).
    private var chapterStarts: [Double] {
        guard duration > 0 else { return [] }
        return chapters.map(\.startSeconds).filter { $0 > 0.5 && $0 < duration }
    }

    private func bubble(for time: Double, thumbX: CGFloat, width: CGFloat) -> some View {
        let bubbleWidth = min(Self.bubbleWidth, width)
        let x = min(max(thumbX - bubbleWidth / 2, 0), width - bubbleWidth)
        let chapter = ChapterLookup.chapter(at: time, in: chapters)
        return VStack(spacing: 1) {
            Text(DurationFormatter.string(seconds: Int(time.rounded(.down))))
                .font(.footnote.weight(.semibold).monospacedDigit())
            if let title = chapter?.title, !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(width: bubbleWidth)
        .offset(x: x, y: -46)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Scrubbing

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if scrubTime == nil {
                    onScrubbing(true)
                }
                scrubTime = time(atX: value.location.x, width: width)
            }
            .onEnded { value in
                guard duration > 0 else { return }
                let target = time(atX: value.location.x, width: width)
                scrubTime = nil
                onScrubbing(false)
                onSeek(target)
            }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        duration * Double(min(max(x / width, 0), 1))
    }

    private func fraction(_ time: Double) -> CGFloat {
        guard duration > 0, time.isFinite else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }

    private var accessibilityValue: String {
        guard duration > 0 else { return "Not available" }
        let now = DurationFormatter.string(seconds: Int(currentTime))
        let total = DurationFormatter.string(seconds: Int(duration))
        return "\(now) of \(total)"
    }
}

// Named so that it cannot clash with a `Color(hex:)` another screen may define.
private extension Color {
    /// "#RRGGBB" (or "RRGGBB"); anything unreadable is mid-grey.
    init(sponsorBlockHex hex: String) {
        var value: UInt64 = 0
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#Preview {
    ZStack {
        Color.black
        SeekBarView(
            currentTime: 70,
            duration: 213,
            bufferedTime: 120,
            segments: SampleData.segments,
            chapters: SampleData.chapters,
            onSeek: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .frame(height: 120)
}
