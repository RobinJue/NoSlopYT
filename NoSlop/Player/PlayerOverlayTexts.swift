import NoSlopKit
import SwiftUI

/// How much room the controls take, for the skip notice and the captions to keep clear of.
///
/// While the controls show, the empty strips between them are all there is: the upper one between the top bar and the
/// centre buttons, the lower one between the centre buttons and the bottom bar. In the small 16:9 player of an iPhone
/// held upright the upper strip is about 37 pt tall and the lower one has no room at all; full screen and iPad have
/// plenty of both. `PlayerControlsView` builds its layout from these numbers, so they cannot drift apart.
struct ControlsFootprint {
    /// The top bar: chevron, title, AirPlay, captions, settings.
    static let topBarHeight: CGFloat = 44
    /// The icon buttons of the bars are this square.
    static let barButton: CGFloat = 44
    /// The play/pause circle in the centre.
    static let centerButton: CGFloat = 64
    /// "Waiting for connection…" under the centre buttons, with the space above it.
    static let waitingNote: CGFloat = 28
    /// What takes the seek bar's place in the bottom bar of a live stream.
    static let liveBarSpacer: CGFloat = 10

    /// From the bottom edge up to the top of the bottom bar; zero when there is none (the error screen).
    var bottomBarHeight: CGFloat
    /// Half the height of everything in the centre; zero when there is none (the error screen).
    var centerHalfHeight: CGFloat

    init(bottomBarHeight: CGFloat, centerHalfHeight: CGFloat) {
        self.bottomBarHeight = bottomBarHeight
        self.centerHalfHeight = centerHalfHeight
    }

    /// The controls of a playing, paused or buffering video.
    init(isLive: Bool, isWaitingForConnection: Bool) {
        self.init(
            bottomBarHeight: Self.barButton + (isLive ? Self.liveBarSpacer : SeekBarView.height),
            centerHalfHeight: Self.centerButton / 2 + (isWaitingForConnection ? Self.waitingNote / 2 : 0)
        )
    }

    /// The error screen keeps only the top bar.
    static let topBarOnly = ControlsFootprint(bottomBarHeight: 0, centerHalfHeight: 0)
}

/// The skip notice and the captions, placed so that they never sit on the controls.
///
/// - Controls hidden: the notice in the top corner, the captions along the bottom edge.
/// - Controls showing: the notice in the upper strip, just below the top bar. The captions in the lower strip, right
///   above the bottom bar, when it holds two lines of them; otherwise in the upper strip (a small inline player has
///   room for nothing else), where they give way to the notice for the few seconds it shows. Captions that do not fit
///   the strip are set smaller, then on one line, then left out rather than put on a button.
struct PlayerOverlayTexts: View {
    let notice: PlayerController.SkipNotice?
    let caption: String?
    /// The controls on screen; nil while they are hidden.
    let controls: ControlsFootprint?
    let isFullscreen: Bool
    let undo: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The viewer's caption style and text size: they decide how tall a caption is, so what fits between the controls.
        // Reading the store here redraws the captions when the style is changed in Settings meanwhile.
        let style = CaptionStyle(
            appearance: CaptionAppearanceStore.shared.appearance,
            dynamicTypeScale: CaptionStyle.dynamicTypeScale(for: dynamicTypeSize)
        )

        GeometryReader { proxy in
            let plan = OverlayPlan(
                height: proxy.size.height,
                controls: controls,
                isLarge: isFullscreen,
                hasNotice: notice != nil,
                captionStyle: style
            )

            ZStack(alignment: .top) {
                if let caption, let slot = plan.caption {
                    FittingCaptionView(text: caption, isLarge: isFullscreen, style: style)
                        .frame(maxWidth: .infinity)
                        .frame(height: slot.height, alignment: slot.alignment)
                        .offset(y: slot.top)
                        .allowsHitTesting(false)
                }

                if let notice, let slot = plan.notice {
                    SkipNoticeView(notice: notice, undo: undo)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, OverlayPlan.noticeInset)
                        .frame(height: slot.height)
                        .offset(y: slot.top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Where the notice and the captions go, in points from the top of the player.
private struct OverlayPlan {
    struct Slot {
        var top: CGFloat
        var height: CGFloat
        var alignment: Alignment
    }

    /// Distance of the notice from the left edge.
    static let noticeInset: CGFloat = 14
    /// How far below the top edge the notice sits when nothing is in the way.
    private static let hiddenNoticeTop: CGFloat = 12
    /// How far above the bottom edge the captions sit when nothing is in the way.
    private static let hiddenCaptionBottom: CGFloat = 14
    /// How far a notice sits from the top bar when its strip is roomy; in a tight one it is centred.
    private static let noticeGap: CGFloat = 8
    /// Between a caption and the bottom bar.
    private static let captionGap: CGFloat = 4

    var notice: Slot?
    var caption: Slot?

    init(height: CGFloat, controls: ControlsFootprint?, isLarge: Bool, hasNotice: Bool, captionStyle: CaptionStyle) {
        let noticeHeight = SkipNoticeView.height

        guard let controls else {
            notice = Slot(top: Self.hiddenNoticeTop, height: noticeHeight, alignment: .center)
            caption = Slot(top: 0, height: max(0, height - Self.hiddenCaptionBottom), alignment: .bottom)
            return
        }

        let topBar = ControlsFootprint.topBarHeight
        let centerTop = height / 2 - controls.centerHalfHeight
        let centerBottom = height / 2 + controls.centerHalfHeight
        let barTop = height - controls.bottomBarHeight
        let upper = Slot(top: topBar, height: max(0, centerTop - topBar), alignment: .center)
        let lower = Slot(top: centerBottom, height: max(0, barTop - centerBottom - Self.captionGap), alignment: .bottom)

        let slack = upper.height - noticeHeight
        let noticeSlot = slack >= 0
            ? Slot(top: topBar + min(Self.noticeGap, slack / 2), height: noticeHeight, alignment: .center)
            : nil
        notice = noticeSlot

        let upperIsFree = !(hasNotice && noticeSlot != nil)
        let roomyLower = lower.height >= CaptionOverlayView.height(lines: 2, size: .regular, isLarge: isLarge, style: captionStyle)
        if roomyLower || !upperIsFree || lower.height >= upper.height {
            caption = lower
        } else {
            caption = upper
        }
    }
}
