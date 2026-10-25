import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import PostGrid
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
    /// The bottom legibility scrim. The mid-stop pulls meaningful darkness up
    /// behind the comment ticker's lanes — the band's naked text has no
    /// capsules, so the scrim is its only contrast — while the bottom stays
    /// as dark as before under the caption and toolbar.
    private let scrimView = GradientView(
        colors: [.clear, UIColor.black.withAlphaComponent(0.45), UIColor.black.withAlphaComponent(0.75)],
        locations: [0, 0.55, 1]
    )

    /// An `EmoteLabel`: the caption's emoji and `:code:` emotes animate in
    /// place, at the caption's own size (`composedCaption` marks them).
    private let captionLabel = EmoteLabel()

    /// The bucket the caption's emotes are drawn at — what the screen warms
    /// the next captions at (#1504).
    var captionEmotePixelSide: Int { captionLabel.emotePixelSide }

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

    /// The hair of space between the page strip and the toolbar under it.
    static let pageBarToolbarGap: CGFloat = Spacing.xs

    /// The card a thumb dragging a clip's bar points with — the frame it would
    /// land on and the time it would land at. Frame-managed and out of the
    /// layout entirely: it exists only during a gesture, it follows the thumb,
    /// and nothing else on this screen may move because it appeared.
    private let scrubPreview = SnapScrubPreviewView()
    /// The pages' previews while a finger browses the strip (#1734).
    private let browseStrip = SnapBrowseStripView()

    /// The clip's length, kept because the card's readout is a time and the
    /// strip speaks in fractions.
    private var clipSeconds: Double = 0

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
    /// shortcuts (our animated emotes, still until the wheel moves), spanning
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
    /// The post's like count on the like button's corner (#668) — or, in the
    /// like pill (#669), under its heart.
    /// The post's like count — `configure`'s, then the live one
    /// (`setPostLikeCount`), the viewer's stake in it.
    private var postLikeCount: Int64?
    /// The SOUND bubble (#671), under the like pill on the field line, beside
    /// the caption and the page strip — see `SnapActionColumn`. Media chrome,
    /// like the pill (`applySoundVisibility`).
    private let soundBubble = SnapSoundBubbleButton()

    // MARK: The action column (#695)
    //
    // ⚠️ ONE COLUMN FOR BOTH LAYOUTS. The like pill and the sound bubble are
    // the page's — and they stay on screen when the comments take the page,
    // where the composer used to draw a SECOND pill and slot on the same
    // frames and the two crossfaded (the owner, on a device: "it looks
    // replaced"). The composer now only reserves their room.
    //
    // So the two buttons live in `columnLayer`, which the owning cell mounts
    // ABOVE this chrome (`installActionColumn(in:)`): this view's engagement
    // fade, a single container alpha, never reaches them. They are framed by
    // two invisible STATIONS that keep every constraint the buttons had —
    // the caption, the band and the composer's reserved room all stop short
    // of the same places. A chrome nobody installs (the hero flight's
    // replica) keeps the layer inside itself, as before.
    private let boostStation = UIView()
    private let soundStation = UIView()
    /// (#1681): save and repost upright between the like pill
    /// and the sound bubble (`showsPostActions`).
    private let postActionsStation = UIView()
    let postActions = SnapPostActionsCapsule()
    private var boostStationTop: NSLayoutConstraint?
    private var boostStationBottom: NSLayoutConstraint?
    private var railBottom: NSLayoutConstraint?

    /// The insets the cell handed over (`setFixedInsets`), before the
    /// bottom breath is added to them.
    private var fixedInsets: UIEdgeInsets?

    /// Shots — the For You root (#1716, the owner): its breath over the tab
    /// bar is its own (`shotsBottomBreath`, `applyFixedInsets`).
    var sitsOverTabBar = false {
        didSet {
            guard sitsOverTabBar != oldValue else { return }
            applyFixedInsets()
        }
    }
    /// The like pill's bottom above the margin line, without the capsule.
    private static var boostStationBottomInset: CGFloat {
        SnapActionColumn.inputRestingGap + SnapActionColumn.bubbleSize + SnapActionColumn.gap
    }

    /// (#1681, the For You root): the column holds save and
    /// repost between the like pill and the sound bubble, and the pill — with
    /// the emote rail it stands on — rises by the capsule's room.
    var showsPostActions = false {
        didSet {
            guard showsPostActions != oldValue else { return }
            applyPostActionsLayout()
        }
    }
    private let columnLayer = SnapActionColumnLayer()
    /// Where `columnLayer` is mounted: this chrome, or the cell's content.
    private weak var columnHost: UIView?

    /// What the sound bubble draws for the represented post — nil when the
    /// post has no sound bubble (the feed pushes it, `setSoundFace`).
    private var soundFace: SnapSoundFace?
    private var imagePipeline: ImagePipeline?
    /// The sound bubble was held: toggle the feed's sound (#683).
    var onSoundToggleRequested: (() -> Void)?
    /// The sound bubble was tapped: open the sound sheet (#683).
    var onSoundSheetRequested: (() -> Void)?
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
    /// The caption's two seats: xl above the bar over a page strip, or — with
    /// no strip — its bottom on the sound cover's line (`applyCaptionSeat`).
    private var captionOverStripConstraint: NSLayoutConstraint?
    private var captionOnBarConstraint: NSLayoutConstraint?
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
        [shortcutRail, boostButton, commentEmptyState, subtitleView, commentTicker, soundBubble, authorRow, captionLabel]
    }

    // MARK: - The author row (#1699)

    /// The post's author INSIDE the page, between the comment stream and the
    /// caption — the For You root's (the owner, 2026-10-24: out of the top
    /// bar). NO GLASS: the pill's face and lines over the media, their
    /// shadows (`setOverMedia`) keeping them legible, as the caption's do.
    /// The bar's glass was only ever the bar item's platter, never the
    /// pill's own.
    let authorRow = PersonPill(height: 40, carriesBadge: true, ceiling: 260)

    /// Whether the page shows its author row (the For You root only).
    var showsAuthorRow = false {
        didSet {
            guard showsAuthorRow != oldValue else { return }
            applyAuthorRowLayout()
        }
    }

    /// A tap on the author: the screen opens the author's card.
    var onAuthorTapped: (() -> Void)?
    /// A hold on the author: the screen pushes the profile.
    var onAuthorLongPressed: (() -> Void)?
    /// The "+" on the face: the screen follows the author.
    var onAuthorFollowTapped: (() -> Void)?

    private var subtitleOverCaption: NSLayoutConstraint!
    private var subtitleOverAuthor: NSLayoutConstraint!
    private var emptyStateOverCaption: NSLayoutConstraint!
    private var emptyStateOverAuthor: NSLayoutConstraint!
    private var tickerOverStream: NSLayoutConstraint!
    private var tickerOverAuthor: NSLayoutConstraint!

    /// Whether the danmaku has bubbles to show, from the streams last handed
    /// over (`updateCommentStreams`).
    private var tickerCarriesReactions = false

    /// (#1699, the owner 2026-10-24): on the For You root, a
    /// running danmaku REPLACES the comment stream — the band takes the
    /// stream's seat on the author row, and the stream stays down.
    private var tickerReplacesStream: Bool {
        showsAuthorRow && hasMedia && tickerCarriesReactions
    }

    private func installAuthorRow() {
        authorRow.setOverMedia(true)
        authorRow.isHidden = true
        authorRow.onTap = { [weak self] in self?.onAuthorTapped?() }
        authorRow.onFollowTapped = { [weak self] in self?.onAuthorFollowTapped?() }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(authorRowHeld(_:)))
        authorRow.addGestureRecognizer(hold)
        authorRow.constrain(in: self) { parent in
            // The face on the caption's text axis.
            authorRow.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg - 2)
            authorRow.trailingAnchor.constraint(lessThanOrEqualTo: shortcutRail.leadingAnchor, constant: -Spacing.md)
            authorRow.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.xs)
        }
    }

    @objc private func captionTapped() {
        onCommentsTapped?()
    }

    /// A tap on the caption — for tests.
    func debugTapCaption() { captionTapped() }

    @objc private func authorRowHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onAuthorLongPressed?()
    }

    /// The stream stands on the author row while it shows, on the caption
    /// otherwise; the danmaku stands on the author row in the stream's place
    /// while it replaces it (`tickerReplacesStream`), on the stream otherwise.
    private func applyAuthorRowLayout() {
        let shown = showsAuthorRow && hasMedia
        authorRow.isHidden = !shown
        let overAuthor: [NSLayoutConstraint] = [subtitleOverAuthor, emptyStateOverAuthor]
        let overCaption: [NSLayoutConstraint] = [subtitleOverCaption, emptyStateOverCaption]
        // Off before on: two required bottoms at once would conflict.
        NSLayoutConstraint.deactivate(shown ? overCaption : overAuthor)
        NSLayoutConstraint.activate(shown ? overAuthor : overCaption)
        let replaces = tickerReplacesStream
        let tickerOff: NSLayoutConstraint = replaces ? tickerOverStream : tickerOverAuthor
        let tickerOn: NSLayoutConstraint = replaces ? tickerOverAuthor : tickerOverStream
        tickerOff.isActive = false
        tickerOn.isActive = true
    }

    /// The author the row names, and the relation its badge says.
    func setAuthorRow(_ model: FeedItemDisplayModel, badge: PersonPill.Badge, pipeline: ImagePipeline) {
        let meta = SnapAuthorIdentityView.pillMetaLine(fromMeta: model.metaText)
        authorRow.setName(model.authorName, handle: meta)
        authorRow.avatar.setMonogram(MonogramAvatarView.monogram(name: model.authorName, handle: String(meta.dropFirst())))
        authorRow.avatar.setPicture(model.avatarURL, pipeline: pipeline)
        authorRow.avatar.frameID = model.avatarFrameID
        authorRow.setBadge(badge, animated: false)
        applyAuthorRowLayout()
    }

    /// The relation changed (a follow, from here or elsewhere).
    func setAuthorRowBadge(_ badge: PersonPill.Badge) {
        authorRow.setBadge(badge, animated: authorRow.window != nil)
    }

    /// A comments surface was tapped (empty-state pill, subtitle zone, or
    /// ticker band — one fan-in, one path) — the cell forwards this as a
    /// comments-engagement request with its post identity attached.
    var onCommentsTapped: (() -> Void)?

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
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SnapChromeView, _) in
            self.captionFloorHeightConstraint?.constant = Self.captionFloorHeight
            self.renderCaption()
        }

        buildLayout()
        installSoundBubble()
        applySoundVisibility()
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
        // ⚠️ NO ROOM FOR A STRIP THAT IS NOT THERE (the owner, 2026-10-16,
        // then #1716/#1726): above a strip the caption sits xl up; with none,
        // its bottom sits on the sound cover's line, on every feed.
        let captionOverStrip = captionLabel.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -Spacing.xl
        )
        let captionOnBar = captionLabel.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
        )
        captionOverStripConstraint = captionOverStrip
        captionOnBarConstraint = captionOnBar
        captionOnBar.isActive = true

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
            // A FIXED line, not the label's bottom: the label moves (a short
            // caption is one line, a lone picture has no strip), the corner
            // that hangs off this floor does not.
            captionFloorGuide.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor, constant: -Spacing.xl),
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
        // Pinned NEAR the bottom of the margins guide — the line the toolbar
        // rests against — so it sits in the band between the caption and the
        // bar without moving either. The caption keeps the position it has on
        // every other format; a post with one picture simply has nothing here.
        //
        // ⚠️ AND IT STOPS SHORT OF THE LINE by a hair. Flush against the guide
        // the strip and the toolbar's glass read as one stacked control, which
        // is the one thing they are not: the strip is the pictures' index and
        // the bar is what you can DO to the post. Four points is enough to say
        // they are two things — less than the seam between two containers in
        // the band above (md), because these two are closer kin than that.
        scrubPreview.translatesAutoresizingMaskIntoConstraints = true
        scrubPreview.frame = CGRect(origin: .zero, size: scrubPreview.totalSize)
        scrubPreview.onShapeChange = { [weak self] in
            guard let self, let last = lastScrubPreview else { return }
            placeScrubPreview(at: last.x)
        }
        addSubview(scrubPreview)
        mediaPageBar.onScrubPreview = { [weak self] preview in
            self?.showScrubPreview(preview)
        }
        addSubview(browseStrip)
        mediaPageBar.onBrowseBegan = { [weak self] page in self?.beginBrowse(at: page) }
        mediaPageBar.onBrowse = { [weak self] page in self?.browse(to: page) }
        mediaPageBar.onBrowseEnded = { [weak self] page in self?.endBrowse(at: page) }
        mediaPageBar.constrain(in: self) { parent in
            mediaPageBar.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor)
            mediaPageBar.bottomAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.bottomAnchor, constant: -Self.pageBarToolbarGap
            )
            mediaPageBar.heightAnchor.constraint(equalToConstant: SnapMediaPageBarView.thickness)
        }
        // The caption's trailing edge: the strip ends left of the sound
        // cover, on every feed (#1716).
        mediaPageBar.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor).isActive = true


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
            shortcutRail.trailingAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -SnapActionColumn.trailingInset
            )
            shortcutRail.widthAnchor.constraint(equalTo: bandSeat.heightAnchor)
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
            subtitleView.trailingAnchor.constraint(equalTo: shortcutRail.leadingAnchor, constant: -Spacing.md)
        }
        // The zone holds the band's seat, one md above the caption floor —
        // the slot the empty-state pill occupies too, so every comment
        // surface starts at one position. The band stands on the zone, md
        // above it, and stops short of the rail like the zone does: with no
        // glass to nest in there, its trailing end dissolves.
        // On the caption as it stands — one line or two (the owner,
        // 2026-10-16: a short caption with its time on one line lets the
        // stream and the band above it come down a line) — or on the author
        // row standing on it, on the For You root (#1699).
        subtitleOverCaption = subtitleView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
        subtitleOverAuthor = subtitleView.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
        tickerOverStream = commentTicker.bottomAnchor.constraint(equalTo: subtitleView.topAnchor, constant: -Spacing.md)
        NSLayoutConstraint.activate([
            subtitleOverCaption,
            tickerOverStream,
            commentTicker.trailingAnchor.constraint(equalTo: shortcutRail.leadingAnchor, constant: -Spacing.md),
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
        // seam against the caption — or against the author row (#1699).
        emptyStateOverCaption = commentEmptyState.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
        emptyStateOverAuthor = commentEmptyState.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
        emptyStateOverCaption.isActive = true
        installAuthorRow()
        // The danmaku in the stream's seat (#1699): md over the author row,
        // as the stream stands.
        tickerOverAuthor = commentTicker.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
        commentEmptyState.onTap = { [weak self] in self?.onCommentsTapped?() }
        subtitleView.onTap = { [weak self] in self?.onCommentsTapped?() }
        commentTicker.onTap = { [weak self] in self?.onCommentsTapped?() }
        // …and the caption (#1720, the owner): the post's words lead to what
        // is said about them.
        captionLabel.isUserInteractionEnabled = true
        captionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(captionTapped)))
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
        soundStation.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
        ).isActive = true
        captionLabel.trailingAnchor.constraint(
            equalTo: soundStation.leadingAnchor, constant: -Spacing.md
        ).isActive = true
        // The post's actions (#1681): one bubble wide, two tall, `gap` over
        // the sound bubble.
        postActionsStation.isUserInteractionEnabled = false
        postActionsStation.constrain(in: self) { parent in
            postActionsStation.trailingAnchor.constraint(
                equalTo: parent.layoutMarginsGuide.trailingAnchor, constant: -SnapActionColumn.trailingInset
            )
            postActionsStation.widthAnchor.constraint(equalTo: bandSeat.heightAnchor)
            postActionsStation.heightAnchor.constraint(equalTo: bandSeat.heightAnchor, multiplier: 2)
            postActionsStation.bottomAnchor.constraint(equalTo: soundStation.topAnchor, constant: -SnapActionColumn.gap)
        }
        postActions.isHidden = true
        // The buttons, in the column's own layer, on their stations.
        columnLayer.addSubview(boostButton)
        columnLayer.addSubview(soundBubble)
        columnLayer.addSubview(postActions)
        mountColumn(in: self)
        soundBubble.onTap = { [weak self] in self?.onSoundSheetRequested?() }
        soundBubble.onLongPress = { [weak self] in self?.onSoundToggleRequested?() }
    }

    private func railBottomConstraint() -> NSLayoutConstraint {
        let constraint = shortcutRail.bottomAnchor.constraint(equalTo: bandSeat.bottomAnchor)
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

    /// The column with or without the post's actions (#1681): the like
    /// pill and its rail rise by the capsule's room, the capsule shows on a
    /// media page (the sound bubble's rule).
    private func applyPostActionsLayout() {
        let lift = showsPostActions ? SnapPostActionsCapsule.columnExtent : 0
        boostStationTop?.constant = -lift
        boostStationBottom?.constant = -(Self.boostStationBottomInset + lift)
        railBottom?.constant = -lift
        applySoundVisibility()
        setNeedsLayout()
    }

    /// The sound bubble is MEDIA chrome, like the like pill above it: a text
    /// page's engagement is its permanent layout, and its composer stands in
    /// the column instead (its rail slot wears the sound). Shown for a post
    /// with a face — every media post has one, greyed when it has no sound.
    private func applySoundVisibility() {
        soundBubble.isHidden = soundFace == nil
        // The post's actions (#1681) are media chrome too: a text page's
        // composer holds them.
        postActions.isHidden = !showsPostActions || soundFace == nil
    }

    /// The sound bubble's face for the represented post (#671): its cover, the
    /// mute state, greyed for a post with no audio; nil for none.
    func setSoundFace(_ face: SnapSoundFace?) {
        soundFace = face
        soundBubble.setFace(face, pipeline: imagePipeline)
        applySoundVisibility()
    }

    /// Turns the sound bubble's cover while the post plays.
    func setSoundSpinning(_ spinning: Bool) {
        soundBubble.setSpinning(spinning)
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
        hasLaidOut = true
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
        let headroom = seat.maxY - base - fixedZones
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
        insets.bottom += sitsOverTabBar ? SnapActionColumn.shotsBottomBreath : SnapActionColumn.bottomBreath
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
        applyAuthorRowLayout()
        // ⚠️ THE CAPTION'S SEAT AT CONFIGURE (#1724): it was only re-read when
        // a page count arrived, which the flight replica of a single picture
        // never gets — it flew at the old seat and the caption jumped at the
        // landing (filmed by the owner, #1724).
        applyCaptionSeat()
        // Each page's declared shape, for the scrub card (#1724).
        pageAspects = model.mediaPages.enumerated().map { index, page in
            CGFloat(index == 0 ? (model.headAspectRatio ?? page.aspectRatio) : page.aspectRatio)
        }
        // ⚠️ THE CHROME CARRIES ITS OWN THEME (#683). The live cell's content
        // view is themed when it joins a window, and the hero flight's
        // replica never was: the like pill and the sound bubble flew as LIGHT
        // glass with dark ink, and turned dark at the landing — while the
        // toolbar, themed already, was white from the first frame.
        overrideUserInterfaceStyle = SnapChromeTheme.style(hasMedia: hasMedia)
        applyColumnStyle()
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
        // Owned by `configure` (static chrome, like the rail's emotes), so
        // it needs no stream to appear and the flight replica — which never
        // receives one — draws the identical corner.
        // ⚠️ THE LIKE PILL IS ALWAYS THERE (#1713, the owner): no post hides
        // its likes. On every page (#695): a text page's composer reserves its
        // room.
        boostButton.isHidden = false
        // The badge's count, from what the card knew; the screen then pushes
        // the post's live one (`setPostLikeCount`).
        postLikeCount = model.likeCount
        applyLikeBadge(animated: false)
        applySoundVisibility()
        if !hasMedia {
            tickerCarriesReactions = false
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
        shortcutRail.setEmotes(SnapShortcutRailView.payload(for: model.id))
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

    /// The caption's register over the media, on every snap feed (#1697,
    /// #1708, the owner): one text style below the body (`.subheadline`) in
    /// a soft grey, the timestamp dimmer still — the picture is the page and
    /// the words step back. ONE register: it was a per-screen variant (the
    /// For You root's) until the owner gave it to every vertical feed.
    enum CaptionRegister {
        static let textStyle: UIFont.TextStyle = .subheadline
        static let ink = UIColor(white: 0.78, alpha: 1)
        static let timestampInk = UIColor.white.withAlphaComponent(0.5)
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
    private static func captionAttributes(
        secondary: Bool
    ) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return [
            .font: UIFont.appFont(forTextStyle: secondary ? .footnote : CaptionRegister.textStyle),
            .foregroundColor: secondary ? CaptionRegister.timestampInk : CaptionRegister.ink,
            .shadow: shadow,
            // GEOMETRY LOCK: every line takes the PRIMARY (body) line height —
            // identical on every run — so a line ending on the smaller
            // footnote timestamp is still a full body line: the block is
            // exactly one or two body lines tall.
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
        let bodyLineHeight = UIFont.appFont(forTextStyle: CaptionRegister.textStyle).lineHeight
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
        2 * UIFont.appFont(forTextStyle: .body).lineHeight
    }

    /// How many lines `string` occupies at `width` — the two-line contract's
    /// yardstick. A pure measurement (no label state), so `composedCaption`
    /// can probe candidate renderings before committing one.
    static func captionLineCount(
        _ string: NSAttributedString, width: CGFloat
    ) -> Int {
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
        let lineHeight = UIFont.appFont(forTextStyle: CaptionRegister.textStyle).lineHeight
        return max(1, Int((height / lineHeight).rounded()))
    }

    /// The single source of caption typography for every media post and both
    /// chrome instances (live cell + flight replica) — a PURE function of
    /// (text, timestamp, width) so both resolve identically. It enforces a
    /// two-line contract with the timestamp always visible and always inline:
    ///
    ///   • Case A — a short caption takes the timestamp on its ONE line
    ///     (`Golden hour.  7 weeks`), so the block is one line tall (the
    ///     owner, 2026-10-16).
    ///   • Case B — a caption that fills two lines takes the timestamp inline
    ///     at the end of line two (`…line two  7 weeks`).
    ///   • Case C — a longer caption truncates early on line two so the
    ///     ellipsis + timestamp always sit un-clipped at that line's end
    ///     (`…cut off here…  7 weeks`).
    ///
    /// With no timestamp (or an unmeasured zero width) it returns the bare
    /// caption — the label's own `numberOfLines`/truncation then applies.
    ///
    /// Emotes are marked BEFORE anything is measured (`EmoteText`): a `:code:`
    /// is already the one emoji glyph it draws as, so every measurement below
    /// sees the final line, and Case C's bisection — which counts graphemes —
    /// can never cut an emote in half.
    static func composedCaption(
        _ caption: String, timestamp: String?, width: CGFloat
    ) -> NSAttributedString {
        let marked = NSMutableAttributedString(
            attributedString: EmoteText.attributedString(caption, attributes: captionAttributes(secondary: false))
        )
        // `@handle`s and `#tag`s in semibold, white like the rest over the
        // media (#524) — before anything is measured.
        marked.applyTextEntityStyle(.emphasis)
        let captionString: NSAttributedString = marked
        guard let timestamp, !timestamp.isEmpty, width > 0 else { return captionString }

        // ⚠️ ONE PIECE: "20 weeks" never splits across the two lines — the
        // inline time once ended line one with "20" and began line two with
        // "weeks" (seen on a device, 2026-10-16). Its spaces don't break.
        let unbroken = timestamp.replacingOccurrences(of: " ", with: "\u{00A0}")
        let timestampString = NSAttributedString(string: unbroken, attributes: captionAttributes(secondary: true))
        let gap = NSAttributedString(string: "  ", attributes: captionAttributes(secondary: false))

        // Case A: the caption and its time inline, on ONE line when they fit
        // there (the owner, 2026-10-16: the block is then one line tall, and
        // the stream above it comes down), else on two — a short caption
        // whose time wraps keeps it inline on the second line.
        let inline = NSMutableAttributedString(attributedString: captionString)
        inline.append(gap)
        inline.append(timestampString)
        if captionLineCount(inline, width: width) <= 2 { return inline }

        // Case C: bisect for the longest caption prefix that keeps the
        // ellipsis + timestamp inside two lines (prefix length grows the
        // line count monotonically, so the largest fitting prefix is the
        // truncation point).
        let characters = Array(captionString.string)
        func candidate(prefixLength: Int) -> NSAttributedString {
            // Cut from the MARKED string, so the emotes a prefix keeps keep
            // their marks.
            let prefix = String(characters[0..<prefixLength])
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = NSMutableAttributedString()
            if !trimmed.isEmpty, let range = prefix.range(of: trimmed) {
                out.append(captionString.attributedSubstring(from: NSRange(range, in: prefix)))
            }
            out.append(NSAttributedString(string: "… ", attributes: captionAttributes(secondary: false)))
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
        // Loaded, the band follows the bubbles: none, it goes. A SEED (top
        // comments from the cache, not loaded) knows nearly as well — a seed
        // with cues and no bubbles reserved the band by the card's count and
        // left the pill floating over a hole until the load collapsed it
        // (filmed on a device, 25 September 2026). Only a page with no
        // streams at all keeps the card's guess.
        if streams.isLoaded || streams.commentCount > 0 {
            commentTicker.setReservesBand(!streams.reactions.isEmpty)
        }
        subtitleView.setCommentCount(streams.commentCount)
        // A danmaku WITH BUBBLES TO SHOW replaces the stream on the For You
        // root (#1699): no cues, so the zone hides itself. None — or Reduce
        // Motion, which keeps the band down — and the stream stays.
        tickerCarriesReactions = !streams.reactions.isEmpty && !MotionPreference.reducesMotion
        subtitleView.setCues(tickerReplacesStream ? [] : streams.subtitles)
        applyAuthorRowLayout()
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


    private var hasLaidOut = false

    #if DEBUG
    /// The band's and the stream's frames in this chrome's space.
    var debugBandFrame: CGRect { commentTicker.frame }
    var debugBandTrailingEnd: (cornerRadius: CGFloat, fadeLocations: [NSNumber]?) {
        commentTicker.debugTrailingEnd
    }
    var debugStreamFrame: CGRect { subtitleView.frame }
    var debugRailFrame: CGRect { shortcutRail.frame }
    #endif

    #if DEBUG
    /// The caption's frame in `space`, for the landing probe that compares
    /// the flight replica with the page it fades into.
    func debugCaptionFrame(in space: UICoordinateSpace) -> CGRect {
        captionLabel.convert(captionLabel.bounds, to: space)
    }
    #endif

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    /// How many media pages the post has, and which one is showing. A count
    /// below two hides the indicator — a readout for a single photograph is
    /// furniture answering a question nobody asked.
    /// The flight's hold, passed to the ticker: no pre-fill at a transient
    /// width (see `SnapCommentTickerView.setHeldForFlight`).
    func setTickerHeldForFlight(_ held: Bool) {
        commentTicker.setHeldForFlight(held)
    }

    /// See `SnapCommentTickerView.replayEntrance`.
    func replayCommentBandEntrance() {
        commentTicker.replayEntrance()
    }

    /// See `SnapSubtitleView.replayEntrance`.
    func replaySubtitleEntrance() {
        subtitleView.replayEntrance()
    }

    func setMediaPageCount(_ count: Int, current: Int, clipPages: Set<Int> = []) {
        mediaPosition = CGFloat(current)
        mediaPageBar.configure(count: count, current: current, clipPages: clipPages)
        applyCaptionSeat()
        #if DEBUG
        runBrowseQAIfAsked(count: count)
        #endif
    }

    #if DEBUG
    /// QA (#1734): `-strip-browse <fraction>` holds a finger on the first
    /// carousel's strip at that fraction of its width, to film the browse
    /// (`-strip-browse-release` lets go after 4 s).
    private static var ranBrowseQA = false
    private func runBrowseQAIfAsked(count: Int) {
        let arguments = ProcessInfo.processInfo.arguments
        guard count >= 2, !Self.ranBrowseQA, let flag = arguments.firstIndex(of: "-strip-browse"),
              flag + 1 < arguments.count, let share = Double(arguments[flag + 1]) else { return }
        Self.ranBrowseQA = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let bar = mediaPageBar
            bar.debugScrub(.began, atX: 2)
            bar.debugScrub(.changed, atX: 2 + SnapMediaPageBarView.debugTravelThreshold + 1)
            bar.debugScrub(.changed, atX: bar.bounds.width * CGFloat(share))
            // `-strip-browse-release`: and lets go 4 s later.
            guard arguments.contains("-strip-browse-release") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                bar.debugScrub(.ended, atX: bar.bounds.width * CGFloat(share))
            }
        }
    }
    #endif

    /// Seats the caption over the strip, or in its place when there is none.
    private func applyCaptionSeat() {
        let overStrip = !mediaPageBar.isHidden
        setNeedsLayout()
        guard captionOverStripConstraint?.isActive != overStrip else { return }
        if overStrip {
            captionOnBarConstraint?.isActive = false
            captionOverStripConstraint?.isActive = true
        } else {
            captionOverStripConstraint?.isActive = false
            captionOnBarConstraint?.isActive = true
        }
        setNeedsLayout()
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
    /// The comment band, in the chrome's space.
    var debugTickerFrame: CGRect { commentTicker.frame }
    var debugCaptionFrame: CGRect { captionLabel.frame }
    var debugPageBar: SnapMediaPageBarView { mediaPageBar }
    var debugScrubPreview: SnapScrubPreviewView { scrubPreview }
    func debugScrubPreviewFrame() -> CGRect { scrubPreview.frame }
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
        mediaPosition = position
        mediaPageBar.setPosition(position)
    }

    /// The watched clip is loading or not (#1537): the bar's pulse.
    func setMediaLoading(_ loading: Bool) {
        mediaPageBar.setLoading(loading)
    }

    /// How far through the clip the page is showing, when there is one whose
    /// length is known — the strip draws it inside the segment it has grown
    /// into a bar.
    func setMediaPlayhead(_ fraction: Double?, seconds: Double = 0) {
        clipSeconds = seconds
        mediaPageBar.setPlayhead(fraction)
    }

    /// A frame the scrub card is pointing at. There is no "nothing new" here:
    /// a decode that failed leaves the last frame standing — see
    /// `SnapScrubPreviewView.setPicture`.
    func setScrubPreviewPicture(_ image: CGImage) {
        scrubPreview.setPicture(image)
    }

    /// Whether a frame is on its way, so the card can stand in for one it has
    /// not got.
    func setScrubPreviewLoading(_ loading: Bool) {
        scrubPreview.setLoading(loading)
    }

    /// Asked for a frame at a moment in the clip, or told the gesture is over.
    /// The CELL owns playback, so the request travels out.
    var onScrubPreviewRequested: ((Double?) -> Void)?

    /// Puts the card over the thumb and tells the host what to fetch.
    ///
    /// ⚠️ CLAMPED TO THE COLUMN, not to the screen: the card is a label on the
    /// strip, and one that ran past the strip's own ends would point at nothing.
    private func showScrubPreview(_ preview: (fraction: Double, x: CGFloat)?) {
        guard let preview else {
            scrubPreview.hide()
            setScrubFocus(false)
            onScrubPreviewRequested?(nil)
            return
        }
        setScrubFocus(true)
        lastScrubPreview = preview
        // The clip's own shape (#1724): the page the viewer is on.
        let page = Int(mediaPosition.rounded())
        if pageAspects.indices.contains(page) { scrubPreview.aspect = pageAspects[page] }
        placeScrubPreview(at: preview.x)
        // ⚠️ ABOVE EVERYTHING, and re-stated on every show. The card is built
        // with the strip, and the surfaces added after it — the shortcut wheel,
        // the boost anchor, the subtitle zone, the comment empty state — are
        // its own siblings, so a card added once sits UNDER the comment
        // surfaces it is meant to point over. Reported exactly that way.
        bringSubviewToFront(scrubPreview)
        scrubPreview.show(fraction: preview.fraction, seconds: clipSeconds)
        onScrubPreviewRequested?(preview.fraction)
    }

    /// The last point the card was asked over, for a re-place after a reshape.
    private var lastScrubPreview: (fraction: Double, x: CGFloat)?
    /// Each page's declared shape, width / height (#1724) — `configure`'s.
    private var pageAspects: [CGFloat] = []
    /// The carousel's position in pages — which page's shape the card takes.
    private var mediaPosition: CGFloat = 0

    /// Sizes the card to its shape and puts it over `x` along the strip.
    private func placeScrubPreview(at x: CGFloat) {
        let size = scrubPreview.totalSize
        let alongTheStrip = mediaPageBar.frame.minX + x
        let leftMost = mediaPageBar.frame.minX + size.width / 2
        let rightMost = mediaPageBar.frame.maxX - size.width / 2
        scrubPreview.frame = CGRect(
            x: min(max(alongTheStrip, leftMost), rightMost) - size.width / 2,
            y: mediaPageBar.frame.minY - size.height - Spacing.sm,
            width: size.width, height: size.height
        )
    }

    // MARK: - Browsing the pages (#1734)

    /// The carousel's previews: each page's thumbnail, and which are clips.
    func setMediaPreviews(thumbnails: [URL?], videoPages: Set<Int>, pipeline: ImagePipeline?) {
        browseStrip.configure(thumbnails: thumbnails, videoPages: videoPages, pipeline: pipeline)
    }

    /// A finger started sliding through the pages: the page's talk fades as
    /// it does under a clip's scrub, and the previews come up over the strip.
    var onMediaBrowseBegan: (() -> Void)?
    /// The page under the finger changed — the CELL turns the carousel.
    var onMediaBrowse: ((Int) -> Void)?
    /// The finger let go on this page.
    var onMediaBrowseEnded: ((Int) -> Void)?

    private func beginBrowse(at page: Int) {
        setScrubFocus(true)
        placeBrowseStrip()
        // Above everything, re-stated on every show — the scrub card's rule.
        bringSubviewToFront(browseStrip)
        browseStrip.show(selecting: page, anchorX: browseAnchor(page))
        onMediaBrowseBegan?()
    }

    private func browse(to page: Int) {
        browseStrip.select(page, anchorX: browseAnchor(page))
        onMediaBrowse?(page)
    }

    private func endBrowse(at page: Int) {
        browseStrip.hide()
        setScrubFocus(false)
        onMediaBrowseEnded?(page)
    }

    /// The filmstrip across the chrome's width, its counter on the strip's
    /// line — the row takes the caption's room above it, faded for the
    /// browse — as the reference app lays it out.
    private func placeBrowseStrip() {
        let bar = mediaPageBar.frame
        let height = SnapBrowseStripView.height
        let counterMid = height - SnapBrowseStripView.counterHeight / 2
        browseStrip.frame = CGRect(x: 0, y: bar.midY - counterMid, width: bounds.width, height: height)
    }

    /// Where the chosen tile stands: over the finger's slot on the strip, in
    /// the filmstrip's space.
    private func browseAnchor(_ page: Int) -> CGFloat {
        mediaPageBar.frame.minX + mediaPageBar.browseSlotCenter(page) - browseStrip.frame.minX
    }

    #if DEBUG
    var debugBrowseStrip: SnapBrowseStripView { browseStrip }
    #endif

    // MARK: - The scrub's focus

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
    private var scrubFadedViews: [UIView] {
        [captionLabel, commentTicker, subtitleView, commentEmptyState, shortcutRail, boostButton, soundBubble, authorRow]
    }

    /// What each faded view was worth before the scrub took it, so the fade
    /// back RESTORES rather than asserts.
    ///
    /// ⚠️ Restoring to 1 would be a bug with a long tail: several of these are
    /// faded by someone else for their own reasons — the rail rides the
    /// pull-down's progress, the band and the caption fade through an
    /// engagement — and a scrub that ended by setting them all to full would
    /// hand back a page brighter than the one it borrowed.
    private var scrubFadeRestore: [(view: UIView, alpha: CGFloat)] = []

    /// Fades the page's talk out under a scrub, and back when it ends.
    ///
    /// A viewer dragging along a clip's bar is looking for a MOMENT in the
    /// picture, and the card showing it is a small thing over a page still
    /// crowded with everything else. So the page recedes for the length of the
    /// gesture and comes back when the thumb lifts.
    private func setScrubFocus(_ focused: Bool, animated: Bool = true) {
        // Guarding on the ledger, not on a flag: entering twice would capture
        // the faded values as the ones to restore, which is how a fade becomes
        // permanent.
        guard focused == scrubFadeRestore.isEmpty else { return }
        let restoring = scrubFadeRestore
        if focused {
            scrubFadeRestore = scrubFadedViews.map { (view: $0, alpha: $0.alpha) }
        } else {
            scrubFadeRestore = []
        }
        let targets: [(view: UIView, alpha: CGFloat)] = focused
            ? scrubFadeRestore.map { (view: $0.view, alpha: 0) }
            : restoring
        let apply = { for target in targets { target.view.alpha = target.alpha } }
        guard animated else { return apply() }
        UIView.animate(
            withDuration: Self.scrubFocusDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: apply
        )
    }

    /// Long enough to read as a fade, short enough that a quick tap-and-drag on
    /// a bar does not spend its first moments in a dissolve.
    static let scrubFocusDuration: TimeInterval = 0.2

    #if DEBUG
    /// What the page's talk is worth right now — the question a spec asks to
    /// prove the scrub took it away and gave it back.
    var debugScrubFadedAlphas: [CGFloat] { scrubFadedViews.map(\.alpha) }
    #endif

    /// The viewer dragged along a clip's bar. The CELL owns playback, so the
    /// request travels out rather than the chrome reaching for a player.
    var onMediaSeekRequested: ((Double) -> Void)? {
        get { mediaPageBar.onSeekRequested }
        set { mediaPageBar.onSeekRequested = newValue }
    }

    /// A drag took hold of the clip's playhead — see `SnapMediaPageBarView
    /// .onScrubBegan`.
    var onMediaScrubBegan: (() -> Void)? {
        get { mediaPageBar.onScrubBegan }
        set { mediaPageBar.onScrubBegan = newValue }
    }

    /// The drag let go, at this fraction (nil on a cancel).
    var onMediaScrubEnded: ((Double?) -> Void)? {
        get { mediaPageBar.onScrubEnded }
        set { mediaPageBar.onScrubEnded = newValue }
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

    /// "Don't Cover People" (#484): the band to mask — always the same view,
    /// shown or not (it appears once its comments arrive).
    var personOcclusionTicker: UIView { commentTicker }
    /// Whether that band is on screen now.
    var isPersonOcclusionBandShown: Bool { !commentTicker.isHidden && commentTicker.window != nil }

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

    /// Mounts the column ABOVE this chrome in `host` (the cell's content
    /// view), so the engagement fade leaves it on screen. The buttons stay on
    /// their stations: same frames, by construction.
    func installActionColumn(in host: UIView) {
        mountColumn(in: host)
    }

    private func mountColumn(in host: UIView) {
        columnHost = host
        columnLayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(columnLayer)
        var constraints = [
            columnLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnLayer.topAnchor.constraint(equalTo: topAnchor),
            columnLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        for (button, station) in [
            (boostButton as UIView, boostStation), (soundBubble, soundStation), (postActions, postActionsStation),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            constraints += [
                button.leadingAnchor.constraint(equalTo: station.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: station.trailingAnchor),
                button.topAnchor.constraint(equalTo: station.topAnchor),
                button.bottomAnchor.constraint(equalTo: station.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Shows or hides the column — the like (boost) pill and the sound
    /// bubble — for a post the viewer may still act on (#1409). Its own
    /// switch, not the flight's hold (`setColumnHeld`, an alpha): a post
    /// that turned unavailable keeps it down whatever the flight does.
    func setActionColumnShown(_ shown: Bool) {
        columnLayer.isHidden = !shown
    }

    /// Hides the column with the page while a flight covers it — the
    /// replica carries its own. Unlike the chrome's own hold, released into
    /// the engaged state too: the column belongs to both.
    func setColumnHeld(_ held: Bool) {
        columnLayer.alpha = held ? 0 : 1
    }

    /// The column's ink: dark glass and white ink on a media page — in
    /// BOTH layouts, the comments' included (the owner, on a device: the
    /// column stays dark) — and a text page's own theme.
    private func applyColumnStyle() {
        columnLayer.overrideUserInterfaceStyle = hasMedia ? .dark : .unspecified
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
        // ⚠️ AND A SCRUB IN FLIGHT GIVES ITS ALPHAS BACK FIRST. A gesture does
        // not have to end for a cell to be recycled — the post can be swiped
        // away under the thumb — and the fade would otherwise be inherited by
        // the next post as a caption and a band that never come back. The same
        // trap as the line below, one gesture further in. Unanimated: there is
        // nothing on screen to dissolve, and the next configure is immediate.
        setScrubFocus(false, animated: false)
        // …and a browse in flight takes its previews with it (#1734).
        browseStrip.hide(animated: false)
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
        tickerCarriesReactions = false
        commentTicker.reset()
        boostButton.isHidden = true
        boostButton.setSpentTotal(0)
        postLikeCount = nil
        applyLikeBadge(animated: false)
        soundFace = nil
        soundBubble.setFace(nil, pipeline: nil)
        soundBubble.isHidden = true
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

    /// The viewer's cumulative spend on the represented post — turns the like
    /// heart red (#668); the count moves through the store
    /// (`setPostLikeCount`). Owned by the cell's configurator (the chrome has
    /// no wallet); reset to 0 with the rest of the post state on reuse.
    /// `animated` is kept for the callers' stake and undo theatre.
    func setBoostTotal(_ total: Int, animated: Bool = false) {
        boostButton.setSpentTotal(total)
        applyLikeBadge(animated: animated)
    }

    /// The post's live like count (#896) — the app's `EntityStore`, where
    /// the viewer's stakes already are (`WalletStakeLikes`).
    func setPostLikeCount(_ count: Int64?) {
        guard count != postLikeCount else { return }
        postLikeCount = count
        applyLikeBadge(animated: false)
    }



    /// The badge's count: the post's, the viewer's stake included (product
    /// decision 2026-10-08) — and included ONCE, by the store the count
    /// comes from (`WalletStakeLikes`, #896). Adding the stake here counted a
    /// committed stake twice (the server's count already holds it), and the
    /// card the post opened from showed another number.
    private func applyLikeBadge(animated: Bool) {
        // Drawn by the pill itself, under its heart (#692).
        boostButton.setLikeCount(postLikeCount)
    }

    #if DEBUG
    /// The like pill's transform — identity, always (#1186).
    var debugBoostButtonTransform: CGAffineTransform { boostButton.transform }
    /// The count under the pill's heart — nil while the pill is not showing.
    var debugLikeBadgeText: String? { boostButton.isHidden ? nil : boostButton.configuration?.title }
    /// Where the heart is drawn, in the chrome's space.
    var debugLikeHeartFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let image = boostButton.imageView else { return .zero }
        return image.convert(image.bounds, to: self)
    }
    /// Where the count is drawn, in the chrome's space.
    var debugLikeBadgeFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let label = boostButton.titleLabel else { return .zero }
        return label.convert(label.bounds, to: self)
    }
    #endif

    /// The anchor's wallet context: what the balance can still afford and
    /// how much of this post's spend is session-undoable — the enable state
    /// and the menu's live contents both derive from it.
    func setBoostContext(balance: Int, undoable: Int, stakeShots: Int = 0) {
        boostButton.setWalletContext(balance: balance, undoableAmount: undoable, stakeShots: stakeShots)
    }

    /// The spend's visible receipt: a gold "+N" born on the boost anchor
    /// that rises and dissolves; the anchor itself moves only by the glass's
    /// own press. Pure theatre over state that already changed — the wallet
    /// debited synchronously before this runs, so the animation can be
    /// dropped (hidden anchor, mid-reuse) without the count going wrong.
    func playBoostConfirmation(amount: Int) {
        guard !boostButton.isHidden, boostButton.bounds.width > 0 else { return }

        let label = UILabel()
        label.text = "+\(amount)"
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
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

        // ⚠️ NO DIP OF ITS OWN (#1186): the pill is a glass button, whose
        // native press already acknowledges the tap. A spring scale here ran
        // on top of it and read as a tremble (the owner, on a device).
    }

    /// The refund's receipt: a cool "−N" that sinks and dissolves — the
    /// confirmation float mirrored, in the direction money leaves the post.
    /// White, not gold: gold is the earning color, and an undo is not a
    /// payout.
    func playBoostRefund(amount: Int) {
        guard !boostButton.isHidden, boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "−\(amount)"
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
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

    /// Re-tunes the gradient's colours, unanimated.
    func setColors(_ colors: [UIColor]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = colors.map(\.cgColor)
        CATransaction.commit()
    }
}
