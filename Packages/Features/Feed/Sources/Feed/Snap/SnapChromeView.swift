import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// The snap *page's* UI chrome — the caption over the bottom scrim.
/// Screen-scoped chrome (back item, author identity) lives in the navigation
/// bar instead (`SnapAuthorIdentityView` / `SnapNavControls`), so it stays
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
    /// The bottom legibility scrim. The mid-stop pulls meaningful darkness up
    /// behind the comment ticker's lanes — the band's naked text has no
    /// capsules, so the scrim is its only contrast — while the bottom stays
    /// as dark as before under the caption and toolbar.
    private let scrimView = GradientView(
        colors: [.clear, UIColor.black.withAlphaComponent(0.45), UIColor.black.withAlphaComponent(0.75)],
        locations: [0, 0.55, 1]
    )

    private let captionLabel = UILabel()

    /// The danmaku band, floating over the media directly above the caption.
    /// Content reaches it only through `updateCommentStreams` — never through
    /// `configure` — so the flight replica renders an empty, invisible band
    /// by construction and the card stays pixel-identical to the landed page.
    private let commentTicker = SnapCommentTickerView()
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
    private let mediaPageBar = SnapMediaPageBarView()

    /// The subtitle zone, directly above the band: a persistent pill of
    /// semantic comments, one at a time, with the count bubble leading it.
    /// Same content contract as the band (arrives only via
    /// `updateCommentStreams`, so the flight replica's zone is empty by
    /// construction) and the same visibility-scoped activation, so the
    /// zone rides a page being dragged in.
    private let subtitleView = SnapSubtitleView()

    /// The comments empty state: a static "No comments yet" pill occupying
    /// the band's slot when the post is KNOWN to have zero comments — the
    /// one case where every comment surface above legitimately gates itself
    /// away and the zone would otherwise read as unexplained blank space.
    /// Same content contract as the band and the zone (visible only via
    /// `updateCommentStreams`, on a loaded stream), so the flight replica
    /// never shows it.
    private let commentEmptyState = SnapCommentEmptyStateView()

    /// The vertical shortcut wheel on the trailing edge: quick-react
    /// shortcuts (placeholder symbols today, favorite GIFs later), spanning
    /// the ticker's top up to the nav bar. Static content like the caption —
    /// populated from `configure` with a per-post deterministic payload, so
    /// the flight replica draws the identical wheel.
    private let shortcutRail = SnapShortcutRailView()
    /// The fixed boost affordance: a Liquid Glass circle filling the
    /// square where the rail overlaps the ticker band (diameter == the
    /// band's height), the zone's ONLY layer — the old frosted backdrop
    /// chip was removed in its favor. A chrome sibling ABOVE the rail
    /// (never a scroll subview), so it holds still while emotes scroll —
    /// and escapes the rail's edge-fade mask, which would otherwise
    /// dissolve it. The rail reserves its bottom strip
    /// (`bottomReservedInset`) so nothing settles behind it; the band's
    /// bubbles are born under this glass and slide out of its seam.
    /// Present on every MEDIA page and no text page — set from `configure`,
    /// never from the stream (see there for why the band's hidden state is
    /// the wrong authority for it).
    private let boostButton = SnapRailBoostButton()
    /// The rail's top edge as a cell-relative constant (see `buildLayout`).
    /// Optional: margins change during `init` before the layout exists.
    private var railTopConstraint: NSLayoutConstraint?
    /// The subtitle zone's two bottom seats — stacked ON the band, or in the
    /// band's own seat when it isn't rendering. Exactly one is ever active;
    /// `applyBandPresence` is the only thing that switches them.
    private var subtitleAboveBandConstraint: NSLayoutConstraint?
    private var subtitleInBandSeatConstraint: NSLayoutConstraint?
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
    var interactionRoots: [UIView] { [shortcutRail, boostButton, commentEmptyState, subtitleView, commentTicker] }

    /// A comments surface was tapped (empty-state pill, subtitle zone, or
    /// ticker band — one fan-in, one path) — the cell forwards this as a
    /// comments-engagement request with its post identity attached.
    var onCommentsTapped: (() -> Void)?

    /// The rail's boost anchor asked to spend `amount` points on this post
    /// (tap = the default denomination, long-press menu = a chosen one).
    /// The cell forwards it with the post identity attached; whether the
    /// wallet can afford it is the OWNER's answer, which comes back through
    /// `playBoostConfirmation` / `playBoostDenied`.
    var onBoostRequested: ((Int) -> Void)?
    /// The anchor's menu asked to take back the session's spend on this
    /// post. Same fan-out as the spend: cell attaches the identity, the
    /// owner does the refund and answers with `playBoostRefund`.
    var onBoostUndoRequested: (() -> Void)?

    private var representedID: PostID?



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
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapChromeView, _) in
            self.captionFloorHeightConstraint?.constant = Self.captionFloorHeight
            self.renderCaption()
        }

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The chrome is an overlay CANVAS: only its subviews are touchable.
    /// Bare-canvas hits fall through to whatever lies beneath — the media
    /// (play/pause), or the engaged comments region (whose inner list must
    /// scroll; a full-cell chrome above it would otherwise swallow every
    /// drag and hand it to the pager, which is exactly the bug this fixed).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func buildLayout() {
        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: self) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            // 0.68 (was 0.62 pre-subtitles): tall enough that the gradient's
            // mid-stop sits behind the subtitle zone AND the ticker band
            // stacked above the caption block.
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.68)
        }

        // Caption, full-width over the scrim (the engagement rail that once
        // reserved the trailing edge is gone). The margins guide tracks the
        // safe area, so when the navigation controller's toolbar is visible
        // the caption sits above it automatically — live cell and flight
        // replica alike (`setFixedInsets` captures the toolbar-inflated
        // insets). The bottom gap is one token up from the sides (xl vs
        // lg): the caption is the stack's last line before the toolbar
        // band, and the seam between page content and bar chrome carries
        // the harmonized rhythm's largest breath.
        captionLabel.constrain(in: self) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg)
            captionLabel.bottomAnchor.constraint(equalTo: parent.layoutMarginsGuide.bottomAnchor, constant: -Spacing.xl)
            captionLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.lg)
        }

        // The caption FLOOR: a zero-content region co-located with the
        // caption label (same bottom, same horizontal margins) but with a
        // FIXED two-line height, present on every format. The ticker/rail/"+"
        // corner hangs off THIS guide's top, not the label's — so a text-only
        // post's empty (collapsed) label can't let the corner sink into the
        // input bar, and the corner's position is a pure font constant,
        // pixel-identical whether the post is video, photo, or text.
        addLayoutGuide(captionFloorGuide)
        let floorHeight = captionFloorGuide.heightAnchor.constraint(equalToConstant: Self.captionFloorHeight)
        captionFloorHeightConstraint = floorHeight
        NSLayoutConstraint.activate([
            captionFloorGuide.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor),
            captionFloorGuide.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor),
            captionFloorGuide.bottomAnchor.constraint(equalTo: captionLabel.bottomAnchor),
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
            commentTicker.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.md - 0.5)
            // md, not sm: the band and the caption are separate CONTAINERS
            // in the bottom stack — inter-container seams breathe at md in
            // the harmonized rhythm (sm stays the WITHIN-container gap).
            // Off the caption FLOOR (not the label): the fixed two-line
            // reservation is what makes this corner format-agnostic — a
            // collapsed text-only caption reserves the same box a two-line
            // media caption fills, so the band never sinks toward the bar.
            commentTicker.bottomAnchor.constraint(equalTo: captionFloorGuide.topAnchor, constant: -Spacing.md)
        }

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
        // Pinned to the BOTTOM of the margins guide — the line the toolbar
        // rests against — so it sits in the band between the caption and the
        // bar without moving either. The caption keeps the position it has on
        // every other format; a post with one picture simply has nothing here.
        mediaPageBar.constrain(in: self) { parent in
            mediaPageBar.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor)
            mediaPageBar.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor)
            mediaPageBar.bottomAnchor.constraint(equalTo: parent.layoutMarginsGuide.bottomAnchor)
            mediaPageBar.heightAnchor.constraint(equalToConstant: SnapMediaPageBarView.thickness)
        }


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
        let railTop = shortcutRail.topAnchor.constraint(
            equalTo: topAnchor, constant: layoutMargins.top + Spacing.sm
        )
        railTopConstraint = railTop
        shortcutRail.constrain(in: self) { parent in
            shortcutRail.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.md)
            shortcutRail.widthAnchor.constraint(equalTo: commentTicker.heightAnchor)
            railTop
            shortcutRail.bottomAnchor.constraint(equalTo: commentTicker.bottomAnchor)
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
        boostButton.onBoost = { [weak self] amount in self?.onBoostRequested?(amount) }
        boostButton.onUndo = { [weak self] in self?.onBoostUndoRequested?() }
        // The anchor is fully framed from outside (band edges + margins);
        // its intrinsic content size must exert ZERO back-pressure on the
        // graph — floor priorities mean it can never squeeze the band or
        // stretch itself (the other half of the height-authority contract).
        boostButton.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        boostButton.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        boostButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
        boostButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        boostButton.constrain(in: self) { parent in
            boostButton.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.md)
            boostButton.widthAnchor.constraint(equalTo: commentTicker.heightAnchor)
            boostButton.topAnchor.constraint(equalTo: commentTicker.topAnchor)
            boostButton.bottomAnchor.constraint(equalTo: commentTicker.bottomAnchor)
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
            subtitleView.trailingAnchor.constraint(equalTo: shortcutRail.leadingAnchor, constant: -Spacing.md)
        }
        // The zone's bottom has TWO seats, and which one it takes is the
        // band's presence (`applyBandPresence`).
        //
        // A hidden UIView still occupies its frame, so stacking the zone on
        // the band's top edge left a band-height hole under the pill on
        // every page the band declines — which is now most of them, since
        // the zone speaks for sparse posts. The band's height cannot simply
        // collapse: it is the engagement corner's HEIGHT AUTHORITY (the "+"
        // pins to its top and bottom edges, the rail's width and reserved
        // strip derive from it), so shrinking it would take the whole
        // trailing column with it.
        //
        // So the band keeps its frame and the ZONE moves instead: with no
        // band it drops into the band's own seat, one md above the caption
        // floor — the same slot the empty-state pill occupies, so all three
        // comment surfaces render at one position and the corner never
        // shows a gap it isn't using.
        //
        // Both seats are md off their reference — the same inter-container
        // seam as band→caption, so the stack keeps one breathing rhythm
        // either way.
        let aboveBand = subtitleView.bottomAnchor.constraint(
            equalTo: commentTicker.topAnchor, constant: -Spacing.md
        )
        let inBandSeat = subtitleView.bottomAnchor.constraint(
            equalTo: captionFloorGuide.topAnchor, constant: -Spacing.md
        )
        subtitleAboveBandConstraint = aboveBand
        subtitleInBandSeatConstraint = inBandSeat
        aboveBand.isActive = true

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
            // md: it stands in the band's seat, so it keeps the band's
            // harmonized seam against the caption.
            commentEmptyState.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
        }
        commentEmptyState.onTap = { [weak self] in self?.onCommentsTapped?() }
        subtitleView.onTap = { [weak self] in self?.onCommentsTapped?() }
        commentTicker.onTap = { [weak self] in self?.onCommentsTapped?() }
    }

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
        shortcutRail.bottomReservedInset = commentTicker.bounds.height

        // The caption's two-line/timestamp composition is width-dependent —
        // re-resolve it once the label has a (new) real width. Guarded on the
        // width so the re-render (which invalidates layout) converges in one
        // extra pass instead of looping.
        if captionLabel.bounds.width != lastRenderedCaptionWidth {
            renderCaption()
        }

        let top = layoutMargins.top
        guard top <= Self.maxSettledTopMargin, commentTicker.frame.maxY > 0 else { return }
        let base = top + Spacing.sm
        let fixedZones = SnapShortcutRailView.restingWindowHeight
            + SnapShortcutRailView.edgeFadeLength
            + commentTicker.bounds.height
        let headroom = commentTicker.frame.maxY - base - fixedZones
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
        insetsLayoutMarginsFromSafeArea = false
        layoutMargins = insets
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

    func configure(with model: FeedItemDisplayModel) {
        representedID = model.id

        // Text-only posts drop the MEDIA comment surfaces — the danmaku
        // ticker, the subtitle zone, the empty-state floor, the scrim over
        // the (absent) media — since those overlay a full-bleed image the
        // page doesn't have. The reactions RAIL is still format-agnostic
        // chrome (seeded on every post type below); the "+" that rides it
        // is not — see its assignment.
        hasMedia = model.mediaURL != nil
        scrimView.isHidden = !hasMedia
        // Set the timestamp before the caption so the caption's didSet
        // composes with both already in hand.
        timestampText = hasMedia ? model.timestampText : nil
        caption = hasMedia ? model.caption : nil
        applyCaptionVisibility()
        // THE BOOST ANCHOR IS FORMAT-SCOPED, NOT STATE-SCOPED — the rule the
        // compose "+" that held this slot established. Every media page owns
        // it from its first frame; its predecessor used to mirror the
        // ticker's hidden state (`updateCommentStreams`), which meant it
        // vanished on every page the band declined to animate: zero-comment
        // posts, the sparse seed, and any page at all under Reduce Motion —
        // the anchor disappearing where it was most useful.
        //
        // Text-only pages keep it hidden. Their engagement is a permanent
        // resting state with its own composer bar, and that bar carries its
        // OWN boost button — so the anchor here would be a second spend
        // control for one post; setting it here rather than leaving the
        // engagement's fade to swallow it also kills the flash it used to
        // make in the frames before that engagement mounts.
        //
        // Owned by `configure` (static chrome, like the rail's symbols), so
        // it needs no stream to appear and the flight replica — which never
        // receives one — draws the identical corner.
        boostButton.isHidden = !hasMedia
        if !hasMedia {
            commentTicker.setComments([])
            subtitleView.setCues([])
            commentEmptyState.setVisible(false)
        }
        // Every configure, not just the text branch: a recycled scaffold
        // arrives seated for the PREVIOUS post's band, and a media page
        // whose stream hasn't landed yet has no band either.
        applyBandPresence()
        // The reactions rail is seeded for EVERY post — the shared action
        // column. Static chrome, so it loads here (not via
        // `updateCommentStreams`) and the flight replica shows it too; the
        // seeded payload keeps both instances identical.
        shortcutRail.setSymbols(SnapShortcutRailView.placeholderPayload(for: model.id))
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

    private func applyCaptionVisibility() {
        captionLabel.isHidden = caption?.isEmpty ?? true
    }

    /// Whether the represented post carries media. Text-only posts show an
    /// empty shell, so this gates page content — including ticker queues
    /// arriving *after* configure (`updateTickerComments`).
    private var hasMedia = true

    private func renderCaption() {
        lastRenderedCaptionWidth = captionLabel.bounds.width
        captionLabel.attributedText = caption.map {
            Self.composedCaption($0, timestamp: timestampText, width: captionLabel.bounds.width)
        }
    }

    /// The caption typography — the shared attributes for the caption glyphs
    /// (`.body`) and, for `secondary`, the appended timestamp: a SMALLER
    /// `.footnote` register, dimmed, so it reads as clean secondary metadata
    /// distinctly lighter than the body text (the same footnote register the
    /// engaged info card uses for the post age). Baked per-run so
    /// `boundingRect` measures each font's true footprint — the two-line
    /// truncation therefore accounts for the smaller timestamp automatically.
    /// The text shadow lives here (an `NSShadow` drawn WITH the glyphs)
    /// rather than as a `CALayer` shadow: a layer shadow on a full-width
    /// label has no `shadowPath` and costs an offscreen pass every scrolled
    /// frame.
    private static func captionAttributes(secondary: Bool) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return [
            .font: UIFont.preferredFont(forTextStyle: secondary ? .footnote : .body),
            .foregroundColor: secondary ? UIColor.white.withAlphaComponent(0.6) : UIColor.white,
            .shadow: shadow,
            // GEOMETRY LOCK: every line takes the PRIMARY (body) line height —
            // identical on every run — so a line holding only the smaller
            // footnote timestamp (Case A's second line) still occupies a full
            // body line. The caption block is therefore exactly two body
            // lines tall whether the timestamp sits inline or drops below,
            // and its bottom-pinned frame never shifts between states.
            .paragraphStyle: captionParagraphStyle,
        ]
    }

    /// The shared paragraph style baked into every caption run. It pins the
    /// line height to the body font's (min == max) so mixed-font lines can't
    /// collapse, and keeps WORD WRAPPING — never a truncating mode — because
    /// `boundingRect` refuses to wrap under `.byTruncating*` (it would report
    /// one line for any width), and `composedCaption` already fits the text
    /// to two lines by construction, so the label needs no truncation of its
    /// own.
    private static var captionParagraphStyle: NSParagraphStyle {
        let bodyLineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = bodyLineHeight
        paragraph.maximumLineHeight = bodyLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    /// The caption's locked box height — exactly TWO primary (body) lines,
    /// matching the composed caption's geometry lock. Reserved by
    /// `captionFloorGuide` on every format so the engagement corner (ticker /
    /// rail / "+") is anchored to a single font-derived constant, agnostic of
    /// whether the caption is a real two-line media caption or a collapsed
    /// text-only placeholder.
    static var captionFloorHeight: CGFloat {
        2 * UIFont.preferredFont(forTextStyle: .body).lineHeight
    }

    /// How many lines `string` occupies at `width` — the two-line contract's
    /// yardstick. A pure measurement (no label state), so `composedCaption`
    /// can probe candidate renderings before committing one.
    static func captionLineCount(_ string: NSAttributedString, width: CGFloat) -> Int {
        guard width > 0, string.length > 0 else { return 0 }
        // No `.usesFontLeading`: the caption's paragraph style already locks
        // every line box to the body line height, so the measured height is a
        // clean multiple of it — adding per-font leading would only reintroduce
        // the mixed-font variance the lock exists to remove.
        let height = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).height
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        return max(1, Int((height / lineHeight).rounded()))
    }

    /// The single source of caption typography for every media post and both
    /// chrome instances (live cell + flight replica) — a PURE function of
    /// (text, timestamp, width) so both resolve identically. It enforces a
    /// strict two-line contract with the timestamp always visible:
    ///
    ///   • Case A — a single-line caption drops the timestamp onto its OWN
    ///     second line (`caption\n7 weeks`).
    ///   • Case B — a caption that fills two lines takes the timestamp inline
    ///     at the end of line two (`…line two  7 weeks`).
    ///   • Case C — a longer caption truncates early on line two so the
    ///     ellipsis + timestamp always sit un-clipped at that line's end
    ///     (`…cut off here…  7 weeks`).
    ///
    /// With no timestamp (or an unmeasured zero width) it returns the bare
    /// caption — the label's own `numberOfLines`/truncation then applies.
    static func composedCaption(_ caption: String, timestamp: String?, width: CGFloat) -> NSAttributedString {
        let captionString = NSAttributedString(string: caption, attributes: captionAttributes(secondary: false))
        guard let timestamp, !timestamp.isEmpty, width > 0 else { return captionString }

        let timestampString = NSAttributedString(string: timestamp, attributes: captionAttributes(secondary: true))
        let gap = NSAttributedString(string: "  ", attributes: captionAttributes(secondary: false))

        // Case A: a single-line caption pushes the timestamp to its own line.
        if captionLineCount(captionString, width: width) <= 1 {
            let out = NSMutableAttributedString(attributedString: captionString)
            out.append(NSAttributedString(string: "\n", attributes: captionAttributes(secondary: false)))
            out.append(timestampString)
            return out
        }

        // Case B: the whole caption plus an inline timestamp still fits two lines.
        let inline = NSMutableAttributedString(attributedString: captionString)
        inline.append(gap)
        inline.append(timestampString)
        if captionLineCount(inline, width: width) <= 2 { return inline }

        // Case C: bisect for the longest caption prefix that keeps the
        // ellipsis + timestamp inside two lines (prefix length grows the
        // line count monotonically, so the largest fitting prefix is the
        // truncation point).
        let characters = Array(caption)
        func candidate(prefixLength: Int) -> NSAttributedString {
            let prefix = String(characters[0..<prefixLength])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let out = NSMutableAttributedString(
                string: prefix + "… ", attributes: captionAttributes(secondary: false)
            )
            out.append(timestampString)
            return out
        }
        var low = 0, high = characters.count, best = 0
        while low <= high {
            let mid = (low + high) / 2
            if captionLineCount(candidate(prefixLength: mid), width: width) <= 2 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return candidate(prefixLength: best)
    }

    /// Replaces both comment surfaces' content (the ticker's wrap-around
    /// queue and the subtitle zone's cue list). Live cells only — the flight
    /// replica must never receive this (moving/timed content cannot be
    /// pixel-identical across two instances), which is why it is not part of
    /// `configure`. Empty streams hide their surface. Text-only posts refuse
    /// content entirely (empty shell) — gated here, not at the callers, so
    /// every arrival path (dequeue pull, async push) hits the same wall.
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) {
        guard hasMedia else { return }
        commentTicker.setComments(streams.reactions)
        // Read AFTER the band has resolved its own hidden state — it also
        // stands down under Reduce Motion, which the queue alone wouldn't
        // tell us.
        applyBandPresence()
        subtitleView.setCommentCount(streams.commentCount)
        subtitleView.setCues(streams.subtitles)
        // THE COUNT IS THE WHOLE CONDITION (product rule 2026-08-08): no
        // comments → the pill; one or more → the comment stream speaks for
        // the post and the pill stays down. The zone is never blank on
        // either side of that line, and this view is not where that is
        // enforced — `SubtitleCommentBuilder` guarantees a non-empty cue
        // list for any post the band isn't already carrying, so "has
        // comments" and "the zone renders" cannot come apart. A count pill
        // ("2 comments") was tried in this slot as a stand-in for the
        // stream and removed; the stream itself is the answer.
        //
        // `isLoaded` is the load/zero seam: an unloaded stream carries a
        // zero count too, so without it the pill would flash on every page
        // while its fetch is in flight.
        commentEmptyState.setVisible(streams.isLoaded && streams.commentCount == 0)
    }

    /// Seats the subtitle zone against the band's RESOLVED visibility: on
    /// top of it when it renders, in its seat when it doesn't. Idempotent
    /// (no-ops when the seat is already right), and it deactivates before
    /// activating — both constraints live at once would be an unsatisfiable
    /// pair, not a preference.
    private func applyBandPresence() {
        let bandRenders = !commentTicker.isHidden
        guard subtitleAboveBandConstraint?.isActive != bandRenders else { return }
        if bandRenders {
            subtitleInBandSeatConstraint?.isActive = false
            subtitleAboveBandConstraint?.isActive = true
        } else {
            subtitleAboveBandConstraint?.isActive = false
            subtitleInBandSeatConstraint?.isActive = true
        }
        // Swapping `isActive` does not reliably flag this view for layout,
        // so a caller that lays out SYNCHRONOUSLY — the flight replica, and
        // any test — reads the previous seat's frames. The run loop hides
        // this; an explicit `layoutIfNeeded` does not.
        setNeedsLayout()
    }

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    /// How many media pages the post has, and which one is showing. A count
    /// below two hides the indicator — a readout for a single photograph is
    /// furniture answering a question nobody asked.
    func setMediaPageCount(_ count: Int, current: Int) {
        mediaPageBar.configure(count: count, current: current)
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
    var debugCaptionFrame: CGRect { captionLabel.frame }
    var debugPageBar: SnapMediaPageBarView { mediaPageBar }
    #endif

    /// Moves the mark as the viewer pages. Separate from the count because this
    /// runs on every scroll callback of a carousel under a finger.
    func setMediaPage(_ page: Int) {
        mediaPageBar.setCurrent(page)
    }

    /// The carousel's position in fractional pages, straight through to the
    /// strip: width and ink are read off it, so the strip reflows for the whole
    /// gesture rather than at the crossing. See `SnapMediaPageBarView`.
    func setMediaScrollPosition(_ position: CGFloat) {
        mediaPageBar.setPosition(position)
    }


    /// The viewer asked for a page by touching the indicator. The CELL owns the
    /// carousel, so the request travels out rather than the chrome reaching in.
    var onMediaPageRequested: ((Int) -> Void)? {
        get { mediaPageBar.onPageRequested }
        set { mediaPageBar.onPageRequested = newValue }
    }

    /// The indicator's scrub, passed up so the screen's own pans can yield to
    /// it. See `MediaPageIndicatorView.scrubGesture`.
    var mediaScrubGesture: UIGestureRecognizer { mediaPageBar.scrubGesture }

    func setTickerActive(_ active: Bool) {
        commentTicker.setActive(active)
    }

    /// The image pipeline the comment surfaces load author avatars through —
    /// forwarded to the ticker and the subtitle zone (both render an avatar
    /// leading their comment content). Set at configure, before any stream
    /// arrives via `updateCommentStreams`.
    func setImagePipeline(_ pipeline: ImagePipeline) {
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
        if returnedToRest { commentEmptyState.restartLabelDwell() }
    }

    /// Cycles while the owning cell is on screen — the band's visibility
    /// seam (plus the settle backstop for foregrounding), NOT playback's
    /// settle scope: the persistent pill is static content between
    /// handoffs, so it must ride a half-dragged page like the caption
    /// does instead of popping in after settle.
    func setSubtitlesActive(_ active: Bool) {
        subtitleView.setActive(active)
        // The empty state rides the same seam — its label's dwell is a
        // READING clock, so it starts when the page is actually on screen,
        // not when the stream lands on a cell still off in the pager.
        commentEmptyState.setActive(active)
    }

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
        // A scaffold handed the next post while still faded would keep that
        // post's chrome invisible.
        alpha = 1
        lastEngagedProgress = 1
        caption = nil
        applyCaptionVisibility()
        onCommentsTapped = nil
        onBoostRequested = nil
        onBoostUndoRequested = nil
        hasMedia = true
        commentTicker.reset()
        applyBandPresence()
        boostButton.isHidden = true
        boostButton.setSpentTotal(0)
        // Back to the unwired default (enabled, nothing undoable) — the
        // next configure pushes the real context.
        boostButton.setWalletContext(balance: .max, undoableAmount: 0)
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

    /// The viewer's cumulative spend on the represented post — flips the
    /// rail anchor between its glyph face (0) and its gold-number face.
    /// Owned by the cell's configurator (the chrome has no wallet); reset
    /// to 0 with the rest of the post state on reuse.
    func setBoostTotal(_ total: Int) {
        boostButton.setSpentTotal(total)
    }

    /// The anchor's wallet context: what the balance can still afford and
    /// how much of this post's spend is session-undoable — the enable state
    /// and the menu's live contents both derive from it.
    func setBoostContext(balance: Int, undoable: Int) {
        boostButton.setWalletContext(balance: balance, undoableAmount: undoable)
    }

    /// The spend's visible receipt: a gold "+N" born on the boost anchor
    /// that rises and dissolves, plus a quick press-bounce on the anchor
    /// itself. Pure theatre over state that already changed — the wallet
    /// debited synchronously before this runs, so the animation can be
    /// dropped (hidden anchor, mid-reuse) without the count going wrong.
    func playBoostConfirmation(amount: Int) {
        guard !boostButton.isHidden, boostButton.bounds.width > 0 else { return }

        let label = UILabel()
        label.text = "+\(amount)"
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
        label.textColor = .systemYellow
        // The scrim under it is a gradient, not a guarantee — the same
        // legibility shadow the nav glyphs wear over live media.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: boostButton.center.x, y: boostButton.frame.minY - Spacing.md)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        addSubview(label)

        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y -= 18
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y -= 26
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }

        // The anchor's own acknowledgement: a press-and-release dip, the
        // spring profile `MapAnnotationPop` uses for the same "it landed"
        // beat.
        boostButton.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(
            withDuration: 0.5, delay: 0,
            usingSpringWithDamping: 0.45, initialSpringVelocity: 4,
            options: [.allowUserInteraction]
        ) {
            self.boostButton.transform = .identity
        }
    }

    /// The refund's receipt: a cool "−N" that sinks and dissolves — the
    /// confirmation float mirrored, in the direction money leaves the post.
    /// White, not gold: gold is the earning color, and an undo is not a
    /// payout.
    func playBoostRefund(amount: Int) {
        guard !boostButton.isHidden, boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "−\(amount)"
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: boostButton.center.x, y: boostButton.frame.minY - Spacing.md)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        addSubview(label)
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y += 14
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y += 20
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    /// The refusal: a horizontal head-shake on the anchor — the wallet
    /// couldn't cover the spend, and nothing changed. Paired with the
    /// error haptic the owner fires; deliberately no floating label (a
    /// "-0" would read as a payout).
    func playBoostDenied() {
        guard !boostButton.isHidden else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 6, -4, 3, -1, 0]
        shake.duration = 0.4
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        boostButton.layer.add(shake, forKey: "boost.denied")
    }
}

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    init(colors: [UIColor],
         locations: [NSNumber]? = nil,
         startPoint: CGPoint = CGPoint(x: 0.5, y: 0),
         endPoint: CGPoint = CGPoint(x: 0.5, y: 1)) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.locations = locations
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-tunes the gradient's stop positions (the frost masks compute
    /// theirs from the engaged geometry at install time).
    func setLocations(_ locations: [NSNumber]) {
        gradientLayer.locations = locations
    }
}
