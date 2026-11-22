import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import LaunchArguments
import MediaCore
import PostGrid
import PostSurfaces
import ThreadKit
import UIKit

/// The snap *page's* UI chrome — the caption over the bottom scrim.
/// Screen-scoped chrome (back item, author identity) lives in the navigation
/// bar instead (`SnapAuthorIdentityView`, stock bar items), so it stays
/// fixed while pages scroll. (Like/comment affordances were removed with the
/// engagement rail; they will return on a different surface.)
///
/// It exists twice per hero flight: embedded in every `SnapFeedCell` (the
/// live, interactive instance) and inside the transition's flying card (an
/// inert replica configured from the same display model). One scaffold, two
/// instances — the flight is pixel-identical to the landed page and the two
/// layouts can never fork, because there is only one layout.
///
/// Geometry is data-independent: labels fill in whenever `configure` runs
/// (possibly mid-flight, on a cold tap) without moving the scaffold.
final class SnapChromeView: UIView {
    /// The bottom legibility scrim: it protects the caption block — the
    /// caption — and leaves the picture
    /// alone above it (#1983, the owner 2026-10-31: "the scrim ends at the
    /// caption block, as a card's does").
    ///
    /// The ramp it draws is `SnapPageScrim`'s (#2521).
    ///
    /// ⚠️ IN POINTS, NOT FRACTIONS OF ITS HEIGHT. The darkness is set at
    /// points of the caption block, the same on every post whatever the
    /// caption's length; its stops were fractions of a scrim whose height was
    /// the block's, so the darkness under the caption changed with it. The
    /// view is a FIXED height (`scrimHeight`, deeper than any screen) pinned
    /// by its top to the block's: it rides the block's animated frame with
    /// nothing recomputed, so nothing jumps, and the flight's replica builds
    /// the same constraints, so it lands pixel-identical. What runs past the
    /// screen's bottom is never seen.
    private let scrimView = GradientView(colors: SnapPageScrim.scrimColors,
                                         locations: SnapPageScrim.scrimLocations)
    /// Clips the scrim at the page's edges: deeper than the page, it would
    /// otherwise darken the next page in the pager (cells don't clip).
    private let scrimClip = UIView()

    /// An `EmoteLabel`: the caption's emoji and `:code:` emotes animate in
    /// place, at the caption's own size (`composedCaption` marks them).
    private let captionLabel = SnapCaptionLabel()

    /// The bucket the caption's emotes are drawn at — what the screen warms
    /// the next captions at (#1504).
    var captionEmotePixelSide: Int { captionLabel.emotePixelSide }

    /// The band, the subtitle zone and the empty state (#2521): built with the
    /// chrome, laid out by it.
    private(set) lazy var commentSurfaces = SnapChromeCommentSurfaces(host: self)
    private var commentTicker: SnapCommentTickerView { commentSurfaces.commentTicker }
    private var subtitleView: SnapSubtitleView { commentSurfaces.subtitleView }
    private var commentEmptyState: SnapCommentEmptyStateView { commentSurfaces.commentEmptyState }
    /// Which page of a COLLECTION the media is showing. Hidden for every post
    /// that has one piece of media, which is most of them.
    /// The page strip, at the bottom of the column and the full width of it.
    ///
    /// ⚠️ It used to be the card's CHIP of dots, floating over the photograph
    /// just above the comment band. Two things were wrong with it there: a
    /// five-dot window is a compromise made for a row that has counters to fit
    /// beside it, and this screen has none — and a small target over the media
    /// is in the one place the page also wants a tap to mean play/pause. Down
    /// here it is a strip the width of the caption, in the band between the
    /// caption and the bar, where a position is read rather than aimed at.
    let mediaPageBar = SnapMediaPageBarView()
    /// The strip's card, filmstrip and scrub focus (#2521): built with the chrome.
    private(set) lazy var mediaStrip = SnapChromeMediaStrip(host: self)

    /// The strip's centre, re-stated when the bar under it or the text size
    /// changes (`applyPageBarPlacement`).
    private var pageBarCenterConstraint: NSLayoutConstraint?


    /// The vertical shortcut wheel on the trailing edge: quick-react
    /// shortcuts (our animated emotes, still until the wheel moves), spanning
    /// the ticker's top up to the nav bar. Static content like the caption —
    /// populated from `configure` with a per-post deterministic payload, so
    /// the flight replica draws the identical wheel.
    let shortcutRail = SnapShortcutRailView()
    /// Where the wheel stands (#1872): an invisible view holding its
    /// constraints in the chrome, while the wheel itself rides the column's
    /// layer, above its glass.
    private let railSeat = UIView()
    private var railLayer: SnapActionColumnLayer { actionColumn.railLayer }
    /// The like pill, the sound bubble and their one glass (#695, #1872, #2521).
    private(set) lazy var actionColumn = SnapChromeActionColumn(host: self)
    var boostButton: SnapRailBoostButton { actionColumn.boostButton }
    private var soundBubble: SnapSoundBubbleButton { actionColumn.soundBubble }

    // MARK: The action column's stations (#695): see `SnapChromeActionColumn`.
    let boostStation = UIView()
    let soundStation = UIView()
    private var boostStationTop: NSLayoutConstraint?
    private var boostStationBottom: NSLayoutConstraint?
    /// The caption floor's bottom, raised with the caption on a media page
    /// (#2301) so the band keeps its place over it.
    private var captionFloorBottom: NSLayoutConstraint?
    private var railBottom: NSLayoutConstraint?
    /// The sound station's bottom: the column's, on the caption's line at
    /// rest on a media page (#2326).
    private var soundStationBottom: NSLayoutConstraint?

    /// The insets the cell handed over (`setFixedInsets`), before the
    /// bottom breath is added to them.
    private var fixedInsets: UIEdgeInsets?

    /// The like pill's bottom above the margin line.
    private static var boostStationBottomInset: CGFloat {
        SnapActionColumn.inputRestingGap + SnapActionColumn.bubbleSize + SnapActionColumn.gap
    }

    private var columnLayer: SnapActionColumnLayer { actionColumn.columnLayer }
    private var glassColumn: SnapGlassColumn { actionColumn.glassColumn }

    private(set) var imagePipeline: ImagePipeline?
    /// The rail's top edge as a cell-relative constant (see `buildLayout`).
    /// Optional: margins change during `init` before the layout exists.
    private var railTopConstraint: NSLayoutConstraint?
    /// A zero-content region that RESERVES the caption's locked two-line box
    /// on EVERY post — a real two-line media caption or an (empty) text-only
    /// post alike. The ticker (and, riding it, the rail + "+") pins to this
    /// guide's top rather than the caption label's, so the whole engagement
    /// corner sits at ONE position agnostic of format: on text-only posts the
    /// collapsed (empty) label no longer lets the "+" drop into the input
    /// bar, and the geometry is pixel-identical to media posts by
    /// construction (the guide's height is a pure font-derived constant).
    private let captionFloorGuide = UILayoutGuide()
    /// The floor guide's height constraint — its constant is the caption's
    /// two-line box, refreshed on Dynamic Type changes alongside the caption.
    private var captionFloorHeightConstraint: NSLayoutConstraint?
    /// The caption's ONE seat (#2252): its bottom on the sound cover's line,
    /// on every format. (Two seats until #2252 — xl over a page strip, the
    /// cover's line without one, the owner 2026-10-16, #1716, #1726.)
    private var captionOnCoverLine: NSLayoutConstraint?
    /// The caption block's two-line floor on a media page (#2252): the label
    /// is never shorter than two caption lines, whatever it holds. Off on a
    /// text page, whose chrome draws no caption.
    private var captionBlockFloor: NSLayoutConstraint?
    /// Top margins beyond this are transition churn (safe-area insets
    /// re-propagating into a cell mid-flight), not a settled state — a real
    /// settled top (status bar + transparent nav bar) stays well under it
    /// on every device class.
    static let maxSettledTopMargin: CGFloat = 160

