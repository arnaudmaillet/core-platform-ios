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
    /// The bottom legibility scrim: it protects the caption block — the
    /// caption, and the author row above it on Shots — and leaves the picture
    /// alone above it (#1983, the owner 2026-10-31: "the scrim ends at the
    /// caption block, as a card's does").
    ///
    /// ⚠️ IT WAS 68 % OF THE PAGE, from 32 % of the screen down, so that its
    /// mid-stop sat behind the reaction band and the subtitle zone (#46). It
    /// darkened the middle of every picture to 0.80 of its value and the
    /// subject with it — the post looked darker full screen than on its tile.
    /// The comment surfaces above the caption no longer get it, by the
    /// owner's decision.
    ///
    /// ONE progressive ramp, darker all the way down (the owner, 2026-10-31,
    /// on the device: no fade that stops on a plateau), calibrated on
    /// TikTok's and Instagram's, measured over a white video (#2175, the
    /// owner 2026-11-07: a little darker, the gradient itself imperceptible):
    /// - it starts `scrimLead` (48 pt) above the caption block, with a zero
    ///   slope — no line marks its top — and its first 20 pt stay under 3 %,
    ///   which the eye reads as nothing (behind the danmaku's lower lane), as
    ///   the reference's do;
    /// - it is never steeper than `scrimSlopeCap` (0.4 % per point, the
    ///   reference's), and its slope never kinks;
    /// - it reaches `scrimTopAlpha` (0.12) at the block's top, about 0.26 at
    ///   a two-line caption's last line, and about 0.60 at the screen's edge
    ///   under the toolbar (it was 0.75), easing toward `scrimCeiling` below.
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
    private let scrimView = GradientView(colors: SnapChromeView.scrimColors,
                                         locations: SnapChromeView.scrimLocations)
    /// Clips the scrim at the page's edges: deeper than the page, it would
    /// otherwise darken the next page in the pager (cells don't clip).
    private let scrimClip = UIView()

    /// How far above the caption block the ramp begins (#2175, the owner's
    /// option A, 2026-11-07; it was 12 pt, from 2026-11-01): the reference's
    /// darkness at the block's top cannot be reached gently from closer.
    static let scrimLead: CGFloat = 48
    /// The darkness at the caption block's top — its first line: the dark
    /// side of the reference's 0.10–0.12 (the owner: a little darker), which
    /// the app's smaller type (#2149) needs to reach about 0.26 by a two-line
    /// caption's last line at the capped slope.
    static let scrimTopAlpha: CGFloat = 0.12
    /// The steepest the ramp gets, in alpha per point: the reference's.
    static let scrimSlopeCap: CGFloat = 0.004
    /// How far below the block's top the ramp stays at its cap before it
    /// eases toward `scrimCeiling` — past a typical caption and the toolbar.
    static let scrimLinearDepth: CGFloat = 140
    /// What the ramp eases toward far below the block, never reaching it.
    static let scrimCeiling: CGFloat = 0.8
    /// The view's fixed height: the lead and more than any screen below it.
    static let scrimHeight: CGFloat = scrimLead + 1_200

    /// The ramp's darkness `x` points below where it starts (the block's top
    /// is at `scrimLead`). Three pieces, the slope continuous at each joint:
    /// a parabola from a zero slope up to the cap, the cap, then an
    /// exponential ease whose first slope is the cap.
    static func scrimAlpha(at x: CGFloat) -> CGFloat {
        let cap = scrimSlopeCap
        // Where the parabola meets the cap, so the block's top lands on
        // `scrimTopAlpha`: a·x₁² + cap·(lead − x₁) with a = cap / 2x₁.
        let joint = 2 * (cap * scrimLead - scrimTopAlpha) / cap
        guard x > 0 else { return 0 }
        if x <= joint { return cap / (2 * joint) * x * x }
        let easeStart = scrimLead + scrimLinearDepth
        let atJoint = cap * joint / 2
        if x <= easeStart { return atJoint + cap * (x - joint) }
        let atEase = atJoint + cap * (easeStart - joint)
        let room = scrimCeiling - atEase
        return scrimCeiling - room * CGFloat(exp(Double(-(x - easeStart) * cap / room)))
    }

    /// The stops, in points: every 6 pt through the curved start and the
    /// cap — so linear interpolation between stops never shows — then every
    /// 30 pt through the slow ease.
    static let scrimStopPoints: [CGFloat] = {
        let dense = scrimLead + scrimLinearDepth + 24
        var points = Array(stride(from: CGFloat(0), through: dense, by: 6))
        points += Array(stride(from: (points.last ?? 0) + 30, to: scrimHeight, by: 30))
        points.append(scrimHeight)
        return points
    }()
    static let scrimLocations: [NSNumber] = scrimStopPoints.map { NSNumber(value: Double($0 / scrimHeight)) }
    static var scrimColors: [UIColor] {
        scrimStopPoints.map { UIColor.black.withAlphaComponent(scrimAlpha(at: $0)) }
    }

    /// The scrim's top on the caption, and on the author row while it shows.
    private var scrimOverCaption: NSLayoutConstraint!
    private var scrimOverAuthor: NSLayoutConstraint!

    /// An `EmoteLabel`: the caption's emoji and `:code:` emotes animate in
    /// place, at the caption's own size (`composedCaption` marks them).
    private let captionLabel = SnapCaptionLabel()

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

    /// Where the page strip's line is centred, below the margins line
    /// (#2252, the owner 2026-11-10): halfway between the bottom of the
    /// caption's letters and the top of the bottom bar's glass, whichever
    /// bar it is — the toolbar on a pushed post, the tab bar on Shots.
    ///
    /// ⚠️ IT RESERVES NO HEIGHT. The caption stands on the cover's line on
    /// every format (`captionOnCoverLine`); the strip lies in the gap that
    /// was already there between the caption and the bar, so a video or a
    /// carousel lays out exactly as a single photo does. Before #2252 the
    /// caption sat 22 pt higher over a strip, and everything stacked on it
    /// jumped between posts.
    ///
    /// The letters' bottom is the caption's last baseline: its frame's
    /// bottom, less what its line box keeps under the baseline
    /// (`captionLetterDrop`). Expected (the owner's measures, the issue):
    /// about 10 pt either side of the line over the toolbar, about 8 over
    /// the tab bar — the 2 pt difference between the two screens is
    /// accepted, for one rule on both.
    static func pageBarCenterOffset(overTabBar: Bool, breathApplied: Bool = true) -> CGFloat {
        let letters: CGFloat = -(SnapActionColumn.inputRestingGap + captionLetterDrop)
        let glass: CGFloat = SnapActionColumn.glassBelowMargins(overTabBar: overTabBar, breathApplied: breathApplied)
        return (letters + glass) / 2
    }

    /// What the caption's line box keeps under its baseline: the bottom of
    /// its letters stands this far above the label's bottom. Every line is
    /// locked to the caption font's line height (`captionParagraphStyle`),
    /// so it is that height less the font's ascender. Font-derived: it
    /// follows Dynamic Type.
    static var captionLetterDrop: CGFloat {
        let font = UIFont.appFont(forTextStyle: CaptionRegister.textStyle)
        return max(font.lineHeight - font.ascender, 0)
    }

    /// The strip's centre, re-stated when the bar under it or the text size
    /// changes (`applyPageBarPlacement`).
    private var pageBarCenterConstraint: NSLayoutConstraint?


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
    /// Where the wheel stands (#1872): an invisible view holding its
    /// constraints in the chrome, while the wheel itself rides the column's
    /// layer, above its glass.
    private let railSeat = UIView()
    /// The wheel's own layer in the column's, faded with the chrome through
    /// the comments' engagement — the fade it had as the chrome's child.
    private let railLayer = SnapActionColumnLayer()
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
            // The strip centres on the tab bar's glass, not the toolbar's.
            applyPageBarPlacement()
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

    /// (#1924, the owner): a TEXT page's like stands in the screen's footer —
    /// its heart and count beside save and repost — so the column floats no
    /// pill over the composer, and a short comment list rests on it. A media
    /// page keeps its pill; so does a screen with no footer.
    var likeInFooter = false {
        didSet {
            guard likeInFooter != oldValue else { return }
            applyLikePillVisibility()
        }
    }

    private func applyLikePillVisibility() {
        let hidden = likeInFooter && !hasMedia
        guard boostButton.isHidden != hidden else { return }
        boostButton.isHidden = hidden
        glassColumn.refresh(animated: false)
    }
    private let columnLayer = SnapActionColumnLayer()
    /// The column's bubbles as ONE glass (#1872): the like, the post's
    /// actions and the sound fuse, split and fold into the sound — the
    /// buttons are its items, on their stations.
    private let glassColumn = SnapGlassColumn()
    /// Where `columnLayer` is mounted: this chrome, or the cell's content.
    private weak var columnHost: UIView?

    /// What the sound bubble draws for the represented post — nil when the
    /// post has no sound bubble (the feed pushes it, `setSoundFace`).
    private var soundFace: SnapSoundFace?
    private var imagePipeline: ImagePipeline?
    /// The sound bubble was tapped: open the sound sheet (#683).
    var onSoundSheetRequested: (() -> Void)?
    /// The sound bubble's way back was tapped (#1929): the stream goes back
    /// to its start.
    var onSoundReturnRequested: (() -> Void)?
    /// The bubble wears the post's Share (#1999) and was tapped.
    var onShareRequested: (() -> Void)?
    /// Whether the way back's hold arms Share (#1999): a media page's.
    private var holdArmsShare = false
    /// The way back's hold (#1929): the disc rises with the cover, and once
    /// full the sound sheet opens — the bubble's own tap action.
    private var soundHold: HoldToArmPresenter?
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
         soundBubble, authorRow, captionLabel]
    }

    // MARK: - The author row (#1699)

    /// The post's author INSIDE the page, between the comment stream and the
    /// caption — the For You root's (the owner, 2026-10-24: out of the top
    /// bar). NO GLASS: the pill's face and lines over the media, their
    /// shadows (`setOverMedia`) keeping them legible, as the caption's do.
    /// The bar's glass was only ever the bar item's platter, never the
    /// pill's own.
    let authorRow = PersonPill(height: 40, carriesBadge: true, ceiling: 260)

    /// The author's LINE, from the pill's face to the rail's stop and down to
    /// the caption, under the pill (#1848). The pill hugs its name, and the
    /// canvas beside a short one fell through to the media: a horizontal swipe
    /// there turned the carousel's page. Touchable and empty, it holds those
    /// touches as the caption does: a vertical swipe still reaches the feed's
    /// pager, and a tap still toggles playback (it is not an interaction root).
    /// `PersonPill` is untouched: the bar's author item is the same control.
    private let authorLane = UIView()

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
        authorRow.onFollowTapped = { [weak self] in self?.onAuthorFollowTapped?() }
        // A person beside content (#2145): a tap opens the card, a hold the
        // profile — the shared contract owns both.
        authorRowOpening.openCard = { [weak self] in self?.onAuthorTapped?() }
        authorRowOpening.openProfile = { [weak self] in self?.onAuthorLongPressed?() }
        authorRow.constrain(in: self) { parent in
            // The face on the caption's text axis.
            authorRow.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor, constant: Spacing.lg - 2)
            authorRow.trailingAnchor.constraint(lessThanOrEqualTo: railSeat.leadingAnchor, constant: -Spacing.md)
            authorRow.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.xs)
        }
        authorLane.isHidden = true
        authorLane.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(authorLane, belowSubview: authorRow)
        NSLayoutConstraint.activate([
            authorLane.leadingAnchor.constraint(equalTo: authorRow.leadingAnchor),
            // The pill's own ceiling, the band's and the subtitle zone's stop.
            authorLane.trailingAnchor.constraint(equalTo: railSeat.leadingAnchor, constant: -Spacing.md),
            authorLane.topAnchor.constraint(equalTo: authorRow.topAnchor),
            // Over the seam between the pill and the caption too.
            authorLane.bottomAnchor.constraint(equalTo: captionLabel.topAnchor),
        ])
        scrimOverAuthor = scrimView.topAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Self.scrimLead)
    }

    @objc private func captionTapped() {
        onCommentsTapped?()
    }

    /// A tap on the caption — for tests.
    func debugTapCaption() { captionTapped() }

    #if DEBUG
    var debugAuthorLane: UIView { authorLane }
    /// The scrim, the caption and the author row, for the scrim's suite.
    var debugScrimView: UIView { scrimView }
    var debugScrimClip: UIView { scrimClip }
    var debugCaptionLabel: UIView { captionLabel }
    var debugAuthorRow: UIView { authorRow }
    /// A hold on the author row, as a finger's would land.
    func debugHoldAuthorRow() { authorRowOpening.debugHold() }
    /// A tap on the author row. Tests.
    func debugTapAuthorRow() { authorRowOpening.debugTap() }
    #endif

    /// The row's tap and hold (#2145).
    private lazy var authorRowOpening = PersonOpening(on: authorRow)


    /// The stream stands on the author row while it shows, on the caption
    /// otherwise; the danmaku stands on the author row in the stream's place
    /// while it replaces it (`tickerReplacesStream`), on the stream otherwise.
    private func applyAuthorRowLayout() {
        let shown = showsAuthorRow && hasMedia
        authorRow.isHidden = !shown
        authorLane.isHidden = !shown
        let overAuthor: [NSLayoutConstraint] = [subtitleOverAuthor, emptyStateOverAuthor, scrimOverAuthor]
        let overCaption: [NSLayoutConstraint] = [subtitleOverCaption, emptyStateOverCaption, scrimOverCaption]
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

    /// The relation changed (a follow, from here or elsewhere), as the
    /// author binding draws it (#1972).
    func setAuthorRowBadge(_ badge: PersonPill.Badge, animated: Bool) {
        authorRow.setBadge(badge, animated: animated)
    }

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
            self.captionFloorHeightConstraint?.constant = Self.captionFloorHeight
            // The two-line block and the strip's place follow the font too
            // (#2252): two lines at every size, the line still centred under
            // the letters.
            self.captionBlockFloor?.constant = self.captionBlockHeight
            self.applyPageBarPlacement()
            self.renderCaption()
        }

        buildLayout()
        installSoundBubble()
        applySoundVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Spares (#2126)

    /// Chrome built ahead, at rest, for the next page a flight opens: the
    /// new cell's chrome and the flight's replica each take one rather than
    /// building theirs in the tap's turn (~4 ms apiece on the simulator,
    /// `-O`). A spare is exactly what `init` leaves — never configured,
    /// never in a window — so taking one is the same as building one.
    private static var spares: [SnapChromeView] = []
    static let spareCapacity = 2
    private static var restockArmed = false
    /// The text size the spares were built at: their caption floor is
    /// font-derived (`captionFloorHeight`), resolved in `init` from the app's
    /// size, not from a window they were never in.
    private static var sparesCategory: UIContentSizeCategory?

    /// A fresh chrome: a spare when one is ready, else built now. Spares
    /// built at another text size are dropped, not handed out.
    static func make() -> SnapChromeView {
        defer { armRestock() }
        if sparesCategory != UIApplication.shared.preferredContentSizeCategory { spares.removeAll() }
        return spares.popLast() ?? SnapChromeView()
    }

    private static func addSpare() {
        let category = UIApplication.shared.preferredContentSizeCategory
        if sparesCategory != category { spares.removeAll() }
        sparesCategory = category
        spares.append(SnapChromeView())
    }

    /// Builds the spares back one at a time, a second after the last take —
    /// past the flight it was taken for — and in the DEFAULT run-loop mode
    /// only, so a scroll's tracking holds it off.
    private static func armRestock() {
        guard !restockArmed, spares.count < spareCapacity else { return }
        restockArmed = true
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                restockArmed = false
                guard spares.count < spareCapacity else { return }
                addSpare()
                armRestock()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    #if DEBUG
    static var debugSpareCount: Int { spares.count }
    /// Builds every spare now — tests cannot wait out the restock.
    static func debugRestock() {
        while spares.count < spareCapacity { addSpare() }
    }
    #endif

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
        if !mediaPageBar.isHidden, mediaPageBar.alpha > 0.01, let item = columnItemHit(at: point, with: event) {
            return item
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// The column item (the sound cover, the actions, the like) under
    /// `point`, if one takes touches there.
    private func columnItemHit(at point: CGPoint, with event: UIEvent?) -> UIView? {
        for item in [soundBubble, postActions, boostButton] as [UIView] {
            guard !item.isHidden, item.alpha > 0.01, item.isUserInteractionEnabled, item.window != nil else { continue }
            let local = convert(point, to: item)
            guard item.point(inside: local, with: event), let hit = item.hitTest(local, with: event) else { continue }
            return hit
        }
        return nil
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
        if ProcessInfo.processInfo.arguments.contains("-scrim-white-page") {
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
            scrimView.heightAnchor.constraint(equalToConstant: Self.scrimHeight)
        }
        // Its top: the caption block's, less the lead (`applyAuthorRowLayout`
        // picks the author row's while it shows).
        scrimOverCaption = scrimView.topAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Self.scrimLead)

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
        let floorHeight = captionFloorGuide.heightAnchor.constraint(equalToConstant: Self.captionFloorHeight)
        captionFloorHeightConstraint = floorHeight
        NSLayoutConstraint.activate([
            captionFloorGuide.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor),
            captionFloorGuide.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor),
            // A FIXED line, not the label's bottom: the corner that hangs off
            // this floor keeps its own rule (#2252 left it where it was).
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
        // ⚠️ A 2 PT LINE IN THE GAP THAT ALREADY EXISTS (#2252, the owner
        // 2026-11-10, as TikTok's and Instagram's): centred between the
        // bottom of the caption's letters and the top of the bottom bar's
        // glass (`pageBarCenterOffset`), reserving no height — the caption
        // stands on the cover's line whether the strip is there or not, and a
        // post with one picture simply has nothing in that gap. Centred, it
        // stays clear of both: the strip is the pictures' index, the bar what
        // you can DO to the post. (It was pinned 4 pt over the margins line
        // in a 6 pt footprint, the caption seated 22 pt higher for it.)
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
        // posts) — or on the author row standing on it, on the For You root
        // (#1699).
        subtitleOverCaption = subtitleView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
        subtitleOverAuthor = subtitleView.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
        tickerOverStream = commentTicker.bottomAnchor.constraint(equalTo: subtitleView.topAnchor, constant: -Spacing.md)
        NSLayoutConstraint.activate([
            subtitleOverCaption,
            tickerOverStream,
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
        // seam against the caption — or against the author row (#1699).
        emptyStateOverCaption = commentEmptyState.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -Spacing.md)
        emptyStateOverAuthor = commentEmptyState.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
        emptyStateOverCaption.isActive = true
        installAuthorRow()
        scrimOverCaption.isActive = true
        // The danmaku in the stream's seat (#1699): md over the author row,
        // as the stream stands.
        tickerOverAuthor = commentTicker.bottomAnchor.constraint(equalTo: authorRow.topAnchor, constant: -Spacing.md)
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
        soundStation.bottomAnchor.constraint(
            equalTo: layoutMarginsGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
        ).isActive = true
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
        // The buttons are the glass column's items (#1872): the column is
        // their one glass, standing them on their stations.
        boostButton.drawsGlass = false
        soundBubble.drawsGlass = false
        postActions.drawsGlass = false
        for (id, button) in [
            (ColumnItem.like, boostButton as UIView), (ColumnItem.actions, postActions), (ColumnItem.sound, soundBubble),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = true
            glassColumn.register(button, for: id)
        }
        glassColumn.anchorID = ColumnItem.sound
        glassColumn.gap = SnapActionColumn.gap
        glassColumn.layout = { [weak self] in self?.columnSlots() ?? [] }
        glassColumn.frame = columnLayer.bounds
        glassColumn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        columnLayer.addSubview(glassColumn)
        // The wheel over the glass (#1872), its capsule in it.
        railLayer.frame = columnLayer.bounds
        railLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        railLayer.addSubview(shortcutRail)
        columnLayer.addSubview(railLayer)
        let capsule = shortcutRail.capsule
        capsule.likeHeight = SnapActionColumn.likePillHeight
        capsule.onLikeCover = { [weak self] cover in self?.glassColumn.setCover(ColumnItem.like, amount: cover) }
        capsule.onReturnShown = { [weak self] shown in self?.boostButton.setShowsReturn(shown) }
        boostButton.onReturn = { [weak capsule] in capsule?.returnToRest() }
        capsule.host = { [weak self] glass in self?.glassColumn.insertAccessory(glass) }
        mountColumn(in: self)
        soundBubble.onTap = { [weak self] in
            guard let self else { return }
            if soundBubble.showsReturn {
                onSoundReturnRequested?()
            } else if soundBubble.sharesPost {
                onShareRequested?()
            } else {
                onSoundSheetRequested?()
            }
        }
        // No hold of its own since #1931 (no in-app mute): only the way back
        // has one, arming the sheet (#1929).
        let hold = HoldToArmPresenter(view: soundBubble) { [weak self] in
            guard let self else { return .picture(nil) }
            return soundBubble.sharesPost ? .symbol(CommentsInputBar.shareRailSymbol) : .picture(soundBubble.coverImage)
        }
        // The hold arms the slot's own action (#1929): the sheet, or Share
        // on a media page's Share (#1999).
        hold.onFire = { [weak self] in
            guard let self else { return }
            if soundBubble.sharesPost { onShareRequested?() } else { onSoundSheetRequested?() }
        }
        hold.isEnabled = false
        soundHold = hold
    }

    /// Scrolled away from the comments' start (#1929): the sound bubble
    /// offers the way back to the top, and its sheet moves to a hold — kept
    /// for VoiceOver as a custom action.
    func setSoundShowsReturn(_ shows: Bool, down: Bool = false, animated: Bool = true) {
        guard shows != soundBubble.showsReturn || down != soundBubble.returnPointsDown else { return }
        soundBubble.setShowsReturn(shows, down: down, animated: animated)
        applySoundHold()
    }

    /// The way back's hold, and VoiceOver's road to the sheet, as the
    /// bubble stands: only on the chevron, only for a sound the post plays.
    private func applySoundHold() {
        let returns = soundBubble.showsReturn
        // Over Share (#1999) the hold arms Share on a media page — "a hold
        // arms its own action" — and nothing on a text page.
        let armsSheet = returns && !soundBubble.sharesPost && soundFace?.isAvailable == true
        let armsShare = returns && soundBubble.sharesPost && holdArmsShare
        soundHold?.isEnabled = armsSheet || armsShare
        if armsSheet {
            soundBubble.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Sound") { [weak self] _ in
                    self?.onSoundSheetRequested?()
                    return true
                },
            ]
        } else if returns, soundBubble.sharesPost {
            // Share stays reachable with the chevron up: VoiceOver's road.
            soundBubble.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Share") { [weak self] _ in
                    self?.onShareRequested?()
                    return true
                },
            ]
        } else {
            soundBubble.accessibilityCustomActions = nil
        }
    }

    /// The bubble as the post's Share (#1999) on a pushed page: a text
    /// page's column is Share alone on the sound's frame, a media page's
    /// ends on Share where the sound was (the sound moves to the footer).
    /// `holdArmsShare`: the way back's hold arms Share — a media page's.
    func setSlotSharesPost(_ shares: Bool, holdArmsShare: Bool = false) {
        self.holdArmsShare = shares && holdArmsShare
        soundBubble.setSharesPost(shares)
        applySoundHold()
        applySoundVisibility()
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

    /// The sound bubble: shown for a post with a face — every media post has
    /// one, greyed when it has no sound — or wearing a pushed text page's
    /// Share (#1999), on the same frame.
    private func applySoundVisibility() {
        soundBubble.isHidden = soundFace == nil && !soundBubble.sharesPost
        // The post's actions (#1681) are media chrome too: a text page's
        // composer holds them.
        postActions.isHidden = !showsPostActions || soundFace == nil
        // The glass column stands what shows (#1872).
        setNeedsLayout()
    }

    /// The sound bubble's face for the represented post (#671): its cover, the
    /// mute state, greyed for a post with no audio; nil for none.
    func setSoundFace(_ face: SnapSoundFace?) {
        soundFace = face
        soundBubble.setFace(face, pipeline: imagePipeline)
        applySoundHold()
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
        // The stations are resolved: the glass column stands its bubbles on
        // them in the same pass (#1872).
        glassColumn.setNeedsLayout()
        glassColumn.layoutIfNeeded()
        // The wheel on its seat (#1872) — by size and centre: a scroll view's
        // bounds origin is its offset.
        let wheelFrame = railSeat.convert(railSeat.bounds, to: railLayer)
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
        // The breath is in the margins now: the glass is that much nearer.
        applyPageBarPlacement()
    }

    /// The strip's centre for this chrome as it stands: over the tab bar or
    /// the toolbar, with the breath in its margins once a feed handed them.
    private var currentPageBarCenterOffset: CGFloat {
        Self.pageBarCenterOffset(overTabBar: sitsOverTabBar, breathApplied: fixedInsets != nil)
    }

    /// Re-centres the strip (#2252): the bar under it, the breath and the
    /// caption's font all move the gap it is centred in.
    private func applyPageBarPlacement() {
        let offset = currentPageBarCenterOffset
        guard let center = pageBarCenterConstraint, center.constant != offset else { return }
        center.constant = offset
        setNeedsLayout()
    }

    /// The caption block's height on a media page (#2252): two caption lines,
    /// rounded up to this screen's pixels — the height the label takes for
    /// two lines, so the floor never stretches a real two-line block.
    private var captionBlockHeight: CGFloat {
        let scale: CGFloat = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        return Self.captionBlockHeight(scale: scale)
    }

    /// Two caption lines, rounded up to `scale`'s pixels. Font-derived: it
    /// follows Dynamic Type.
    static func captionBlockHeight(scale: CGFloat) -> CGFloat {
        let twoLines: CGFloat = 2 * UIFont.appFont(forTextStyle: CaptionRegister.textStyle).lineHeight
        return (twoLines * scale).rounded(.up) / scale
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
        applyAuthorRowLayout()
        // ⚠️ THE CAPTION'S GEOMETRY AT CONFIGURE, never at a page count
        // (#1724: the flight replica of a single picture never gets one, and
        // the caption jumped at the landing). Since #2252 there is one seat;
        // what configure decides is the two-line floor — a media page's
        // block is two lines tall, a text page draws no caption.
        captionBlockFloor?.constant = captionBlockHeight
        captionBlockFloor?.isActive = hasMedia
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
        // A media post with no caption still draws its date, alone on the
        // block's second line (#2252): the caption is then empty, not absent.
        caption = hasMedia ? (model.caption ?? "") : nil
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
        // its likes. On every page (#695) — but a text page's stands in the
        // screen's footer when it has one (#1924, `likeInFooter`).
        boostButton.isHidden = likeInFooter && !hasMedia
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
    private var hasMedia = true

    private func renderCaption() {
        lastRenderedCaptionWidth = captionLabel.bounds.width
        captionLabel.attributedText = caption.map {
            Self.composedCaption($0, timestamp: timestampText, width: captionLabel.bounds.width)
        }
    }

    /// The caption's register over the media, on every snap feed (#1697,
    /// #1708, the owner): one text style below the body (`.subheadline`).
    /// ONE register: it was a per-screen variant (the For You root's) until
    /// the owner gave it to every vertical feed.
    ///
    /// ⚠️ WHITE, NO GREY (#2012, the owner 2026-11-01): the app's standard
    /// text white over media — the subtitle zone's, the band's, a card's —
    /// FIXED, not the dynamic `.label` (black in light mode). The caption and
    /// its timestamp alike; the timestamp is set apart by its smaller
    /// `.footnote` alone. It was a 0.78 grey with a half-white timestamp
    /// (#1697), 3.4 : 1 over a bright picture under the scrim — under AA's
    /// 4.5 : 1, and dimmer than the comments around it.
    ///
    /// The AGE has its own ink since #2052 (the owner, 2026-11-02): a
    /// solid grey a little darker than the caption's white, so it steps
    /// back as metadata. Solid, not a translucent white, so the picture
    /// behind never shifts it; fixed, as the chrome is over media in both
    /// appearances. The caption itself stays white.
    enum CaptionRegister {
        static let textStyle: UIFont.TextStyle = .subheadline
        static let ink = UIColor.white
        static let timestampInk: UIColor = {
            #if DEBUG
            // `-caption-age-white 0.65`: the owner's device comparison (#2052).
            let white = UserDefaults.standard.double(forKey: "caption-age-white")
            if white > 0, white <= 1 { return UIColor(white: white, alpha: 1) }
            #endif
            return UIColor(white: 0.75, alpha: 1)
        }()
    }

    /// The caption typography — the shared attributes for the caption glyphs
    /// (`.body`) and, for `secondary`, the appended timestamp: a SMALLER
    /// `.footnote` register in its own grey (`timestampInk`, #2052), so it
    /// reads as secondary metadata by its size and ink (the same footnote register the
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
    /// two-line contract: the block is ALWAYS two lines tall, and the date
    /// is never on line one (#2252, the owner 2026-11-10):
    ///
    ///   • A one-line caption — the date ALONE on line two
    ///     (`Golden hour.` / `7 weeks`).
    ///   • Case B — a caption that runs onto line two takes the date inline
    ///     at that line's end (`…line two  7 weeks`).
    ///   • Case C — a longer caption truncates early on line two so the
    ///     ellipsis + date always sit un-clipped at that line's end
    ///     (`…cut off here…  7 weeks`).
    ///   • No caption (media only) — line one empty, reserved, and the date
    ///     on line two.
    ///
    /// ⚠️ CASE A IS GONE (#2252). A short caption took its date on its one
    /// line (`Golden hour.  7 weeks`, the owner 2026-10-16, #1256): the
    /// block was then one line tall and the stream above it came down a
    /// line — a second jump between posts, after the strip's seat. The
    /// block's bottom stands on the cover's line, so two lines on every post
    /// keep the author row, the stream and the danmaku still.
    ///
    /// With no timestamp (or an unmeasured zero width) it returns the bare
    /// caption — the label's own `numberOfLines`/truncation then applies, and
    /// the chrome's two-line floor (`captionBlockFloor`) keeps the height.
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

        // A caption on ONE line (or none): the date alone on line two, behind
        // a line break — never beside the caption on line one (#2252). Kept
        // only if it really is two lines, which a caption ending in a break
        // of its own might not be; else the cases below place the date.
        if captionString.length == 0 || captionLineCount(captionString, width: width) <= 1 {
            let stacked = NSMutableAttributedString(attributedString: captionString)
            stacked.append(NSAttributedString(string: "\n", attributes: captionAttributes(secondary: false)))
            stacked.append(timestampString)
            if captionLineCount(stacked, width: width) == 2 { return stacked }
        }

        // Case B: the caption runs onto line two, and its date follows it
        // there, inline.
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
        // Nothing else moves for it (#2252): the strip reserves no height,
        // so a count arriving re-seats nothing.
        mediaPageBar.configure(count: count, current: current, clipPages: clipPages)
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
    var debugSoundHold: HoldToArmPresenter? { soundHold }
    /// The glass column's items, shape by shape, as the column stands them
    /// now (#1872).
    var debugColumnItems: [[String]] { columnSlots().map { $0.map(\.id) } }
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
    /// ⚠️ CLAMPED TO THE STRIP'S ENDS, not to the screen: the card is a label
    /// on the strip, and one that ran past them would point at nothing. The
    /// strip ends 12 pt in on both sides (#2291), so the card stays on screen.
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

    /// The clip the post is playing on `page`, mirrored into its preview while
    /// browsing (nil: none) — the CELL owns playback and hands the surface.
    func setBrowseLiveSurface(_ view: UIView?, page: Int) {
        browseStrip.setLiveView(view, page: page)
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
    ///
    /// The save and share capsule is in here with the like pill and the sound
    /// bubble, its neighbours in the column (#1847): left standing, it was the
    /// only piece of the post beside the filmstrip.
    private var scrubFadedViews: [UIView] {
        // The column fades as one glass (#1872): its bubbles' glass would
        // stay behind the buttons' faded faces.
        [captionLabel, commentTicker, subtitleView, commentEmptyState, shortcutRail, glassColumn, authorRow]
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
        // The wheel fades with the chrome.
        railLayer.alpha = resolved
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
        let constraints = [
            columnLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnLayer.topAnchor.constraint(equalTo: topAnchor),
            columnLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
    }

    /// The glass column's items (#1872).
    enum ColumnItem {
        static let like = "like"
        static let actions = "actions"
        static let sound = "sound"
    }

    /// Where the column's items stand: on their stations, each a bubble of
    /// its own.
    private func columnSlots() -> [[SnapGlassColumn.Slot]] {
        func slot(_ id: String, _ item: UIView, _ station: UIView) -> SnapGlassColumn.Slot? {
            guard !item.isHidden, station.bounds.width > 0 else { return nil }
            return SnapGlassColumn.Slot(id: id, frame: station.convert(station.bounds, to: glassColumn))
        }
        let sound = slot(ColumnItem.sound, soundBubble, soundStation)
        return [
            slot(ColumnItem.like, boostButton, boostStation),
            slot(ColumnItem.actions, postActions, postActionsStation),
            sound,
        ].compactMap { $0.map { [$0] } }
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
        let style: UIUserInterfaceStyle = hasMedia ? .dark : .unspecified
        columnLayer.overrideUserInterfaceStyle = style
        // ⚠️ AND ON EACH ITEM (#1872): a glass's content takes the ink the
        // glass picks over what is behind it, and the column's ink is the
        // page's choice — white over media, whatever the picture.
        for item in [boostButton as UIView, soundBubble, postActions] {
            item.overrideUserInterfaceStyle = style
        }
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
        railLayer.alpha = 1
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
        setSoundShowsReturn(false, animated: false)
        soundBubble.setFace(nil, pipeline: nil)
        soundBubble.setSharesPost(false)
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

/// The caption slide's delegate: begins only on a clearly horizontal travel
/// over a post with a strip (`SnapChromeView.captionSlideMayBegin`). An object
/// of its own — the chrome is a `UIView`, whose own `gestureRecognizerShouldBegin`
/// is asked of every recognizer attached to it.
final class SnapCaptionSlideGate: NSObject, UIGestureRecognizerDelegate {
    var mayBegin: (CGPoint) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Past its slop, the travel says the direction; the velocity backs it
        // when the travel is still too small to read.
        let travel = pan.translation(in: pan.view)
        return mayBegin(travel == .zero ? pan.velocity(in: pan.view) : travel)
    }
}

/// The caption: an `EmoteLabel` that tells a horizontal pager above it
/// (Shots' sector pager, `HorizontalDragClaiming`) when a slide starting on it
/// is its own — on a post with a strip (#2269).
final class SnapCaptionLabel: EmoteLabel, HorizontalDragClaiming {
    var claimsDrag: (CGPoint) -> Bool = { _ in false }

    func claimsHorizontalDrag(velocity: CGPoint) -> Bool {
        claimsDrag(velocity)
    }
}
