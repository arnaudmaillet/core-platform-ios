import DesignSystem
import UIKit

/// **EXPERIMENTAL — `-snap-layout-v2` (DEBUG/QA only).** The trailing ACTION
/// COLUMN: two Liquid Glass bubbles stacked at the screen's trailing edge that
/// hold the same screen coordinates in BOTH layouts of a post.
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ [♥]          ———————————————————— [♥]
///   caption…                 [⇄]          ———————————————————— [⇄ / ↑]
///   ━━━ progress ━━━                      [◉][field…        ☺ 〰]
///   [♫ attribution]  …  [⇪ 🔖] [⋯]        [♫ attribution]  …  [⇪ 🔖] [⋯]
/// ```
///
/// - Media layout: the points/like anchor (`SnapRailBoostButton`) where it has
///   always been, and a REPOST bubble directly below it, beside the caption
///   and the page strip (which give up that width). The toolbar's capsule is
///   [share][bookmark]: share took repost's place there, and left the ⋯.
/// - Comments layout: the composer's stake bubble stands on the like anchor's
///   frame, and its trailing rail slot on the repost bubble's — a REPOST face
///   that turns into the SEND arrow while there is text (a symbol replace, one
///   bubble). Same size, same place: switching layouts is an alpha crossfade
///   between two bubbles that never move. The voice note is a waveform INSIDE
///   the field, beside the emote button.
/// - The Messages thread: no stake (a conversation has nothing to like), and
///   the rail slot is a PIN for the conversation, turning into send the same
///   way.
///
/// Off, everything is as before — every surface asks `isEnabled` once, at
/// construction, and keeps its classic geometry when it is false.
///
/// ⚠️ ONE SET OF NUMBERS, two layouts that never see each other. The media
/// layout is constraints inside `SnapChromeView` (band → caption floor →
/// margins), the composer is constraints inside its host (keyboard guide,
/// screen bottom). They agree because both read their geometry from here, and
/// `SnapActionColumnLayoutTests` measures both in window coordinates and
/// asserts the frames are EQUAL — if either side's anchoring changes, that
/// test is what says the column moved.
///
/// **THE INPUT ROW RESTS ON THE TOOLBAR, flag or no flag** (asked 2026-10-01).
/// The composer's field sits `glassGap` above the toolbar's glass, and the trailing
/// column keeps the place it had: the composer lifts the column off its own
/// bottom by `columnLift`, so the rail bubble stands a little higher than the
/// field — accepted, the field is what reads as "right above the toolbar".
enum SnapActionColumn {
    /// The launch argument that turns the experiment on.
    static let launchArgument = "-snap-layout-v2"

    /// Whether `arguments` ask for the experiment. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for the experiment — the DEFAULT every
    /// surface takes; tests flip it per instance instead (a process-wide
    /// switch would leak across parallel suites).
    static let isEnabled = isEnabled(arguments: ProcessInfo.processInfo.arguments)

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

    /// Where the composer's trailing COLUMN rests above the bottom margin
    /// line: the action column's lift when the experiment is on, the classic
    /// `sm` breath otherwise — where both stood before the input row moved
    /// down onto the toolbar.
    @MainActor static func columnRestingGap(actionColumn: Bool) -> CGFloat {
        actionColumn ? restingLift : Spacing.sm
    }

    /// What the composer puts between its own bottom (the input row's) and
    /// its trailing column's bottom, so a bar resting at `inputRestingGap`
    /// stands its column at `columnRestingGap`.
    @MainActor static func columnLift(actionColumn: Bool) -> CGFloat {
        columnRestingGap(actionColumn: actionColumn) - inputRestingGap
    }

    /// The composer's trailing inset from the screen's edge — the column's
    /// when the experiment is on, the classic `lg` otherwise.
    static func composerTrailingInset(actionColumn: Bool) -> CGFloat {
        actionColumn ? trailingInset : Spacing.lg
    }
}

/// The media layout's repost bubble (`-snap-layout-v2`): a Liquid Glass circle
/// the like anchor's size, directly under it.
///
/// ⚠️ DRAWN WITHOUT AN ACTION, like the toolbar's repost it replaces: the
/// client has no path that publishes a repost yet (see the feed's
/// `configureToolbarItems`).
///
/// Configured PLAIN at init; the glass materializes on first window attach —
/// the like anchor's doctrine (`SnapRailBoostButton`): creating a system
/// material contacts the render server, a multi-second main-thread stall on
/// headless CI simulators, where unit-tested views never join a window.
final class SnapRailRepostButton: UIButton {
    private var hasGlass = false

    init() {
        super.init(frame: .zero)
        applyFace()
        accessibilityLabel = "Repost"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hasGlass {
            hasGlass = true
            applyFace()
        }
    }

    /// The like anchor's face recipe — same glyph size, same white ink over
    /// the media, same zero insets — so the two read as one column.
    private func applyFace() {
        var config: UIButton.Configuration = hasGlass ? .glass() : .plain()
        config.image = UIImage(
            systemName: PostActionSymbol.repost,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        configuration = config
    }
}