    /// Subtrees where a touch means "use the control", not "toggle playback" —
    /// consumed by the cell's tap arbitration: the shortcut rail and its
    /// "+" anchor (rail territory in both engagement states — the pager's
    /// swipe veto already treats it so), plus every comments surface (the
    /// empty-state pill, the subtitle zone, the ticker band — the
    /// engagement's entry points; hidden views receive no touches, so each
    /// claims taps only while shown).
    var interactionRoots: [UIView] {
        // The wheel's capsule (#1872): the wheel lets its touches through to it.
        [shortcutRail, shortcutRail.capsule.glass, boostButton, commentEmptyState, subtitleView, commentTicker,
         soundBubble, captionLabel]
    }

    @objc private func captionTapped() {
        onCommentsTapped?()
    }

    /// A tap on the caption — for tests.
    func debugTapCaption() { captionTapped() }

    #if DEBUG
    /// The scrim and the caption, for the scrim's suite.
    var debugScrimView: UIView { scrimView }
    var debugScrimClip: UIView { scrimClip }
    var debugCaptionLabel: UIView { captionLabel }
    #endif

    /// A comments surface was tapped (empty-state pill, subtitle zone, or
    /// ticker band — one fan-in, one path) — the cell forwards this as a
    /// comments-engagement request with its post identity attached.
    var onCommentsTapped: (() -> Void)?
    /// The band has shown most of its reactions (#2005).
    var onReactionsRunningLow: (() -> Void)?

    /// The rail's boost anchor asked to spend on this post (tap = the
    /// default amount, long-press menu = the default or one ×100 shot).
    /// The cell forwards it with the post identity attached; whether the
    /// wallet can afford it is the OWNER's answer, which comes back through
    /// `playBoostConfirmation` / `playBoostDenied`.
    var onBoostRequested: ((WalletStakeSpend) -> Void)?
    /// The anchor's menu asked to take back the session's spend on this
    /// post. Same fan-out as the spend: cell attaches the identity, the
    /// owner does the refund and answers with `playBoostRefund`.
    var onBoostUndoRequested: (() -> Void)?

    private var representedID: PostID?



    /// THE STREAM UNDER THE BAND (the owner, 2026-10-16; the experiment
    /// `-snap-stream-under-band` of #1244, kept): the streaming comments
    /// (`subtitleView`) sit on the caption, one md above its floor, and the
    /// danmaku band rides one md above them, stopping short of the rail
    /// with its trailing end faded. The engagement corner (the like pill,
    /// the rail, the sound bubble) hangs off `bandSeat` — the slot one md
    /// above the caption floor, the band's height — not off the band.
    private let bandSeat = UILayoutGuide()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // The chrome pins to its margins guide, NOT the safe-area guide
        // directly, because the margins are meant to be OWNED from outside:
        // live cells receive the feed view's safe-area insets via
        // `applyChromeInsets` (the screen's header/footer thresholds — a
        // moving cell's ambient safe area re-derives every transition frame
        // and is structurally untrustworthy), and the flight replica
        // receives captured insets the same way. Ambient tracking below is
        // only the pre-first-push fallback until an owner pushes real
        // thresholds.
        layoutMargins = .zero
        insetsLayoutMarginsFromSafeArea = true
        preservesSuperviewLayoutMargins = false

        captionLabel.numberOfLines = 2
        captionLabel.lineBreakMode = .byTruncatingTail

