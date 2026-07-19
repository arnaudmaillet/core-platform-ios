import CoreModels
import DesignSystem
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
    /// The fixed compose affordance: a Liquid Glass circle filling the
    /// square where the rail overlaps the ticker band (diameter == the
    /// band's height), the zone's ONLY layer — the old frosted backdrop
    /// chip was removed in its favor. A chrome sibling ABOVE the rail
    /// (never a scroll subview), so it holds still while emotes scroll —
    /// and escapes the rail's edge-fade mask, which would otherwise
    /// dissolve it. The rail reserves its bottom strip
    /// (`bottomReservedInset`) so nothing settles behind it; the band's
    /// bubbles are born under this glass and slide out of its seam.
    /// Visibility mirrors the ticker's (no band → no anchor floating
    /// over bare media).
    private let composeButton = SnapRailComposeButton()
    /// The rail's top edge as a cell-relative constant (see `buildLayout`).
    /// Optional: margins change during `init` before the layout exists.
    private var railTopConstraint: NSLayoutConstraint?
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
    var interactionRoots: [UIView] { [shortcutRail, composeButton, commentEmptyState, subtitleView, commentTicker] }

    /// A comments surface was tapped (empty-state pill, subtitle zone, or
    /// ticker band — one fan-in, one path) — the cell forwards this as a
    /// comments-engagement request with its post identity attached.
    var onCommentsTapped: (() -> Void)?

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
        // reused cells can never show two different caption sizes.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapChromeView, _) in
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
            commentTicker.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
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

        // The fixed "+" fills 100% of the overlap square, above the rail:
        // emotes scroll (and rubber-band) beneath it while it holds still.
        // Skinned in the SYSTEM's Liquid Glass (materialized on window
        // attach — see `SnapRailComposeButton`); capsule on the square box
        // (width == the band's height) renders a perfect circle inscribed
        // in the zone — the zone's only layer, now that the frosted chip
        // is gone. Constrained off ticker + margins, exactly the bounds
        // the old backdrop occupied.
        composeButton.isHidden = true
        // The anchor is fully framed from outside (band edges + margins);
        // its intrinsic content size must exert ZERO back-pressure on the
        // graph — floor priorities mean it can never squeeze the band or
        // stretch itself (the other half of the height-authority contract).
        composeButton.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        composeButton.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        composeButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
        composeButton.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        composeButton.constrain(in: self) { parent in
            composeButton.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -Spacing.md)
            composeButton.widthAnchor.constraint(equalTo: commentTicker.heightAnchor)
            composeButton.topAnchor.constraint(equalTo: commentTicker.topAnchor)
            composeButton.bottomAnchor.constraint(equalTo: commentTicker.bottomAnchor)
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
            // md: same inter-container seam as band→caption — the three
            // stacked containers share one breathing rhythm.
            subtitleView.bottomAnchor.constraint(equalTo: commentTicker.topAnchor, constant: -Spacing.md)
        }

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
        // ticker, the subtitle zone, the scrim over the (absent) media —
        // since those overlay a full-bleed image the page doesn't have.
        // But the ACTION COLUMN (reactions rail + "+") is format-agnostic
        // chrome: it stays visible on every post type, exactly as the
        // engaged layout floats over it identically on all of them.
        hasMedia = model.mediaURL != nil
        scrimView.isHidden = !hasMedia
        caption = hasMedia ? model.caption : nil
        applyCaptionVisibility()
        if !hasMedia {
            commentTicker.setComments([])
            subtitleView.setCues([])
            commentEmptyState.setVisible(false)
            // The rail's "+" persists (media refines its visibility off
            // the ticker in `updateCommentStreams`, which text skips).
            composeButton.isHidden = false
        }
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

    private func applyCaptionVisibility() {
        captionLabel.isHidden = caption?.isEmpty ?? true
    }

    /// Whether the represented post carries media. Text-only posts show an
    /// empty shell, so this gates page content — including ticker queues
    /// arriving *after* configure (`updateTickerComments`).
    private var hasMedia = true

    private func renderCaption() {
        captionLabel.attributedText = caption.map(Self.renderedCaption)
    }

    /// The caption's attributed rendering — the single source of caption
    /// typography for every post kind and both chrome instances (live cell
    /// and flight replica); no caller may size it conditionally. The text
    /// shadow lives here (an `NSShadow` drawn with the glyphs) rather than
    /// as a `CALayer` shadow: a layer shadow on a full-width label has no
    /// `shadowPath` and costs an offscreen pass every scrolled frame.
    private static func renderedCaption(_ text: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ])
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
        // The "+" anchor exists exactly when the band beneath it does
        // (mirrors the ticker's own hidden state, Reduce Motion included) —
        // it must never float over bare media.
        composeButton.isHidden = commentTicker.isHidden
        subtitleView.setCommentCount(streams.commentCount)
        subtitleView.setCues(streams.subtitles)
        // KNOWN-zero only (`isLoaded` is the load/zero seam): an unloaded
        // stream keeps the zone blank — the empty state must never flash
        // while a fetch is in flight — and a sparse-but-nonzero post keeps
        // its deliberate quiet (the surfaces' engagement gates, not an
        // absence worth captioning).
        commentEmptyState.setVisible(streams.isLoaded && streams.commentCount == 0)
    }

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    func setTickerActive(_ active: Bool) {
        commentTicker.setActive(active)
    }

    /// How much trailing width the engaged comments content must reserve
    /// for the rail's exclusive column: from the rail's leading edge to the
    /// chrome's trailing edge, plus a breathing gap. Zero when the rail is
    /// hidden (text-only pages).
    var railExclusionWidth: CGFloat {
        guard !shortcutRail.isHidden, shortcutRail.frame.width > 0 else { return 0 }
        return max(0, bounds.width - shortcutRail.frame.minX) + Spacing.sm
    }

    /// The comments engagement's chrome cut: fades the comment surfaces
    /// and the scrim — the pieces the engaged layout replaces or orphans —
    /// while the SHORTCUT RAIL and its "+" anchor stay untouched (the
    /// blueprint keeps the whole vertical action column through both
    /// states; it floats over the comments region, and its touches keep
    /// winning via `interactionRoots` + the pager's rail veto). The "+"
    /// holds its native seat below the rail for visual continuity — it is
    /// RAIL territory, not ticker content, even though its frame borrows
    /// the ticker band's edges. The caption fades with the rest — a
    /// synchronous in-place cross-fade against the engaged caption's own
    /// fade, no geometric flight. Alpha, not isHidden, so a single
    /// animation block drives both directions; alpha < 0.01 also removes
    /// the faded surfaces from hit-testing, so the entry pill can't
    /// re-fire mid-engagement.
    func setCommentsEngaged(_ engaged: Bool) {
        let alpha: CGFloat = engaged ? 0 : 1
        captionLabel.alpha = alpha
        scrimView.alpha = alpha
        commentTicker.alpha = alpha
        subtitleView.alpha = alpha
        commentEmptyState.alpha = alpha
        // The rail (and its "+") stays fully INTERACTIVE through the
        // engagement; the keyboard-up overlap with the composer's trailing
        // ✕ is arbitrated at the cell level (`SnapFeedCell.hitTest`: the
        // composer outranks the rail only where the two physically
        // overlap).
    }

    /// The keyboard-session yield: while the engaged composer rises into
    /// the rail's column, the rail CONCEDES the band visually (alpha —
    /// which also removes it from hit-testing below 0.01). zPosition
    /// cannot express this: the rail and the composer live in different
    /// subtrees, and Core Animation only reorders SIBLINGS by zPosition —
    /// the input bar structurally cannot outrank chrome from inside the
    /// comments container, so the chrome steps back instead. Driven by
    /// the feed VC's keyboard observers, inside its own animation block.
    func setRailConcealed(_ concealed: Bool) {
        shortcutRail.alpha = concealed ? 0 : 1
    }

    /// Cycles while the owning cell is on screen — the band's visibility
    /// seam (plus the settle backstop for foregrounding), NOT playback's
    /// settle scope: the persistent pill is static content between
    /// handoffs, so it must ride a half-dragged page like the caption
    /// does instead of popping in after settle.
    func setSubtitlesActive(_ active: Bool) {
        subtitleView.setActive(active)
    }

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
        caption = nil
        applyCaptionVisibility()
        onCommentsTapped = nil
        hasMedia = true
        commentTicker.reset()
        composeButton.isHidden = true
        subtitleView.reset()
        commentEmptyState.setVisible(false)
        shortcutRail.reset()
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
