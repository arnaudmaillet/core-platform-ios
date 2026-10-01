import DesignSystem
import UIKit

/// **EXPERIMENTAL — `-snap-layout-v2` (DEBUG/QA only).** The trailing ACTION
/// COLUMN: two Liquid Glass bubbles stacked at the screen's trailing edge that
/// hold the same screen coordinates in BOTH layouts of a post.
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ [♥]          ———————————————————— [♥]
///   caption…                 [⇪]          [☺][field…        ] [〰]
///   ━━━ progress ━━━                      (stake above waveform/send)
///   [♫ attribution]  …  [🔖 ⇄] [⋯]        [♫ attribution]  …  [🔖 ⇄] [⋯]
/// ```
///
/// - Media layout: the points/like anchor (`SnapRailBoostButton`) where it has
///   always been, and a SHARE bubble directly below it, beside the caption and
///   the page strip (which give up that width). Share leaves the toolbar's ⋯.
/// - Comments layout and the Messages thread: the composer's stake bubble
///   stands on the like anchor's frame, and its trailing mic/send slot — the
///   mic now a WAVEFORM — on the share bubble's frame. Same size, same place:
///   switching layouts is an alpha crossfade between two bubbles that never
///   move.
///
/// Off, everything is exactly as before — every surface asks `isEnabled` once,
/// at construction, and keeps its classic geometry when it is false.
///
/// ⚠️ ONE SET OF NUMBERS, two layouts that never see each other. The media
/// layout is constraints inside `SnapChromeView` (band → caption floor →
/// margins), the composer is constraints inside its host (keyboard guide,
/// screen bottom). They agree because both read their geometry from here, and
/// `SnapActionColumnLayoutTests` measures both in window coordinates and
/// asserts the frames are EQUAL — if either side's anchoring changes, that
/// test is what says the column moved.
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
    /// bottom is the band's, and the share bubble's top is the caption
    /// floor's — the band → caption seam.
    static let gap: CGFloat = Spacing.md

    /// How far the LOWER bubble's bottom stands above the bottom margin line
    /// (the toolbar's top edge — the line the feed's safe area stops at).
    ///
    /// In the media layout the share bubble's top is the caption floor's top,
    /// which stands `xl` (the caption's bottom gap) + the floor's two lines
    /// above that line; its bottom is one bubble lower. A composer resting with
    /// its bottom this high puts its mic/send slot on the share bubble.
    @MainActor static var restingLift: CGFloat {
        Spacing.xl + SnapChromeView.captionFloorHeight - bubbleSize
    }

    /// The composer's resting gap above the bottom margin line — the column's
    /// lift when the experiment is on, the classic `sm` breath otherwise.
    @MainActor static func composerRestingGap(actionColumn: Bool) -> CGFloat {
        actionColumn ? restingLift : Spacing.sm
    }

    /// The composer's trailing inset from the screen's edge — the column's
    /// when the experiment is on, the classic `lg` otherwise.
    static func composerTrailingInset(actionColumn: Bool) -> CGFloat {
        actionColumn ? trailingInset : Spacing.lg
    }
}

/// The media layout's share bubble (`-snap-layout-v2`): a Liquid Glass circle
/// the like anchor's size, directly under it. A tap is the post's share — the
/// same sheet ⋯ used to open.
///
/// Configured PLAIN at init; the glass materializes on first window attach —
/// the like anchor's doctrine (`SnapRailBoostButton`): creating a system
/// material contacts the render server, a multi-second main-thread stall on
/// headless CI simulators, where unit-tested views never join a window.
final class SnapRailShareButton: UIButton {
    private var hasGlass = false

    init() {
        super.init(frame: .zero)
        applyFace()
        accessibilityLabel = "Share"
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
            systemName: "square.and.arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        configuration = config
    }
}