        // The caption's font lives in its attributed string (see
        // `renderedCaption`), which `adjustsFontForContentSizeCategory`
        // cannot track — re-resolve on Dynamic Type changes so live and
        // reused cells can never show two different caption sizes. The floor
        // guide's reserved height is font-derived too, so it re-resolves on
        // the same beat.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { (self: SnapChromeView, _) in
            self.captionFloorHeightConstraint?.constant = SnapChromeGeometry.captionFloorHeight
            // The two-line block and the strip's place follow the font too
            // (#2252): two lines at every size, the line still centred under
            // the letters.
            self.captionBlockFloor?.constant = self.captionBlockHeight
            self.applyPageBarPlacement()
            self.renderCaption()
        }

        buildLayout()
        installSoundBubble()
        actionColumn.applySoundVisibility()
        // The cover's line raised from the start (#2301), before any insets.
        applySeat()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A fresh chrome, a spare when one is ready (`SnapChromeSpares`, #2126).
    static func make() -> SnapChromeView { SnapChromeSpares.make() }

    /// The chrome is an overlay CANVAS: only its subviews are touchable.
    /// Bare-canvas hits fall through to whatever lies beneath — the media
    /// (play/pause), or the engaged comments region (whose inner list must
    /// scroll; a full-cell chrome above it would otherwise swallow every
    /// drag and hand it to the pager, which is exactly the bug this fixed).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // ⚠️ THE CAPTION BEFORE THE STRIP (#2252). The strip's invisible
        // 44 pt touch area is centred on its 2 pt line, about 10 pt under the
        // letters, so it reaches up over the caption's last line — and the
        // strip is the later sibling, so it would take a tap on the words. A
        // tap on the caption keeps opening the comments; the strip has the
        // gap down to the bar.
        if !mediaPageBar.isHidden, mediaPageBar.alpha > 0.01, captionLabel.frame.contains(point),
           let words = captionLabel.hitTest(convert(point, to: captionLabel), with: event) {
            return words
        }
        // ⚠️ AND THE COLUMN BEFORE THE STRIP (#2291). The strip now runs under
        // the column, and its 44 pt area reaches up over the sound cover's
        // bottom: a touch that starts on a column item is that item's.
        if !mediaPageBar.isHidden, mediaPageBar.alpha > 0.01, let item = actionColumn.columnItemHit(at: point, with: event) {
            return item
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func buildLayout() {
        scrimView.isUserInteractionEnabled = false
        scrimClip.isUserInteractionEnabled = false
        scrimClip.clipsToBounds = true
        scrimClip.constrain(in: self) { parent in
            scrimClip.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimClip.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimClip.topAnchor.constraint(equalTo: parent.topAnchor)
            scrimClip.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        #if DEBUG
        // `-scrim-white-page`: a flat white page under the scrim, to measure
        // it as the reference was measured (#2175).
        if LaunchArgument.scrimWhitePage.isPassed() {
            let white = UIView()
            white.backgroundColor = .white
            white.isUserInteractionEnabled = false
            white.translatesAutoresizingMaskIntoConstraints = false
            insertSubview(white, at: 0)
            NSLayoutConstraint.activate([
                white.leadingAnchor.constraint(equalTo: leadingAnchor),
                white.trailingAnchor.constraint(equalTo: trailingAnchor),
                white.topAnchor.constraint(equalTo: topAnchor),
                white.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        #endif
        scrimView.constrain(in: scrimClip) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            // Fixed: its stops are points (see `scrimView`).
            scrimView.heightAnchor.constraint(equalToConstant: SnapPageScrim.scrimHeight)
        }

        // Caption, over the scrim; its trailing edge stops one md short of the
        // sound bubble (`installSoundBubble`). The margins guide tracks the
        // safe area, so when the navigation controller's toolbar is visible
        // the caption sits above it automatically — live cell and flight
        // replica alike (`setFixedInsets` captures the toolbar-inflated
        // insets). The bottom gap is one token up from the sides (xl vs
        // lg): the caption is the stack's last line before the toolbar
        // band, and the seam between page content and bar chrome carries
        // the harmonized rhythm's largest breath.
        captionLabel.constrain(in: self) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
        }
        // ⚠️ ONE SEAT, ON EVERY FORMAT (#2252, the owner 2026-11-10): the
        // caption's bottom on the sound cover's line — the column's bottom —
        // whatever the post: a single photo, a carousel, a clip. It used to
        // sit xl up over a page strip (the owner, 2026-10-16, #1716/#1726),
        // and the caption and everything stacked on it jumped 22 pt between a
        // photo and a video. The strip now lies in the gap below
        // (`pageBarCenterOffset`) and reserves nothing.
        let captionOnCover = captionLabel.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
        )
        captionOnCoverLine = captionOnCover
        captionOnCover.isActive = true
        // ⚠️ AND ALWAYS TWO LINES TALL (#2252): the composition puts the date
        // on line two whatever the caption (`composedCaption`), and this
        // floor holds the box at two caption lines even when there is
        // nothing to compose (no date, an unmeasured width) — so the author
        // row, the stream and the danmaku over it never move between posts.
        // A floor, not an equality: the label's own height for two lines is
        // pixel-rounded, and a box a hair shorter would drop its second line.
        captionBlockFloor = captionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: captionBlockHeight)

        // The caption FLOOR: a zero-content region co-located with the
        // caption label (same bottom, same horizontal margins) but with a
        // FIXED two-line height, present on every format. The ticker/rail/"+"
        // corner hangs off THIS guide's top, not the label's — so a text-only
        // post's empty (collapsed) label can't let the corner sink into the
        // input bar, and the corner's position is a pure font constant,
        // pixel-identical whether the post is video, photo, or text.
        addLayoutGuide(captionFloorGuide)
        let floorHeight = captionFloorGuide.heightAnchor.constraint(equalToConstant: SnapChromeGeometry.captionFloorHeight)
        captionFloorHeightConstraint = floorHeight
        // Raised with the cover's line on a media page (#2301), so the band
        // keeps its place over the caption.
        let floorBottom = captionFloorGuide.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -Spacing.xl
        )
        captionFloorBottom = floorBottom
        NSLayoutConstraint.activate([
            captionFloorGuide.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor),
            captionFloorGuide.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor),
            // A FIXED line, not the label's bottom: the corner that hangs off
            // this floor keeps its own rule (#2252 left it where it was).
            floorBottom,
            floorHeight,
        ])

        // The comment ticker rides directly above the caption, full-width so
        // bubbles traverse the whole page. It is an overlay over the media:
        // its presence or absence never moves the caption, which keeps the
        // flight replica's geometry identical whether or not comments exist.
        // (Constrained after the caption — its bottom hangs off the caption's
        // top.)
        // The band's trailing edge is the "+" square's OUTER threshold, not
        // the screen's: bubbles spawn just past it and the band clips there,
        // so every comment is born hidden under the frosted square and
        // slides out of its seam — the square reads as the stream's source.
        // (Leading stays full-bleed; exits keep using the screen's edge.)
        // The half-point tuck: band and glass edges pixel-round
        // independently, and a coincident clip line can land 1/3pt proud
        // of the glass — tucking the band's trailing strictly inside the
        // square kills the sliver at every pixel alignment.
        // HEIGHT AUTHORITY: the band's intrinsic height (type metrics,
        // fixed at init) is the master for the whole corner — the "+"
        // anchor's edges pin to it, the rail's width and reserved strip
        // derive from it. Intrinsic sizes bind at 750 by default, and the
        // glass button's OWN intrinsic size (glyph + material insets)
        // joined the same equations when it stretched to the band's edges:
        // two 750s through equality constraints = an ambiguous system that
        // resolved either way pass to pass (the height jitter). Required
        // hugging/resistance makes the band unsqueezable and unstretchable.
        commentTicker.setContentHuggingPriority(.required, for: .vertical)
        commentTicker.setContentCompressionResistancePriority(.required, for: .vertical)
        commentTicker.constrain(in: self) { parent in
            commentTicker.leadingAnchor.constraint(equalTo: leadingAnchor)
        }
        // The band's seat: md, not sm — the band and the caption are separate
        // CONTAINERS in the bottom stack, and inter-container seams breathe
        // at md in the harmonized rhythm (sm stays the WITHIN-container gap).
        // Off the caption FLOOR (not the label): the fixed two-line
        // reservation is what makes this corner format-agnostic — a
        // collapsed text-only caption reserves the same box a two-line media
        // caption fills, so the band never sinks toward the bar.
        addLayoutGuide(bandSeat)
        NSLayoutConstraint.activate([
            bandSeat.leadingAnchor.constraint(equalTo: leadingAnchor),
            bandSeat.trailingAnchor.constraint(equalTo: trailingAnchor),
            bandSeat.bottomAnchor.constraint(equalTo: captionFloorGuide.topAnchor, constant: -Spacing.md),
            bandSeat.heightAnchor.constraint(equalTo: commentTicker.heightAnchor),
        ])

        // NOTE: nothing rides above the ticker any more. The page indicator
        // used to — a chip of dots hung off the band's top edge — and it is the
        // strip below the caption now (`mediaPageBar`), which is why this
        // corner is one container shorter than it was.
        //
        // ⚠️ THE FULL WIDTH OF THE COLUMN, and the caption's own margins are
        // what defines it: the strip is the pictures' index, the caption is
        // what they are about, and two things stacked in one column read as
        // one thing only if they share an edge.
        //
        // ⚠️ A 2 PT LINE IN THE GAP THAT ALREADY EXISTS (#2252, the owner
        // 2026-11-10, as TikTok's and Instagram's): centred between the
        // bottom of the caption's letters and the top of the bottom bar's
        // glass (`pageBarCenterOffset`), reserving no height — the caption
        // stands on the cover's line whether the strip is there or not, and a
        // post with one picture simply has nothing in that gap. Centred, it
        // stays clear of both: the strip is the pictures' index, the bar what
        // you can DO to the post. (It was pinned 4 pt over the margins line
        // in a 6 pt footprint, the caption seated 22 pt higher for it.)
        mediaStrip.installOverlays()
        mediaPageBar.constrain(in: self) { parent in
            mediaPageBar.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor)
            mediaPageBar.heightAnchor.constraint(equalToConstant: SnapMediaPageBarView.thickness)
        }
        let pageBarCenter = mediaPageBar.centerYAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: currentPageBarCenterOffset
        )
        pageBarCenterConstraint = pageBarCenter
        pageBarCenter.isActive = true
        // Its trailing edge: the column's outer edge, see `installSoundBubble`
        // (#2291).


        // The shortcut rail owns the trailing column, layered OVER the
        // band: its bottom rides down to the ticker's BOTTOM edge, so the
        // wheel's bubbles rest into — and scroll through — the band's
        // territory on the glass pedestal above. The top is NOT anchored
        // to the margins guide: cells ride page transitions, and UIKit
        // re-propagates safe-area insets into a moving cell continuously —
        // a guide-anchored top made the rail's geometry churn every
        // transition frame (icons drifted off the page toward the screen's
        // safe boundary instead of riding the cell). Instead the top pins
        // to the CELL's top with a constant that tracks the margin only
        // while it is a plausible settled value (`layoutMarginsDidChange`
        // below), freezing through the flight so the rail rides like the
        // rest of the chrome.
        let railTop = railSeat.topAnchor.constraint(
            equalTo: topAnchor, constant: layoutMargins.top + Spacing.sm
        )
        railTopConstraint = railTop
        // ⚠️ THE SEAT, NOT THE WHEEL (#1872): the wheel draws ABOVE the
        // action column's glass — its capsule is that glass's, and the emotes
        // pass over it — so it lives in the column's layer, framed on this
        // invisible seat, which keeps every constraint the wheel had.
        railSeat.isHidden = true
        railSeat.isUserInteractionEnabled = false
        railSeat.constrain(in: self) { parent in
            railSeat.trailingAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -SnapActionColumn.trailingInset
            )
            railSeat.widthAnchor.constraint(equalTo: bandSeat.heightAnchor)
            railTop
            railBottomConstraint()
        }

        // The boost anchor fills 100% of the overlap square, above the rail:
        // emotes scroll (and rubber-band) beneath it while it holds still.
        // Skinned in the SYSTEM's Liquid Glass (materialized on window
        // attach — see `SnapRailBoostButton`); capsule on the square box
        // (width == the band's height) renders a perfect circle inscribed
        // in the zone — the zone's only layer, now that the frosted chip
        // is gone. Constrained off ticker + margins, exactly the bounds
        // the old backdrop occupied.
        boostButton.isHidden = true
        boostButton.onBoost = { [weak self] spend in self?.onBoostRequested?(spend) }
        boostButton.onUndo = { [weak self] in self?.onBoostUndoRequested?() }
        // The anchor is fully framed from outside (band edges + margins);
        // its intrinsic content size must exert ZERO back-pressure on the
        // graph — floor priorities mean it can never squeeze the band or
        // stretch itself (the other half of the height-authority contract).
        boostButton.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        boostButton.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        boostButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
        boostButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        boostStation.isUserInteractionEnabled = false
        boostStation.constrain(in: self) { parent in
            boostStation.trailingAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -SnapActionColumn.trailingInset
            )
            boostStation.widthAnchor.constraint(equalTo: bandSeat.heightAnchor)
            boostStationTopConstraint()
            // The like pill (#669) runs down to `gap` above the lower bubble,
            // measured from the margin line rather than off the sound bubble —
            // a text page's station keeps the same frame.
            boostStationBottomConstraint(margins: parent.layoutMarginsGuide)
        }
        // The subtitle zone extends the same one-directional chain one link
        // up (caption ← band ← subtitles): nothing constrains back onto it,
        // so cue presence/absence can never move the stack below. The slot
        // spans from the caption's leading edge to the shortcut rail — the
        // zone no longer runs the full width; the trailing column is the
        // rail's. The view left-aligns its pill inside the slot, so the
        // pill's left edge locks to the caption's leading margin — cues
        // stack on the caption's text axis — and long cues grow toward the
        // rail's clearance.
        subtitleView.constrain(in: self) { parent in
            subtitleView.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            subtitleView.trailingAnchor.constraint(equalTo: railSeat.leadingAnchor, constant: -Spacing.md)
        }
        // The zone holds the band's seat, one md above the caption floor —
        // the slot the empty-state pill occupies too, so every comment
        // surface starts at one position. The band stands on the zone, md
        // above it, and stops short of the rail like the zone does: with no
        // glass to nest in there, its trailing end dissolves.
        // On the caption — always two lines tall on a media page since #2252
        // (it was one line for a short caption with its time inline, the
        // owner 2026-10-16, and the stream came down a line: a jump between
        // posts).
        NSLayoutConstraint.activate([
            subtitleView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md),
            commentTicker.bottomAnchor.constraint(equalTo: subtitleView.topAnchor, constant: -Spacing.md),
            commentTicker.trailingAnchor.constraint(equalTo: railSeat.leadingAnchor, constant: -Spacing.md),
        ])
        commentTicker.fadesTrailingEdge = true

        // The comments empty state sits in the BAND's slot (bottom on the
        // caption's top, leading on the caption's text axis — where a
        // zero-comment page's blank zone actually is), not the subtitle
        // zone's: with no comments there is no band, and the pill hugging
        // the caption reads as the comment container's own placeholder
        // rather than a stray cue. Another overlay on the one-directional
        // chain: it constrains onto the caption, nothing constrains onto
        // it, so its presence can never move the stack.
        commentEmptyState.constrain(in: self) { parent in
            commentEmptyState.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            commentEmptyState.trailingAnchor.constraint(lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.lg)
        }
        // md: it stands in the band's seat, so it keeps the band's harmonized
        // seam against the caption.
        commentEmptyState.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md).isActive = true
        // The scrim's top: the caption block's, less the lead.
        scrimView.topAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -SnapPageScrim.scrimLead).isActive = true
        commentEmptyState.onTap = { [weak self] in self?.onCommentsTapped?() }
        subtitleView.onTap = { [weak self] in self?.onCommentsTapped?() }
        commentTicker.onTap = { [weak self] in self?.onCommentsTapped?() }
        commentTicker.onRunningLow = { [weak self] in self?.onReactionsRunningLow?() }
        // …and the caption (#1720, the owner): the post's words lead to what
        // is said about them.
        captionLabel.isUserInteractionEnabled = true
        captionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(captionTapped)))
        // …and a horizontal slide on it drives the strip (#2269).
        captionSlide.addTarget(self, action: #selector(captionSlid(_:)))
        captionSlideGate.mayBegin = { [weak self] travel in
            self?.captionSlideMayBegin(velocity: travel) ?? false
        }
        captionSlide.delegate = captionSlideGate
        captionLabel.addGestureRecognizer(captionSlide)
        captionLabel.claimsDrag = { [weak self] velocity in
            self?.captionSlideMayBegin(velocity: velocity) ?? false
        }
    }

    // MARK: - The caption drives the strip (#2269)

    /// A horizontal slide on the caption, on a post with a strip: the strip's
    /// scrub or browse, relative (`SnapMediaPageBarView.relativeDrag`). The
    /// owner, 2026-11-10: the 2 pt strip is hard to hit, and the caption
    /// right above it is the natural place to slide.
    ///
    /// ⚠️ THE COST, ACCEPTED BY THE OWNER: on a clip or a carousel, a
    /// horizontal slide that starts on the caption no longer goes back (a
    /// pushed post) or changes sector (Shots). The media above it still does,
    /// as does the leading edge. On a post without a strip the caption keeps
    /// today's behaviour: the pan never begins.
    let captionSlide = UIPanGestureRecognizer()
    private let captionSlideGate = SnapCaptionSlideGate()

    /// Whether the caption's slide may begin, for a drag heading the way
    /// `velocity` says: a strip to drive, and a clearly horizontal travel —
    /// so a vertical swipe that starts on the caption pages the feed at once.
    func captionSlideMayBegin(velocity: CGPoint) -> Bool {
        guard mediaPageBar.acceptsRelativeDrag else { return false }
        return Self.isHorizontalSlide(velocity)
    }

    /// A travel (or velocity) clearly horizontal: x dominates y by half again.
    static func isHorizontalSlide(_ vector: CGPoint) -> Bool {
        abs(vector.x) > 0 && abs(vector.x) > abs(vector.y) * horizontalDominance
    }

    /// How much x must outweigh y for the slide to be the caption's.
    static let horizontalDominance: CGFloat = 1.5

    @objc private func captionSlid(_ pan: UIPanGestureRecognizer) {
        mediaPageBar.relativeDrag(pan.state, travel: pan.translation(in: self).x)
    }

    /// The action column's media half (`SnapActionColumn`): the SOUND bubble
    /// (#671) on the composer's field line, `glassGap` above the toolbar's
    /// glass (#669), and the caption — with the page strip, which shares its
    /// trailing edge — ending one md short of it.
    private func installSoundBubble() {
        soundBubble.isHidden = true
        // Framed from outside, like the like pill: zero back-pressure from
        // its intrinsic size (see the pill's height-authority note).
        soundBubble.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        soundBubble.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        soundBubble.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
        soundBubble.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        soundStation.isUserInteractionEnabled = false
        soundStation.constrain(in: self) { parent in
            soundStation.trailingAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -SnapActionColumn.trailingInset
            )
            soundStation.widthAnchor.constraint(equalTo: bandSeat.heightAnchor)
            soundStation.heightAnchor.constraint(equalTo: bandSeat.heightAnchor)
        }
        // On the caption's line at rest (#2326, `applySeat` raises it from
        // the composer's line).
        let soundBottom = soundStation.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
        )
        soundStationBottom = soundBottom
        soundBottom.isActive = true
        captionLabel.trailingAnchor.constraint(
            equalTo: soundStation.leadingAnchor, constant: -Spacing.md
        ).isActive = true
        // ⚠️ THE STRIP RUNS THE CONTENT'S FULL WIDTH (#2291, the owner
        // 2026-11-11, the width #2252 left open): from the caption's first
        // letter to the action column's outer edge, under the sound cover —
        // it lies below the cover's bottom (#2252), so they never meet. Not
        // edge to edge: TikTok's line lies on the video's bottom edge; ours
        // floats between the caption and a glass bar, inside the content's
        // column.
        mediaPageBar.trailingAnchor.constraint(equalTo: soundStation.trailingAnchor).isActive = true
        actionColumn.assemble()
    }

    /// See `SnapChromeActionColumn` — the cell's, the flight replica's and the tests'.
    func setSoundShowsReturn(_ shows: Bool, down: Bool = false, animated: Bool = true) {
        actionColumn.setSoundShowsReturn(shows, down: down, animated: animated)
    }
    func setSlotSharesPost(_ shares: Bool, holdArmsShare: Bool = false) {
        actionColumn.setSlotSharesPost(shares, holdArmsShare: holdArmsShare)
    }

    private func railBottomConstraint() -> NSLayoutConstraint {
        let constraint = railSeat.bottomAnchor.constraint(equalTo: bandSeat.bottomAnchor)
        railBottom = constraint
        return constraint
    }

    private func boostStationTopConstraint() -> NSLayoutConstraint {
        let constraint = boostStation.topAnchor.constraint(equalTo: bandSeat.topAnchor)
        boostStationTop = constraint
        return constraint
    }

    /// The like pill (#669) runs down to `gap` above the lower bubble,
    /// measured from the margin line rather than off the sound bubble — a
    /// text page's station keeps the same frame.
    private func boostStationBottomConstraint(margins: UILayoutGuide) -> NSLayoutConstraint {
        let constraint = boostStation.bottomAnchor.constraint(
            equalTo: margins.bottomAnchor, constant: -Self.boostStationBottomInset
        )
        boostStationBottom = constraint
        return constraint
    }

    /// The column's stations as the page stands (#2326): risen by the
    /// column's lift on a media page at rest — the like pill and the sound
    /// together, the rail's bottom with them. The like pill's top hangs off
    /// the band's seat, which already rose by the cover line's lift with the
    /// caption floor: only the difference is added. True when a constant
    /// changed.
    @discardableResult
    private func applyColumnSeat() -> Bool {
        let column = currentColumnLineLift
        let overBand = currentCoverLineLift - column
        let constants: [(NSLayoutConstraint?, CGFloat)] = [
            (boostStationTop, overBand),
            (boostStationBottom, -(Self.boostStationBottomInset + column)),
            (railBottom, overBand),
            (soundStationBottom, -(SnapActionColumn.inputRestingGap + column)),
        ]
        var changed = false
        for (constraint, constant) in constants {
            guard let constraint, constraint.constant != constant else { continue }
            constraint.constant = constant
            changed = true
        }
        return changed
    }

    func setSoundFace(_ face: SnapSoundFace?) { actionColumn.setSoundFace(face) }

    /// The rail's reserved bottom strip is the glass square's height — a
    /// font-derived value (the ticker's intrinsic height), so it is read
    /// off the resolved layout rather than duplicated as a constant. The
    /// rail's own setter no-ops on identical values, so this cannot loop.
    ///
    /// The rail's HEIGHT is then grid-aligned: the headroom above the
    /// resting window (`contentInset.top`) must be an exact multiple of
    /// the emote step, or settles leave the top-most exiting emote
    /// stranded half-faded/half-scaled. The tallest fit under the nav bar
    /// is computed and the sub-step excess absorbed into the rail's top
    /// constant. Idempotent (the formula reads margins + ticker frames,
    /// never the current constant), so re-layout converges immediately.
    override func layoutSubviews() {
        super.layoutSubviews()
        hasLaidOut = true
        // The stations are resolved: the glass column stands its bubbles on
        // them in the same pass (#1872).
        glassColumn.setNeedsLayout()
        glassColumn.layoutIfNeeded()
        // The wheel on its seat (#1872) — by size and centre: a scroll view's
        // bounds origin is its offset.
        // Into the column's layer, which the wheel's layer fills: the wheel's
        // layer's own glide (#2326) is not undone by the conversion.
        let wheelFrame = railSeat.convert(railSeat.bounds, to: columnLayer)
        if shortcutRail.bounds.size != wheelFrame.size { shortcutRail.bounds.size = wheelFrame.size }
        let centre = CGPoint(x: wheelFrame.midX, y: wheelFrame.midY)
        if shortcutRail.center != centre { shortcutRail.center = centre }
        shortcutRail.bottomReservedInset = bandSeat.layoutFrame.height

        // The caption's two-line/timestamp composition is width-dependent —
        // re-resolve it once the label has a (new) real width. Guarded on the
        // width so the re-render (which invalidates layout) converges in one
        // extra pass instead of looping.
        if captionLabel.bounds.width != lastRenderedCaptionWidth {
            renderCaption()
        }

        let top = layoutMargins.top
        // Off the band's SEAT, not the band: the band rides the stream,
        // the rail never does.
        let seat = bandSeat.layoutFrame
        guard top <= Self.maxSettledTopMargin, seat.maxY > 0 else { return }
        let base = top + Spacing.sm
        let fixedZones = SnapShortcutRailView.restingWindowHeight
            + SnapShortcutRailView.edgeFadeLength
            + seat.height
        // The rail's bottom rides the column, not the band (#2326): the
        // column rose by its own lift, the band by the cover line's.
        let headroom = seat.maxY + currentCoverLineLift - currentColumnLineLift - base - fixedZones
        guard headroom > 0 else { return }
        let aligned = (headroom / SnapShortcutRailView.step).rounded(.down) * SnapShortcutRailView.step
        let constant = base + (headroom - aligned)
        if railTopConstraint?.constant != constant {
            railTopConstraint?.constant = constant
        }
    }

    /// Flight replica: freeze the guide to *captured* insets (the live feed's
    /// real safe area) instead of ambient propagation, so the replica's
    /// geometry equals the live cell's regardless of what the transition
    /// container resolves.
    func setFixedInsets(_ insets: UIEdgeInsets) {
        fixedInsets = insets
        applyFixedInsets()
    }

    /// The handed-over insets, the breath over the bottom bar added (#1716,
    /// #1722: every feed, the flight replica included).
    private func applyFixedInsets() {
        guard var insets = fixedInsets else { return }
        insets.bottom += SnapActionColumn.bottomBreath
        insetsLayoutMarginsFromSafeArea = false
        layoutMargins = insets
        // The breath is in the margins now: the glass is that much nearer.
        applyPageBarPlacement()
    }

    /// The strip's centre for this chrome as it stands: over the toolbar,
    /// with the breath in its margins once a feed handed them.
    private var currentPageBarCenterOffset: CGFloat {
        SnapChromeGeometry.pageBarCenterOffset(breathApplied: fixedInsets != nil)
    }

    /// Re-centres the strip (#2252): the bar under it, the breath and the
    /// caption's font all move the gap it is centred in.
    private func applyPageBarPlacement() {
        applySeat()
        let offset = currentPageBarCenterOffset
        guard let center = pageBarCenterConstraint, center.constant != offset else { return }
        center.constant = offset
        setNeedsLayout()
    }

    /// The cover's line's lift for this chrome as it stands (#2301): a
    /// media page's; a text page keeps #2252's line.
    private var currentCoverLineLift: CGFloat {
        guard hasMedia else { return 0 }
        return onPixels(SnapChromeGeometry.coverLineLift(breathApplied: fixedInsets != nil))
    }

    /// The column's lift for this chrome as it stands (#2326): a media
    /// page's; a text page keeps #2252's line.
    var currentColumnLineLift: CGFloat {
        guard hasMedia else { return 0 }
        return onPixels(SnapChromeGeometry.columnLineLift(breathApplied: fixedInsets != nil))
    }

    /// On the pixel grid, so the band, the floor, the column and the rail's
    /// headroom all move by the same drawn amount.
    private func onPixels(_ raw: CGFloat) -> CGFloat {
        let scale: CGFloat = max(traitCollection.displayScale, 1)
        return (raw * scale).rounded() / scale
    }

    /// Raises the caption and its floor (the band rides it) by the cover
    /// line's lift, and the whole column by its own (#2326), so its bottom
    /// stands on the caption's letters' line.
    private func applySeat() {
        let lift = currentCoverLineLift
        let captionBottom: CGFloat = -(SnapActionColumn.inputRestingGap + lift)
        var changed = false
        if captionOnCoverLine?.constant != captionBottom {
            captionOnCoverLine?.constant = captionBottom
            captionFloorBottom?.constant = -(Spacing.xl + lift)
            changed = true
        }
        if applyColumnSeat() { changed = true }
        // The glide is a share of the column's lift, which may have changed.
        actionColumn.applyColumnGlide()
        if changed { setNeedsLayout() }
    }

    #if DEBUG
    /// How far the column stands below its resting seat right now (#2326).
    var debugColumnGlide: CGFloat { glassColumn.transform.ty }
    /// The column's lift at rest, as this chrome stands.
    var debugColumnLineLift: CGFloat { currentColumnLineLift }
    #endif

    /// The caption block's height on a media page (#2252): two caption lines,
    /// rounded up to this screen's pixels — the height the label takes for
    /// two lines, so the floor never stretches a real two-line block.
    private var captionBlockHeight: CGFloat {
        let scale: CGFloat = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        return SnapChromeGeometry.captionBlockHeight(scale: scale)
    }

    /// Tracks the settled top margin into the rail's cell-relative top.
    /// Mid-flight safe-area churn (which can push the margin far past any
    /// real nav-bar clearance) is rejected, so the rail's frame — and with
    /// it the wheel's scroll geometry — holds still while the page rides a
    /// transition. Settled updates (initial layout, the flight replica's
    /// captured insets, trait changes) pass through.
    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        let top = layoutMargins.top
        guard top <= Self.maxSettledTopMargin else { return }
        railTopConstraint?.constant = top + Spacing.sm
    }

    // MARK: - Configuration

    /// This chrome is a flight's replica: its shortcut rail shows its emotes
    /// during the flight, still, where the live page's sits it out (#2004).
    func markAsFlightReplica() {
        shortcutRail.isFlightReplica = true
    }

    func configure(with model: FeedItemDisplayModel) {
        let isSamePost = representedID == model.id
        representedID = model.id

        // Text-only posts drop the MEDIA comment surfaces — the danmaku
        // ticker, the subtitle zone, the empty-state floor, the scrim over
        // the (absent) media — since those overlay a full-bleed image the
        // page doesn't have. The reactions RAIL is still format-agnostic
        // chrome (seeded on every post type below); the "+" that rides it
        // is not — see its assignment.
        hasMedia = model.mediaURL != nil
        // ⚠️ THE CAPTION'S GEOMETRY AT CONFIGURE, never at a page count
        // (#1724: the flight replica of a single picture never gets one, and
        // the caption jumped at the landing). Since #2252 there is one seat;
        // what configure decides is the two-line floor — a media page's
        // block is two lines tall, a text page draws no caption.
        captionBlockFloor?.constant = captionBlockHeight
        captionBlockFloor?.isActive = hasMedia
        // Each page's declared shape, for the scrub card (#1724).
        mediaStrip.pageAspects = model.mediaPages.enumerated().map { index, page in
            CGFloat(index == 0 ? (model.headAspectRatio ?? page.aspectRatio) : page.aspectRatio)
        }
        // ⚠️ THE CHROME CARRIES ITS OWN THEME (#683). The live cell's content
        // view is themed when it joins a window, and the hero flight's
        // replica never was: the like pill and the sound bubble flew as LIGHT
        // glass with dark ink, and turned dark at the landing — while the
        // toolbar, themed already, was white from the first frame.
        overrideUserInterfaceStyle = SnapChromeTheme.style(hasMedia: hasMedia)
        actionColumn.applyColumnStyle()
        scrimView.isHidden = !hasMedia
        // Set the timestamp before the caption so the caption's didSet
        // composes with both already in hand.
        timestampText = hasMedia ? model.timestampText : nil
        // A media post with no caption still draws its date, alone on the
        // block's second line (#2252): the caption is then empty, not absent.
        caption = hasMedia ? (model.caption ?? "") : nil
        applyCaptionVisibility()
        actionColumn.configure(with: model)
        if !hasMedia {
            commentTicker.setComments([])
            subtitleView.setCues([])
            commentEmptyState.setVisible(false)
        }
        // The band's space, from what the card already knows (charter P9):
        // a count above zero reserves it, an unknown count reserves it too
        // (a collapse on "none" is rarer than a jump on "some"), zero does
        // not. The bubbles fade into it when the streams land.
        let knownComments = model.cardMetrics?.comments
        commentTicker.setReservesBand(hasMedia && (knownComments ?? 1) > 0)
        // The reactions rail is seeded for EVERY post — the shared action
        // column. Static chrome, so it loads here (not via
        // `updateCommentStreams`) and the flight replica shows it too; the
        // seeded payload keeps both instances identical.
        shortcutRail.setEmotes(SnapShortcutRailView.payload(for: model.id), keepingIfUnchanged: isSamePost)
        applyCareMode()
    }

    /// Care Mode (#482) keeps the page calmer: the emote shortcuts go. A
    /// hidden view keeps its frame, so the subtitle slot that stops at the
    /// rail's leading edge doesn't move. Re-read when the chrome joins a
    /// window, which is how a change made in Settings reaches a feed that
    /// was already on screen.
    private func applyCareMode() {
        shortcutRail.isHidden = CareModePreference.isOn
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyCareMode() }
    }

    /// The raw caption, kept so Dynamic Type changes can re-resolve the
    /// attributed rendering (the font is baked into the string).
    private var caption: String? {
        didSet { renderCaption() }
    }

    /// The post's age ("7 weeks"), composed onto the caption under the
    /// strict two-line contract (see `composedCaption`). Kept raw so Dynamic
    /// Type and width changes can re-resolve the composed rendering.
    private var timestampText: String? {
        didSet { renderCaption() }
    }

    /// The label width the current caption rendering was composed for. The
    /// two-line + timestamp layout is WIDTH-dependent (line counts and the
    /// truncation point both move with it), so `layoutSubviews` re-renders
    /// whenever the label's width changes — rotation, iPad, or the flight
    /// replica's first real layout — and skips when it hasn't.
    private var lastRenderedCaptionWidth: CGFloat = 0

    /// Hidden on a text page only (#2252): a media page with no caption shows
    /// its date on line two, the line above it left empty.
    private func applyCaptionVisibility() {
        let date = timestampText ?? ""
        captionLabel.isHidden = caption == nil || (caption?.isEmpty == true && date.isEmpty)
    }

    /// Whether the represented post carries media. Text-only posts show an
    /// empty shell, so this gates page content — including ticker queues
    /// arriving *after* configure (`updateTickerComments`).
    private(set) var hasMedia = true {
        didSet { if hasMedia != oldValue { applySeat() } }
    }

    private func renderCaption() {
        lastRenderedCaptionWidth = captionLabel.bounds.width
        captionLabel.attributedText = caption.map {
            SnapCaptionComposer.composedCaption($0, timestamp: timestampText, width: captionLabel.bounds.width)
        }
    }

    /// See `SnapChromeCommentSurfaces.updateCommentStreams` (live cells only).
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) { commentSurfaces.updateCommentStreams(streams) }


    private var hasLaidOut = false

    #if DEBUG
    /// The band's and the stream's frames in this chrome's space.
    var debugBandFrame: CGRect { commentTicker.frame }
    var debugBandTrailingEnd: (cornerRadius: CGFloat, fadeLocations: [NSNumber]?) {
        commentTicker.debugTrailingEnd
    }
    var debugStreamFrame: CGRect { subtitleView.frame }
    var debugRailFrame: CGRect { shortcutRail.frame }
    /// The wheel, which rides the column's layer (#1872).
    var debugShortcutRail: SnapShortcutRailView { shortcutRail }
    #endif

    #if DEBUG
    /// The caption's frame in `space`, for the landing probe that compares
    /// the flight replica with the page it fades into.
    func debugCaptionFrame(in space: UICoordinateSpace) -> CGRect {
        captionLabel.convert(captionLabel.bounds, to: space)
    }
    #endif

    /// See `SnapChromeMediaStrip.setMediaPageCount` — the flight replica's too.
    func setMediaPageCount(_ count: Int, current: Int, clipPages: Set<Int> = []) {
        mediaStrip.setMediaPageCount(count, current: current, clipPages: clipPages)
    }

    /// Where the page's BOTTOM READOUT begins — the top of the comment band.
    ///
    /// The media's floor, and the boundary a tap on the picture stops at: below
    /// this line the page is talking ABOUT the post (ticker, caption, page
    /// strip, bar) and a touch belongs to whatever it lands on.
    ///
    /// ⚠️ Read off the band whether or not it is showing anything. The ticker's
    /// box is reserved on every format — that is what makes this corner
    /// format-agnostic (see `captionFloorGuide`) — so taking its position
    /// rather than its visibility keeps the floor still on a post that has no
    /// comments yet, and keeps it in the same place when the first one lands.
    ///
    /// ⚠️ AND IT IS THE SAME LINE ON EVERY FORMAT NOW. It used to rise for a
    /// gallery, whose page dots hung above the band; the strip that replaced
    /// them lives under the caption, well below this, so a collection's picture
    /// is as tall as any other's.
    var bottomReadoutTop: CGFloat { commentTicker.frame.minY }

    #if DEBUG
    /// The page strip and the caption, so a spec can state where the strip sits
    /// in the column — and that its arrival moves nothing else.
    var debugPageBarFrame: CGRect { mediaPageBar.frame }
    /// The action column's two bubbles, for the spec that
    /// holds them still across the media and comments layouts.
    var debugBoostButton: UIButton { boostButton }
    var debugSoundBubble: SnapSoundBubbleButton { soundBubble }
    var debugSoundHold: HoldToArmPresenter? { actionColumn.soundHold }
    /// The glass column's items, shape by shape, as the column stands them
    /// now (#1872).
    var debugColumnItems: [[String]] { actionColumn.columnSlots().map { $0.map(\.id) } }
    var debugGlassColumn: SnapGlassColumn { glassColumn }
    /// `view`'s frame in this chrome's space — a column item stands in its
    /// bubble's glass, not in the chrome (#1872).
    func debugFrame(of view: UIView) -> CGRect { view.convert(view.bounds, to: self) }
    /// The sound's station, shown or not — where its bubble stands.
    var debugSoundStationFrame: CGRect { soundStation.convert(soundStation.bounds, to: self) }
    /// The comment band, in the chrome's space.
    var debugTickerFrame: CGRect { commentTicker.frame }
    /// The comment band and the subtitle pill themselves (#1798).
    var debugCommentTicker: SnapCommentTickerView { commentTicker }
    var debugSubtitleView: SnapSubtitleView { subtitleView }
    var debugCaptionFrame: CGRect { captionLabel.frame }
    var debugPageBar: SnapMediaPageBarView { mediaPageBar }
    #endif

    /// Everything on the page that is ABOUT the post rather than part of the
    /// instrument in the viewer's hand.
    ///
    /// ⚠️ THE STRIP AND ITS CARD ARE NOT IN HERE, and neither is the scrim.
    /// The first two are what the thumb is holding; the third is not content
    /// at all but the wash that keeps white legible over a photograph, and
    /// taking it away would brighten the picture under the very thing the
    /// viewer is reading.
    ///
    /// The two TOOLBARS are not here either, and cannot be: they belong to the
    /// screen rather than to this view. That is the right answer as well as
    /// the available one — the way out of a post should not blink away because
    /// a thumb landed on a clip's bar.
    ///
    var scrubFadedViews: [UIView] {
        // The column fades as one glass (#1872): its bubbles' glass would
        // stay behind the buttons' faded faces.
        [captionLabel, commentTicker, subtitleView, commentEmptyState, shortcutRail, glassColumn]
    }

    /// The image pipeline the comment surfaces load author avatars through —
    /// forwarded to the ticker and the subtitle zone (both render an avatar
    /// leading their comment content). Set at configure, before any stream
    /// arrives via `updateCommentStreams`.
    func setImagePipeline(_ pipeline: ImagePipeline) {
        imagePipeline = pipeline
        commentTicker.setImagePipeline(pipeline)
        subtitleView.setImagePipeline(pipeline)
    }

    /// The comments engagement's chrome cut: fades EVERY page surface —
    /// the comment surfaces, the scrim, the caption, and the shortcut rail
    /// with its "+" anchor. The caption's is a synchronous in-place
    /// cross-fade against the engaged caption's own fade, no geometric
    /// flight. Alpha, not isHidden, so a single animation block drives both
    /// directions; alpha < 0.01 also removes the faded surfaces from
    /// hit-testing, so the entry pill can't re-fire mid-engagement.
    ///
    /// The rail used to be the one survivor, floating over the comments
    /// region through both states. It reserved a trailing column the stream
    /// then had to inset around, and it collided with the composer's own
    /// trailing controls — two problems that both dissolve now that the
    /// engaged layout owns the full width.
    func setCommentsEngaged(_ engaged: Bool) {
        setCommentsEngagedProgress(engaged ? 0 : 1)
    }

    /// The same fade, INTERPOLATED: 0 = fully engaged (comment surfaces
    /// hidden), 1 = fully resting (all of them back). The interactive
    /// pull-down dismissal drives this continuously, so the ticker and the
    /// caption return under the finger instead of appearing at the end.
    /// The last progress seen, kept ONLY to spot the return to rest — the
    /// empty state's reading beat restarts on it. It used to double as the
    /// alpha the pill settled at; that coupling is gone with the container
    /// fade, but the EDGE it detected is still needed.
    private var lastEngagedProgress: CGFloat = 1

    func setCommentsEngagedProgress(_ progress: CGFloat) {
        // ONE LAYER, not seven — and under Core Animation that is one
        // animation object instead of seven.
        //
        // Every view this chrome owns fades together on the same curve: the
        // scrim, the caption, the band, the subtitle zone, the empty-state
        // floor, the rail and its "+". Fading each was seven properties
        // describing one intention. Equivalent by construction, not by luck —
        // this view holds nothing that stays visible while engaged, so a
        // container fade cannot catch a member by mistake. Hit-testing agrees:
        // below 0.01 UIKit skips the whole chrome, where before it skipped
        // each surface, and the engaged state wants exactly that.
        let resolved = min(max(0, progress), 1)
        // Landing back ON 1 from anywhere below it is the RETURN to the
        // resting page — the one seam both dismissal paths share. The empty
        // state reads its words out again from full strength, because closing
        // the comments is the moment a viewer has most recently asked about
        // them. Guarded on the TRANSITION, so a pull that springs back part
        // way without ever reaching 1 re-arms nothing.
        let returnedToRest = resolved >= 1 && lastEngagedProgress < 1
        lastEngagedProgress = resolved
        alpha = resolved
        // The wheel fades with the chrome.
        railLayer.alpha = resolved
        // The column glides to the composer's line on the same progress
        // (#2326) — on the same curve inside the engagement's spring.
        actionColumn.engagementColumnShare = 1 - resolved
        actionColumn.applyColumnGlide()
        shortcutRail.capsule.layout()
        if returnedToRest { commentEmptyState.restartLabelDwell() }
    }

    // MARK: - The action column (#695)

    /// Moves the whole overlay down by `offset` — the side list's pose
    /// (#1509) — the action column included (#1549): mounted in the cell's
    /// content, outside this view, it does not ride this view's transform,
    /// and the like pill and the sound bubble stayed behind.
    func setOverlayOffset(_ offset: CGFloat) {
        let shift = offset == 0 ? CGAffineTransform.identity : CGAffineTransform(translationX: 0, y: offset)
        transform = shift
        if columnLayer.superview !== self { columnLayer.transform = shift }
    }

    /// The action column's own shift. Tests.
    var debugActionColumnOffset: CGFloat {
        columnLayer.superview === self ? transform.ty : columnLayer.transform.ty
    }

    /// See `SnapChromeCommentSurfaces.setSubtitlesActive`.
    func setSubtitlesActive(_ active: Bool) { commentSurfaces.setSubtitlesActive(active) }

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
        // ⚠️ AND A SCRUB IN FLIGHT GIVES ITS ALPHAS BACK FIRST. A gesture does
        // not have to end for a cell to be recycled — the post can be swiped
        // away under the thumb — and the fade would otherwise be inherited by
        // the next post as a caption and a band that never come back. The same
        // trap as the line below, one gesture further in. Unanimated: there is
        // nothing on screen to dissolve, and the next configure is immediate.
        mediaStrip.setScrubFocus(false, animated: false)
        // …and a browse in flight takes its previews with it (#1734).
        mediaStrip.browseStrip.hide(animated: false)
        // A scaffold handed the next post while still faded would keep that
        // post's chrome invisible.
        alpha = 1
        railLayer.alpha = 1
        lastEngagedProgress = 1
        // The column back on its resting seat (#2326).
        actionColumn.engagementColumnShare = 0
        actionColumn.sheetColumnShare = 0
        actionColumn.applyColumnGlide()
        caption = nil
        applyCaptionVisibility()
        onCommentsTapped = nil
        onBoostRequested = nil
        onBoostUndoRequested = nil
        hasMedia = true
        commentTicker.reset()
        actionColumn.reset()
        subtitleView.reset()
        // Both, and in this order: `setActive(false)` clears the visibility
        // seam the scaffold arrived with (the cell's streaming flag is not
        // guaranteed to have been lowered), so the NEXT zero-comment post
        // starts its label's reading dwell when it is actually looked at
        // rather than the instant its stream lands.
        commentEmptyState.setActive(false)
        commentEmptyState.setVisible(false)
        shortcutRail.reset()
    }

    // MARK: - Boost feedback

    /// The like pill's receipts for a spend (#2521).
    private(set) lazy var boostReceipts = SnapBoostReceipts(host: self)

    /// See `SnapChromeActionColumn` — the flight replica's too.
    func setBoostTotal(_ total: Int, animated: Bool = false) { actionColumn.setBoostTotal(total, animated: animated) }
    func setPostLikeCount(_ count: Int64?) { actionColumn.setPostLikeCount(count) }

    #if DEBUG
    /// The like pill's transform — identity, always (#1186).
    var debugBoostButtonTransform: CGAffineTransform { boostButton.transform }
    /// The count under the pill's heart — nil while the pill is not showing.
    var debugLikeBadgeText: String? { boostButton.isHidden ? nil : boostButton.configuration?.title }
    /// Where the heart is drawn, in the chrome's space.
    ///
    /// ⚠️ THE GLYPH, centred in its image view, which stands taller than the
    /// picture it shows (~2 pt above and below the heart). Read off the
    /// view, the gaps looked even only while the button was measured half
    /// laid out — at its title's width, the heart off centre; fully laid out
    /// in the column's glass (#1872), the view's padding showed.
    var debugLikeHeartFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let image = boostButton.imageView else { return .zero }
        let frame = image.convert(image.bounds, to: self)
        guard let drawn = image.image?.size, drawn.height > 0, drawn.height < frame.height else { return frame }
        return frame.insetBy(dx: 0, dy: (frame.height - drawn.height) / 2)
    }
    /// Where the count is drawn, in the chrome's space.
    var debugLikeBadgeFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let label = boostButton.titleLabel else { return .zero }
        return label.convert(label.bounds, to: self)
    }
    #endif
}

extension SnapChromeView: SnapBoostReceiptsHost {}

extension SnapChromeView: SnapChromeCommentSurfacesHost {}

extension SnapChromeView: SnapChromeMediaStripHost {}

extension SnapChromeView: SnapChromeActionColumnHost {}
