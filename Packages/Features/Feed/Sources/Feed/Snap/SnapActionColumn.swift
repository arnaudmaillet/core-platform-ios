import DesignSystem
import UIKit

/// The trailing ACTION COLUMN: two Liquid Glass bubbles stacked at the
/// screen's trailing edge that hold the same screen coordinates in BOTH
/// layouts of a post.
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ ╭♥╮          ———————————————————— ╭♥╮
///   caption…                 │1.2K│       ———————————————————— │1.2K│
///   ━━━ progress ━━━         ╰─╯                               ╰─╯
///                            [◉]          [◉][field…    ☺ 〰/↑][◉]
///   [author pill] … [⇄ 🔖] [⋯]            [author pill] … [⇄ 🔖] [⋯]
/// ```
///
/// - Media layout: the like PILL (`SnapRailBoostButton`, #669), from the
///   band's top down to `gap` above the lower bubble — the heart on top and
///   the post's like count under it — and the SOUND bubble
///   (`SnapSoundBubbleButton`, #671) on the composer's field line.
/// - Comments layout: the composer's stake pill stands on the like pill's
///   frame, and its trailing rail slot — the sound's cover — on the sound
///   bubble's. Same size, same place: switching layouts is an alpha crossfade
///   between two bubbles that never move. The voice note is a waveform INSIDE
///   the field, beside the emote button, and it becomes the SEND arrow while
///   there is text (a symbol replace).
/// - The Messages thread: no stake (a conversation has nothing to like), and
///   the rail slot is a PIN for the conversation, on the field line.
///
/// The like pill and the dropped lower bubble began behind `-snap-like-pill`
/// (#669) and became the layout on 2026-10-08 (#680).
/// - KEYBOARD UP the column still does not move (asked 2026-10-02): only the
///   composer's input row rides the keyboard, widening into the column's
///   width as it rises clear of it (`CommentsInputBar.riseWithKeyboard(of:)`);
///   the bubbles stay on these coordinates, under the keyboard.
///
/// Began as an experiment behind a DEBUG flag (#340, #344); validated
/// 2026-10-01 and made the only layout — the classic one is gone.
///
/// ⚠️ ONE SET OF NUMBERS, two layouts that never see each other. The media
/// layout is constraints inside `SnapChromeView` (band → caption floor →
/// margins), the composer is constraints inside its host (screen bottom). They agree because both read their geometry from here, and
/// `SnapActionColumnLayoutTests` measures both in window coordinates and
/// asserts the frames are EQUAL — if either side's anchoring changes, that
/// test is what says the column moved.
///
/// **THE INPUT ROW RESTS ON THE TOOLBAR** (asked 2026-10-01). The composer's
/// field sits `glassGap` above the toolbar's glass, and the lower bubble sits
/// on the same line (#669): the field, its avatar and the rail slot are one
/// row of `bubbleSize` (#680).
enum SnapActionColumn {
    /// The bubbles' side: the comment band's height — the like anchor's
    /// square, which the band has always sized. Font-derived, so it follows
    /// the text size the way the anchor does.
    @MainActor static var bubbleSize: CGFloat { SnapCommentTickerView.bandHeight }

    /// From the screen's trailing edge (the chrome's margin) to the column —
    /// the like anchor's inset.
    static let trailingInset: CGFloat = Spacing.md

    /// Between the like bubble and the bubble under it. The like anchor's
    /// bottom is the band's, and the repost bubble's top is the caption
    /// floor's — the band → caption seam.
    static let gap: CGFloat = Spacing.md

    /// How far the LOWER bubble's bottom stands above the bottom margin line
    /// (the line the feed's safe area stops at, just above the toolbar).
    ///
    /// In the media layout the repost bubble's top is the caption floor's top,
    /// which stands `xl` (the caption's bottom gap) + the floor's two lines
    /// above that line; its bottom is one bubble lower.
    @MainActor static var restingLift: CGFloat {
        Spacing.xl + SnapChromeView.captionFloorHeight - bubbleSize
    }

    /// ⚠️ MEASURED: how far the floating toolbar's GLASS stands below the
    /// bottom safe-area line — the safe area a screen with a toolbar reports
    /// stops short of the bar's capsules by this much. The SAME 10pt on both
    /// runtimes the app meets, whatever height the bubble draws (the line
    /// moves with the bar):
    /// - iOS 27, iPhone 18 Pro: the app's feed, `-dump-bars` — line 788, glass
    ///   798…846 (48pt bubbles); the package test host's lone ⋯ — line 792,
    ///   glass 802…846 (a 44pt bubble).
    /// - iOS 26.2, iPhone 16e (CI): the package test host, read off the glass
    ///   frame UIKit drew — 10pt, and the field 12pt (`glassGap`) above it.
    /// Not published by UIKit; re-measure if the bar's metrics move —
    /// `SnapActionColumnLayoutTests.theToolbarsGlassStandsWhereTheComposerExpectsIt`
    /// reads it off a real bar on whichever runtime runs the suite, and fails
    /// with the new number. ⚠️ Read the bubble's frame, never its centre less
    /// 24: the 48pt that assumes is the app's bubble, not UIKit's only one —
    /// that arithmetic read iOS 27's drop as 8 and iOS 26's as 10 and made a
    /// per-OS difference out of nothing (#344, 2026-10-01).
    ///
    /// A CONSTANT, NOT A READING. The glass lives in a private floating-bar
    /// container that UIKit lays out after the screen does, and fades in and
    /// out with every push and hero flight; the feed hands its comments panel
    /// the rest line (`setEngagedInsets`) before that bar exists. A composer
    /// resting on the bar's live frame would land a frame late and move with
    /// the bar's own transitions — the item-width feedback family
    /// (`ios27-bar-item-width-traps`, `bar-item-wrapper-drift`).
    static let toolbarGlassDrop: CGFloat = 10

    /// ⚠️ THE ONE GAP between the composer's field and the toolbar's glass:
    /// the gap UIKit itself leaves between two neighbouring glass bubbles in
    /// that same bar, so the field reads as one more member of the bar.
    /// Measured on iOS 27 (iPhone 18 Pro, `-dump-bars`): the toolbar's
    /// attribution capsule ends at 212 and the actions capsule starts at 224,
    /// and the nav bar's wallet badge ends at 198 and the author pill starts
    /// at 210 — 12pt both. Asked 2026-10-01: the field sat too far above the
    /// bar (18pt), then too close (8pt, `sm`); Liquid Glass bars space their
    /// neighbours by one gap, and this is it. Not below 8 (the HIG's spacing
    /// between related controls), not above ~12 (tighter than before was
    /// the point).
    static let glassGap: CGFloat = 12

    /// The composer's INPUT ROW (its bottom edge) above the bottom margin line
    /// at rest: `glassGap` above the toolbar's glass — which is below the
    /// line, so this is the glass drop short of the gap (and may be negative).
    static var inputRestingGap: CGFloat { glassGap - toolbarGlassDrop }

    // MARK: - The like pill (#669)

    /// The like pill's height: from the band's top down to `gap` above the
    /// lower bubble, which rests on the field line. The same on a text page as
    /// on a media one: derived from the margin line, never from the lower
    /// bubble, which a text page's chrome does not show.
    @MainActor static var likePillHeight: CGFloat { bubbleSize + restingLift - inputRestingGap }

    /// The heart's symbol: an OUTLINE at rest, the points' red FILL once the
    /// viewer has staked (#680).
    static let heartConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    /// The heart's drawn height at `heartConfiguration`.
    @MainActor static var heartHeight: CGFloat {
        UIImage(systemName: PointsSymbol.glyph, withConfiguration: heartConfiguration)?.size.height ?? 15
    }

    /// ⚠️ EVEN GAPS INSIDE THE PILL (#680): top → heart, heart → count, count →
    /// bottom are one gap, the pill's height less the heart and the count,
    /// shared three ways.
    @MainActor static var pillGap: CGFloat {
        max(0, (likePillHeight - heartHeight - SnapLikeCountBadge.height) / 3)
    }

    /// The button insets that put the heart one `pillGap` below the pill's
    /// top: the image centres in what the insets leave, which is exactly the
    /// heart's height.
    @MainActor static var heartInsets: NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: pillGap, leading: 0, bottom: max(0, likePillHeight - pillGap - heartHeight), trailing: 0
        )
    }

    /// Where the count's top sits below the pill's top: one gap, the heart,
    /// another gap.
    @MainActor static var countTopInset: CGFloat { 2 * pillGap + heartHeight }
}
