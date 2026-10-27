import MediaCore
import MediaPlayback
import PostGrid
import DesignSystem
import EmoteKit
import UIKit

/// What stands in a hero header's disc.
public enum HeroHeaderAvatar {
    /// A person's avatar (`AvatarView`): the initials, then the face — the
    /// content's `avatarURL`, monogram and frame. A tap replays an animated
    /// one.
    case person
    /// Any view, filling the disc: a place's flag.
    case custom(UIView)
}

/// One view of the header's action row (`HeroHeaderView.setActions`).
public enum HeroHeaderAction {
    /// A capsule: the capsules share the width the bubbles leave, and give
    /// way first when it is short.
    case capsule(UIView)
    /// A round bubble, `HeroHeaderView.bubbleSize` across.
    case bubble(UIView)
}

/// What a hero header shows — a person's, a place's — as finished text and
/// addresses. The header owns no data.
public struct HeroHeaderContent: Equatable, Sendable {
    /// The display name, a place's name.
    public var title: String
    /// Under the title: a person's @handle, a place's region.
    public var subtitle: String
    public var isVerified: Bool
    /// Nil hides the bio's row.
    public var bio: String?
    /// The link row's words; nil hides the row.
    public var websiteText: String?
    /// Handed to `onWebsiteTapped`.
    public var websiteURL: URL?
    /// One figure per counter, in the counters' order; nil (or none) hides
    /// that counter and leaves its cell empty.
    public var counterValues: [String?]
    /// A `.person` avatar's picture, initials and frame; unused by a
    /// `.custom` one.
    public var avatarURL: URL?
    public var avatarMonogram: String
    public var avatarFrameID: String?
    /// No picture, no banner: the bannerless layout.
    public var bannerImageURL: URL?
    public var bannerVideoURL: URL?
    /// A banner that may exist and is not known yet (a place whose posts
    /// are on their way, the owner 2026-10-26): with no `bannerImageURL`,
    /// the banner's slot shows its skeleton rather than the bannerless
    /// layout (#1752).
    public var bannerPending: Bool

    public init(
        title: String, subtitle: String, isVerified: Bool = false, bio: String? = nil,
        websiteText: String? = nil, websiteURL: URL? = nil, counterValues: [String?],
        avatarURL: URL? = nil, avatarMonogram: String = "", avatarFrameID: String? = nil,
        bannerImageURL: URL? = nil, bannerVideoURL: URL? = nil, bannerPending: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isVerified = isVerified
        self.bio = bio
        self.websiteText = websiteText
        self.websiteURL = websiteURL
        self.counterValues = counterValues
        self.avatarURL = avatarURL
        self.avatarMonogram = avatarMonogram
        self.avatarFrameID = avatarFrameID
        self.bannerImageURL = bannerImageURL
        self.bannerVideoURL = bannerVideoURL
        self.bannerPending = bannerPending
    }

    /// Counter `index`'s figure — nil past the end.
    func counterValue(at index: Int) -> String? {
        counterValues.indices.contains(index) ? counterValues[index] : nil
    }
}

/// The hero page's identity block (#1654) — a profile's, a place's — under a
/// BAND banner — a card across the top of the screen (`HeroBannerView`,
/// #1208), behind the status bar and the transparent navigation bar, its
/// foot in the air above the counters — or none at all. (The tall "poster"
/// banner is gone, the owner 2026-10-15.)
///
/// Identity anatomy:
/// - the band's picture under the chrome;
/// - then the identity row: the disc left (`HeroHeaderAvatar`: a person's
///   avatar, a place's flag), and beside it two halves of the disc's height
///   — the title (+ verified badge) over the subtitle in the TOP half,
///   standing on the picture in its ink (`HeroInk`), and the counter row
///   (`HeroStatView`, as many as the page counts, in equal cells) in the
///   BOTTOM half. From just above the disc the picture grows progressively
///   blurred and fades into the page, both barely under the title and whole
///   at the banner's foot (`HeroBannerFade`), so the counters are on the
///   page in page ink;
/// - below, full width: bio, website link and the flat action row
///   (`setActions`: capsules, then bubbles), closing the header right above
///   the content threshold.
///
/// Pure presentation — it is handed a finished `HeroHeaderContent` and an
/// `ImagePipeline`; it owns no data. A page kind builds on it for its own
/// actions (the profile's Follow tray, `ProfileHeaderView`).
open class HeroHeaderView: UIView {
    private enum Metrics {
        /// One element group's cross-dissolve on an account switch.
        static let dissolve: TimeInterval = 0.24
        /// Gap between groups. Small enough to read as one flowing change
        /// rather than three separate ones.
        static let stagger: TimeInterval = 0.05
        /// The avatar's side — and so the identity row's height: half of it
        /// for the name and the handle, half for the counters.
        static let avatarSize: CGFloat = 96
        /// Dynamic-Type ceiling for the avatar.
        static let avatarMaxSize: CGFloat = 110
        static let avatarRingWidth: CGFloat = 3
        static let badgeSize: CGFloat = 18
        /// Raw-media window between the navigation chrome and the identity
        /// block, per banner shape. A poster's is the picture's whole stage,
        /// so it gets more. A band's is only air: the disc's top sits just
        /// under the chrome's bottom edge, and the strip is the picture
        /// behind the chrome plus the top half of the identity row.
        /// The air between the chrome's bottom edge and the avatar, on a band
        /// and on a header with no picture.
        static let bandGap: CGFloat = Spacing.md
        /// How far below the avatar's midline a band's picture ends: the
        /// counters' half starts at the midline, their type a few points
        /// lower, and the page must be whole by then.
        static let bandFootBelowMidline: CGFloat = 6
        /// ⚠️ EXPERIMENT (the owner, 2026-10-15): a band is a CARD — inset
        /// from the screen's sides, held off the screen's top by the same
        /// margin, behind the status bar, its top corners following the display's and its
        /// bottom ones the post cards' — and the content starts lower, so
        /// more of the picture shows.
        static let bandCardInset: CGFloat = 12
        /// A band card's foot: 30 % of the screen's height.
        static let bandScreenFraction: CGFloat = 0.35
        /// The identity row's own side margins on a band card, inside the
        /// column's.
        static let bandRowInset: CGFloat = Spacing.md
        /// The air between the bar's foot and a band card's avatar at its
        /// detent.
        static let bandAvatarDetentGap: CGFloat = HeroBannerMetrics.bandAvatarDetentGap
        /// The air above the tray, carried by the tray itself so it holds
        /// whether or not a website row sits above it.
        static let trayGap: CGFloat = Spacing.md
        /// Side length of the circular bubbles in the action tray (and
        /// thus the height of the whole tray).
        static let bubbleSize: CGFloat = 44
        /// Content margins of the identity block — wider than the standard
        /// `Spacing.lg` page margin so the header reads airy against the
        /// full-bleed banner.
        static let horizontalInset: CGFloat = HeroBannerMetrics.identityInset
    }

    /// The identity block's page margin, published so the selector directly
    /// beneath it can line its own ends up with the name and the bio rather
    /// than with a second opinion about where this page's column starts.
    public static let pageMargin = Metrics.horizontalInset

    private let bannerView: HeroBannerView
    /// The player pool the video banner plays on (#944) — the screen's.
    public var bannerVideoPool: VideoPlaybackController?

    /// Whether the banner has a loop to play.
    public var hasBannerVideo: Bool { bannerView.videoURL != nil }

    /// Plays the video banner or stops it; nothing for a still banner.
    public func setBannerVideoPlaying(_ playing: Bool) {
        bannerView.setVideoPlaying(playing, pool: bannerVideoPool)
    }

    /// ⚠️ THE ONE RULE FOR A PROFILE'S MOVING PICTURES (#944, #1399, #1541),
    /// wherever the header is drawn — the profile, its card: the banner's
    /// loop plays while its host is on show (or leaving), the banner on
    /// screen and decorative motion allowed; the poster otherwise (Reduce
    /// Motion, Power Saving, idle calm, #580), and its skeleton while the
    /// profile loads (`setRedacted`). The avatar keeps its own (#1424): its
    /// rounds, its last frame as the still. A host supplies the one thing
    /// the header cannot know — whether it is on show.
    public func bannerShouldPlay(hostShowing: Bool) -> Bool {
        hostShowing && window != nil && isBannerOnScreen && !MotionPreference.stillsDecoration
    }

    /// Applies the rule above.
    public func updateBannerVideo(hostShowing: Bool) {
        setBannerVideoPlaying(bannerShouldPlay(hostShowing: hostShowing))
    }

    /// Whether the banner shows on screen at all: in its window, faded in,
    /// and below the bar.
    public var isBannerOnScreen: Bool {
        guard !bannerView.isHidden, let window = bannerView.window, bannerView.visibility > 0.05 else { return false }
        let frame = bannerView.convert(bannerView.bounds, to: window)
        return frame.intersects(window.bounds) && frame.maxY > window.safeAreaInsets.top
    }
    /// The disc's frame: sized by layout, ringed in the page's tone.
    private let avatarView = CircleAvatarView()
    /// A `.person` disc's avatar (#943): the initials, a smaller face
    /// standing in, then the sharp one — decoded at 512 px, not full (#1086).
    private let avatar: AvatarView?
    /// A `.custom` disc's view (a place's flag), filling it.
    private let customAvatar: UIView?
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let handleLabel = UILabel()
    /// A bio's emotes animate (`EmoteLabel` marks plain `text`).
    private let bioLabel = EmoteLabel()
    private let websiteButton = UIButton(configuration: .plain())
    /// Bumped by every configure — see `dissolve`.
    private var configureGeneration = 0
    /// The counters, in order. The first leads: a band card's foot stands
    /// in the even air above its figure.
    public let counters: [HeroStatView]
    private var leadCounter: HeroStatView { counters[0] }
    /// The action row — see `setActions`.
    private let actionRow = UIStackView()
    private var columnTopConstraint: NSLayoutConstraint?

    /// Pins the banner's top to the scroll viewport's top edge (required,
    /// as an inequality), so that when the user overscrolls downward the
    /// banner's soft attachment to the header top gives way and the media
    /// stretches to keep covering the screen from y = 0 — no background gap.
    /// When content scrolls up, the inequality is slack and the banner leaves
    /// the screen with the header as usual. Called once by the owning
    /// controller with its scroll view's `frameLayoutGuide.topAnchor`; the
    /// header stays scroll-view-agnostic.
    public func anchorBanner(toViewportTop viewportTop: NSLayoutYAxisAnchor) {
        let pin = bannerView.topAnchor.constraint(lessThanOrEqualTo: viewportTop, constant: bandCardTop)
        pin.isActive = true
        viewportPin = pin
    }

    /// The banner's pin to the viewport's top — a band card's top margin.
    private var viewportPin: NSLayoutConstraint?
    /// The banner's edges, for a band card's margins.
    private var bannerTopEdge: NSLayoutConstraint?
    private var bannerLeadingEdge: NSLayoutConstraint?
    private var bannerTrailingEdge: NSLayoutConstraint?

    /// A band card's top: the same margin as its sides, from the screen's
    /// top — behind the status bar, its corners concentric with the
    /// display's.
    private var bandCardTop: CGFloat { bannerFormat == .band ? Metrics.bandCardInset : 0 }

    /// The page's climb, as last handed down.
    private var travelled: CGFloat = 0

    /// The climb that brings a band card's avatar to rest just under the
    /// bar, a small gap between them — a scroll detent. Nil off a band.
    public var bandAvatarDetent: CGFloat? {
        guard bannerFormat == .band else { return nil }
        let avatarTop = avatarView.convert(avatarView.bounds, to: self).minY
        return max(0, avatarTop - chromeTopInset - Metrics.bandAvatarDetentGap)
    }

    /// A band card's shadow: a soft, wide glow in the ramp's tone, drawn by
    /// a view under the banner (which clips its own content).
    private let bannerShadow = UIView()

    private func applyBannerShadow(tone: UIColor) {
        bannerShadow.backgroundColor = tone
        bannerShadow.layer.shadowColor = tone.cgColor
        bannerShadow.layer.shadowOpacity = 0.35
        bannerShadow.layer.shadowRadius = 22
        bannerShadow.layer.shadowOffset = CGSize(width: 0, height: 10)
    }

    /// ⚠️ EXPERIMENT (the owner, 2026-10-15): A BAND CARD HOLDS ITS TOP
    /// MARGIN while the page climbs — its foot rides up with the avatar, so
    /// the card shortens — until the avatar's top reaches the bar's foot;
    /// from there it climbs away with the page.
    private func holdBandCardTop() {
        let held: CGFloat
        if bannerFormat == .band {
            let avatarTop = avatarView.convert(avatarView.bounds, to: self).minY
            let holdTravel = max(0, avatarTop - chromeTopInset)
            held = min(max(0, travelled), holdTravel)
        } else {
            held = 0
        }
        let top = bandCardTop + held
        guard bannerTopEdge?.constant != top else { return }
        bannerTopEdge?.constant = top
        // Asked for: a constant alone did not lay the header out again off a
        // window, and the scroll's own pass is not this method's to count on.
        setNeedsLayout()
    }

    /// The band card's margins and corners, or the banner edge to edge.
    private func applyBandCard() {
        let card = bannerFormat == .band
        let inset = card ? Metrics.bandCardInset : 0
        bannerTopEdge?.constant = bandCardTop
        viewportPin?.constant = bandCardTop
        holdBandCardTop()
        bannerLeadingEdge?.constant = inset
        bannerTrailingEdge?.constant = -inset
        // The top corners concentric with the display's (the card's top is
        // the screen's), the bottom ones the post cards' below.
        let foot = UICornerRadius.fixed(PostGridListRowCell.cardCornerRadius)
        bannerShadow.isHidden = isBannerSuppressed || !card
        bannerShadow.cornerConfiguration = card
            ? .corners(
                topLeftRadius: .containerConcentric(), topRightRadius: .containerConcentric(),
                bottomLeftRadius: foot, bottomRightRadius: foot
            )
            : .uniformCorners(radius: .fixed(0))
        bannerView.cornerConfiguration = card
            ? .corners(
                topLeftRadius: .containerConcentric(), topRightRadius: .containerConcentric(),
                bottomLeftRadius: foot, bottomRightRadius: foot
            )
            : .uniformCorners(radius: .fixed(0))
    }

    /// Height of the status-bar + navigation chrome the banner runs under,
    /// supplied by the owning controller (the header can't know it: its own
    /// safe area shifts as the scroll view moves). The identity column starts
    /// a full banner-clearance below this inset; the banner ignores it and
    /// bleeds to y = 0.
    public var chromeTopInset: CGFloat = 0 {
        didSet {
            if chromeTopInset != oldValue { layoutRevision += 1 }
            columnTopConstraint?.constant = columnTopConstant
            columnTopFloor?.constant = columnTopConstant
            // A collapsed band's avatar rides the chrome's foot.
            bandAvatarLine?.constant = bandAvatarLineConstant
            // The status bar's scrim covers the chrome, and stops there.
            bannerView.topScrimHeight = chromeTopInset > 0 ? chromeTopInset : 160
        }
    }

    /// The banner's shape — see `HeroBannerFormat`. Read off the picture
    /// as it lands; settable for QA.
    public private(set) var bannerFormat: HeroBannerFormat = .unresolved

    /// Where the identity column starts on a band or with no banner, and
    /// the highest it may ever start: a band's clearance under the chrome —
    /// the strip reaches down INTO the avatar rather than the avatar
    /// climbing up into the strip.
    private var columnTopConstant: CGFloat {
        chromeTopInset + Metrics.bandGap
    }

    /// Whether a band card RESTS COLLAPSED (a place's, the owner
    /// 2026-10-23): at the height a profile's shrinks to as it climbs — its
    /// avatar just under the bar, a detent's gap between them — rather than
    /// down to `bandScreenFraction` of the screen.
    public var bandRestsCollapsed = false {
        didSet {
            guard bandRestsCollapsed != oldValue else { return }
            bandAvatarLine?.constant = bandAvatarLineConstant
            layoutRevision += 1
            setNeedsLayout()
        }
    }

    /// A band card's avatar midline, so its foot (`bandFootBelowMidline`
    /// under it) lands at `bandScreenFraction` of the screen — or, resting
    /// collapsed, so the avatar's top stands a detent's gap under the chrome.
    private var bandAvatarLine: NSLayoutConstraint?
    private var bandAvatarLineConstant: CGFloat {
        if bandRestsCollapsed {
            return chromeTopInset + Metrics.bandAvatarDetentGap + Metrics.avatarSize / 2
        }
        return (screenHeight * Metrics.bandScreenFraction).rounded() - Metrics.bandFootBelowMidline
    }
    /// The column never starts higher than a band's.
    private var columnTopFloor: NSLayoutConstraint?

    private var screenHeight: CGFloat { window?.screen.bounds.height ?? UIScreen.main.bounds.height }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBandCard()
        if let bandAvatarLine, bandAvatarLine.constant != bandAvatarLineConstant {
            bandAvatarLine.constant = bandAvatarLineConstant
            layoutRevision += 1
        }
    }

    /// The header's alpha — the identity's fade at the dock — reaches the
    /// banner too when it stands outside the header (`moveBanner`).
    public override var alpha: CGFloat {
        didSet {
            if bannerView.superview !== self {
                bannerView.hostAlpha = alpha
                bannerShadow.alpha = alpha
            }
        }
    }

    /// A hidden header takes its banner and the banner's shadow along, as
    /// `alpha` does (#1406: an unavailable profile is a plain page). They
    /// live outside the header once moved (`moveBanner`), so hiding the
    /// header used to leave them — with no picture to show, the card's
    /// placeholder ramp read as a banner that failed to load. A picture
    /// landing while hidden (`setBannerFormat`) does not bring them back.
    public override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            bannerView.isHidden = isBannerSuppressed || bannerFormat == .none
            bannerShadow.isHidden = isBannerSuppressed || bannerFormat != .band
            if isBannerSuppressed { setBannerVideoPlaying(false) }
        }
    }

    private var isBannerSuppressed: Bool { isHidden }

    /// Moves the banner OUT of the header, into `container` below `sibling` —
    /// behind the screen's scrolling content, so that content can pass over
    /// a poster's lower part. It keeps resting on the header's top (its
    /// constraints are the header's own, `constrainBanner`), so everything
    /// read off it — the fade, the ink, the stretch — stays in the header's
    /// space. Call before `anchorBanner(toViewportTop:)`.
    public func moveBanner(into container: UIView, below sibling: UIView) {
        bannerView.removeFromSuperview()
        container.insertSubview(bannerView, belowSubview: sibling)
        bannerView.restingTopReference = self
        bannerView.hostAlpha = alpha
        constrainBanner()
    }

    /// Adopts a banner shape: the column's start, whether there is a banner,
    /// where it ends — a band on the avatar's midline (the name on the
    /// picture, the counters on the page), a poster at the tray's foot (the
    /// whole block on the picture) — and whether it fades out on the way up.
    public func setBannerFormat(_ format: HeroBannerFormat) {
        guard format != bannerFormat || !hasAppliedBannerFormat else { return }
        hasAppliedBannerFormat = true
        layoutRevision += 1
        bannerFormat = format
        columnTopConstraint?.constant = columnTopConstant
        columnTopFloor?.constant = columnTopConstant
        // A band's column rides its avatar line; no picture, its floor.
        columnTopConstraint?.isActive = format != .band
        bandAvatarLine?.isActive = format == .band
        let rowInset = format == .band ? Metrics.bandRowInset : 0
        topRow.isLayoutMarginsRelativeArrangement = true
        topRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: rowInset, bottom: 0, trailing: rowInset)
        bannerView.isHidden = isBannerSuppressed || format == .none
        activateBannerFoot()
        bannerView.setFormat(format)
        applyIdentityInk()
        setNeedsLayout()
    }

    /// The scroll, handed down to the banner: the picture lags the content,
    /// and a poster fades out over exactly the travel that brings the
    /// avatar's top to where a band would hold it — under the chrome, a gap
    /// below it — so the two shapes meet at the same picture: none.
    public func setTravelled(_ travelled: CGFloat) {
        self.travelled = travelled
        holdBandCardTop()
        bannerView.setTravelled(travelled)
        applyIdentityInk()
    }

    // MARK: - Identity ink

    /// The page's ink, for no picture and a poster scrolled away. On a
    /// banner the name and the handle wear the picture's ink instead — white
    /// or black by what the picture is behind them; see `HeroInk`.
    public static let pageNameInk = UIColor.label
    public static let pageHandleInk = UIColor.secondaryLabel

    /// Which ink each block standing on the picture wears — read off the
    /// blurred picture behind it (`updateInkTones`): the name and the handle,
    /// and on a poster the counters and the bio with its link.
    private struct InkTones: Equatable {
        var name = HeroInk.defaultTone
        var counters = HeroInk.defaultTone
        var body = HeroInk.defaultTone
    }
    private var inkTones = InkTones()
    /// The blocks' frames the tones were last read for, and the bake — a
    /// re-read only when one of them moves or the picture is re-baked.
    private var inkTonesReadFor: [CGRect] = []

    /// How much of the name's and the handle's ink is the picture's: 1 on a
    /// banner at rest, 0 with no picture. A poster fades out as it scrolls up
    /// (`setTravelled`) — picture ink kept over the page could vanish — so
    /// the ink follows the banner's visibility back to the page's. A band
    /// never fades: it scrolls away under the type it carries.
    private var identityInkOnPicture: CGFloat = 0
    /// The same for what stands BELOW the name — the counters, the bio and
    /// the link: on the picture only on a poster, which runs down to the
    /// tray; on a band they are on the page.
    private var bodyInkOnPicture: CGFloat = 0

    /// One of the counter row's four equal cells (#687): `stat` centred in
    /// it, never wider than it. A hidden stat leaves the cell — and so its
    /// neighbours' places — as they were.
    private static func statCell(holding stat: HeroStatView) -> UIView {
        let cell = UIView()
        stat.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stat)
        NSLayoutConstraint.activate([
            stat.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            stat.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
            stat.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stat.topAnchor.constraint(equalTo: cell.topAnchor),
            stat.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    private func applyIdentityInk(force: Bool = false) {
        // No picture yet (a flat grey slot, no ramp): the page's ink.
        let onPicture = bannerFormat == .none || !bannerView.hasPicture ? 0 : bannerView.visibility
        if force || onPicture != identityInkOnPicture {
            identityInkOnPicture = onPicture
            let tone = inkTones.name
            nameLabel.textColor = HeroInk.blend(
                page: Self.pageNameInk, picture: tone.primary, onPicture: onPicture
            )
            handleLabel.textColor = HeroInk.blend(
                page: Self.pageHandleInk, picture: tone.secondary, onPicture: onPicture
            )
            for label in [nameLabel, handleLabel] {
                HeroInk.applyShadow(to: label, tone: tone, onPicture: onPicture)
            }
        }
        let bodyOnPicture: CGFloat = 0
        guard force || bodyOnPicture != bodyInkOnPicture else { return }
        bodyInkOnPicture = bodyOnPicture
        for stat in counters {
            stat.setInk(tone: inkTones.counters, onPicture: bodyOnPicture)
        }
        let body = inkTones.body
        bioLabel.textColor = HeroInk.blend(page: .label, picture: body.primary, onPicture: bodyOnPicture)
        HeroInk.applyShadow(to: bioLabel, tone: body, onPicture: bodyOnPicture)
        // The link wears the text links' ink on the page (#1174); on a
        // picture a hue is the ink sure to sink into it, so it wears the
        // picture's ink.
        websiteButton.configuration?.baseForegroundColor = HeroInk.blend(
            page: Palette.entityInk, picture: body.primary, onPicture: bodyOnPicture
        )
    }

    /// Reads the blurred picture behind each block of type and picks its
    /// ink (`HeroInk.tone`, which keeps a legible ink rather than flip on a
    /// mid picture). Runs when the levels are baked and when a block moves;
    /// a change of ink on screen cross-dissolves.
    private func updateInkTones(force: Bool = false) {
        guard bannerFormat != .none else { return }
        HeroBannerCost.measure(.ink) { readInkTones(force: force) }
    }

    private func readInkTones(force: Bool) {
        // ⚠️ IN THE HEADER'S SPACE — the banner's at rest, which is what its
        // ground is read in. Converted to the banner, a pull-down (which
        // stretches the banner up above the header) moved every block down
        // its ground by the pull, and each two points of it read the ground
        // again: up to three reads a frame on a poster, the bulk of the
        // pull's dropped frames on a device.
        func frame(of views: [UIView]) -> CGRect {
            views.filter { !$0.isHidden }
                .map { $0.convert($0.bounds, to: self) }
                .reduce(CGRect.null) { $0.union($1) }
        }
        let blocks = [
            frame(of: [nameLabel, handleLabel]),
            frame(of: [statsRow]),
            frame(of: [bioLabel, websiteButton])
        ]
        let moved = blocks.count != inkTonesReadFor.count
            || zip(blocks, inkTonesReadFor).contains { abs($0.minY - $1.minY) > 2 || abs($0.height - $1.height) > 2 }
        guard force || moved else { return }
        guard let nameGround = bannerView.groundPixels(behind: blocks[0]) else { return }
        inkTonesReadFor = blocks
        #if DEBUG
        debugInkReadCount += 1
        #endif
        var tones = inkTones
        tones.name = HeroInk.tone(forGround: nameGround, current: inkTones.name)
        #if DEBUG
        HeroInk.debugTraceGround(nameGround, name: "profile-name", picked: tones.name)
        #endif
        guard tones != inkTones else { return }
        inkTones = tones
        guard isInVisibleWindow else { return applyIdentityInk(force: true) }
        UIView.transition(
            with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.applyIdentityInk(force: true)
        }
    }


    private var hasAppliedBannerFormat = false
    private var bannerEndsInAvatar: NSLayoutConstraint?
    private var bandFootAtCounters: NSLayoutConstraint?
    /// The name block on its half's top — or, on a band card, the handle's
    /// baseline as far above the banner's foot as the name's baseline is
    /// above the handle's cap top (the owner, 2026-10-15).
    private var nameBlockTop: NSLayoutConstraint?
    private var bandHandleBaseline: NSLayoutConstraint?

    /// The air between the name's baseline and the handle's cap top, as drawn.
    private var nameToHandleAir: CGFloat {
        let name = nameLabel.font ?? .systemFont(ofSize: 22)
        let handle = handleLabel.font ?? .systemFont(ofSize: 15)
        return -name.descender + nameBlock.spacing + (handle.ascender - handle.capHeight)
    }

    private var bandHandleBaselineConstant: CGFloat {
        leadCounter.evenAirEdge - nameToHandleAir
    }

    /// Exactly one foot for the banner, by its shape: a band's on the
    /// avatar's midline, a poster's at 80% of the screen.
    private func activateBannerFoot() {
        bannerEndsInAvatar?.isActive = bannerFormat != .band
        bandFootAtCounters?.isActive = bannerFormat == .band
        if bandHandleBaseline == nil {
            let baseline = handleLabel.lastBaselineAnchor.constraint(
                equalTo: leadCounter.topAnchor, constant: bandHandleBaselineConstant
            )
            baseline.priority = .init(999)
            bandHandleBaseline = baseline
        }
        nameBlockTop?.isActive = bannerFormat != .band
        bandHandleBaseline?.isActive = bannerFormat == .band
        applyBandCard()
    }

    /// The banner's place, from the header's own anchors wherever the banner
    /// stands: its top resting on the header's (soft — a pull-down's
    /// `anchorBanner` stretches it above), edge to edge, and its foot by
    /// its shape. Built again after a move: a view leaving its superview
    /// takes its constraints with it.
    private func constrainBanner() {
        let bannerTop = bannerView.topAnchor.constraint(equalTo: topAnchor)
        bannerTop.priority = .defaultHigh
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        let leading = bannerView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = bannerView.trailingAnchor.constraint(equalTo: trailingAnchor)
        bannerTopEdge = bannerTop
        bannerLeadingEdge = leading
        bannerTrailingEdge = trailing
        NSLayoutConstraint.activate([bannerTop, leading, trailing])
        // The shadow rides under the banner, wherever it stands, on its edges.
        bannerShadow.removeFromSuperview()
        bannerShadow.isUserInteractionEnabled = false
        bannerShadow.translatesAutoresizingMaskIntoConstraints = false
        bannerView.superview?.insertSubview(bannerShadow, belowSubview: bannerView)
        NSLayoutConstraint.activate([
            bannerShadow.topAnchor.constraint(equalTo: bannerView.topAnchor),
            bannerShadow.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor),
            bannerShadow.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor),
            bannerShadow.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor),
        ])
        bannerView.onRampToneChange = { [weak self] tone in self?.applyBannerShadow(tone: tone) }
        // ⚠️ A BAND ENDS ON THE AVATAR'S MIDLINE — the line between the
        // name's half and the counters' half, so the name stands on the strip
        // and the counters on the page. The banner's own edge sits a few
        // points lower (`bandFootBelowMidline`), in the air above the
        // counters, where `HeroBannerFade`'s ramp is all but the page.
        bannerEndsInAvatar = bannerView.bottomAnchor.constraint(
            equalTo: avatarView.centerYAnchor, constant: Metrics.bandFootBelowMidline
        )
        // A band card's foot: as much air above the counters' numbers as
        // under them (the owner, 2026-10-15).
        bandFootAtCounters = bannerView.bottomAnchor.constraint(
            equalTo: leadCounter.topAnchor, constant: leadCounter.evenAirEdge
        )
        activateBannerFoot()
    }
    private let topRow = UIStackView()
    /// The identity block — avatar row to tray — whose height sets a
    /// poster's stage (`posterClearance`).
    private var identityBlock: UIStackView?
    private let statsRow = UIStackView()
    /// The name and the handle, in the identity row's top half.
    private let nameBlock = UIStackView()
    /// Beside the avatar: `nameBlock`'s half over the counters' half.
    private let identityColumn = UIStackView()

    #if DEBUG
    /// How many times the ground under the type was read.
    public private(set) var debugInkReadCount = 0
    public var debugBlurComposeCount: Int { bannerView.debugBlurComposeCount }
    public var debugBlurBakeCount: Int { bannerView.debugBlurBakeCount }
    /// The banner's loop surface, to ask the pool about it (#1399).
    public var debugBannerVideoView: VideoRenderView { bannerView.debugVideoView }
    /// Where the banner's sharp picture and its ramp are drawn, in the
    /// header's space.
    public var debugBannerPictureCover: CGRect { bannerView.convert(bannerView.debugPictureCover, to: self) }
    public var debugBannerRampFrame: CGRect { bannerView.convert(bannerView.debugRampFrame, to: self) }
    public var debugBannerFrame: CGRect { bannerView.convert(bannerView.bounds, to: self) }
    public var debugAvatarFrame: CGRect { avatarView.convert(avatarView.bounds, to: self) }
    public var debugTrayFrame: CGRect { actionRowForDebug?.convert(actionRowForDebug!.bounds, to: self) ?? .zero }
    public var debugStatsFrame: CGRect { statsRow.convert(statsRow.bounds, to: self) }
    /// The counter row's cells, leading to trailing (#687).
    public var debugStatCellFrames: [CGRect] { statsRow.arrangedSubviews.map { $0.convert($0.bounds, to: self) } }
    /// Each counter's frame, in order, nil while hidden.
    public var debugStatFrames: [CGRect?] {
        counters.map { $0.isHidden ? nil : $0.convert($0.bounds, to: self) }
    }
    /// The two halves beside the avatar: name + handle, then the counters.
    public var debugNameHalfFrame: CGRect {
        identityColumn.arrangedSubviews[0].convert(identityColumn.arrangedSubviews[0].bounds, to: self)
    }
    public var debugStatsHalfFrame: CGRect {
        identityColumn.arrangedSubviews[1].convert(identityColumn.arrangedSubviews[1].bounds, to: self)
    }
    public var debugBannerIsHidden: Bool { bannerView.isHidden }
    public var debugBannerShowsBlur: Bool { bannerView.debugShowsBlur }
    public var debugBannerRampTone: UIColor { bannerView.debugRampTone }
    public var debugBannerShowsRamp: Bool { bannerView.debugShowsRamp }
    /// The action row's views, leading to trailing.
    public var debugTrayViews: [UIView] { actionRow.arrangedSubviews }
    /// The banner's fade, in the HEADER's coordinates — the banner's at
    /// rest, which is what it is given in.
    public var debugBannerFade: HeroBannerFade.Geometry? { bannerView.debugFade }
    /// The blur levels showing, in the header's coordinates.
    public var debugBannerBlurLevels: [(start: CGFloat, full: CGFloat)] { bannerView.debugBlurLevels }
    public var debugBannerRampLocations: [CGFloat] { bannerView.debugRampLocations }
    public var debugBannerRampAlphas: [CGFloat] { bannerView.debugRampAlphas }
    /// How much of the banner shows — its veil's complement (a poster's
    /// fade is a page-toned veil, not the view's alpha).
    public var debugBannerAlpha: CGFloat { bannerView.visibility }
    public var debugBannerPictureShift: CGFloat { bannerView.debugPictureShift }
    public var debugBannerHasPicture: Bool { bannerView.debugHasPicture }
    public var debugBlurBakeMilliseconds: Double { bannerView.debugLastBlurBakeMilliseconds }
    public var debugBlurBakeBytes: Int { bannerView.debugLastBlurBakeBytes }
    public var debugNameInk: UIColor { nameLabel.textColor }
    /// Puts `ink` on the name, wrong or not — for a test that proves the
    /// contrast instrument still sees a failure.
    public func debugForceNameInk(_ ink: UIColor) { nameLabel.textColor = ink }
    public var debugHandleInk: UIColor { handleLabel.textColor }
    public var debugNameShadowOpacity: Float { nameLabel.layer.shadowOpacity }
    /// The ink each block on the picture wears: name + handle, counters, bio.
    public var debugInkTones: (name: HeroInk.Tone, counters: HeroInk.Tone, body: HeroInk.Tone) {
        (inkTones.name, inkTones.counters, inkTones.body)
    }
    public var debugNameFrame: CGRect { nameLabel.convert(nameLabel.bounds, to: self) }
    public var debugHandleFrame: CGRect { handleLabel.convert(handleLabel.bounds, to: self) }
    private weak var actionRowForDebug: UIView?

    /// WCAG contrast of the name and the handle against the pixels rendered
    /// behind them, over the page — see `HeroInk.debugContrast`. Used by
    /// `ProfileIdentityInkTests` and the `-profile-ink-audit` launch argument.
    public func debugIdentityContrast() -> (name: HeroInkContrast, handle: HeroInkContrast)? {
        guard let measured = HeroInk.debugContrast(
            of: [nameLabel, handleLabel], in: self, over: Surface.page
        ), measured.count == 2 else { return nil }
        return (measured[0], measured[1])
    }

    /// The same for what stands below the name — the first counter's value
    /// and caption, and the bio — labelled, for the audit: on a poster they
    /// stand on the picture too.
    public func debugBodyContrast() -> [(String, HeroInkContrast)]? {
        let labels = leadCounter.debugLabels + (bioLabel.isHidden ? [] : [bioLabel])
        guard let measured = HeroInk.debugContrast(of: labels, in: self, over: Surface.page) else { return nil }
        // The lead counter by its caption ("followers" on a profile).
        let lead = leadCounter.accessibilityLabel?.lowercased() ?? "counter"
        return zip([lead, "caption", "bio"], measured).map { ($0, $1) }
    }
    #endif

    /// The action row.
    private weak var actionRowView: UIView?

    /// Whether the action row is shown. The profile card sheet (#1524)
    /// hides it: its actions are the sheet's own bars.
    public var showsActionTray = true {
        didSet {
            guard showsActionTray != oldValue else { return }
            actionRowView?.isHidden = !showsActionTray
            layoutRevision += 1
        }
    }

    /// The action row's foot in `view`'s space: once it has scrolled under
    /// the navigation bar, the bar takes the relationship over (the owner,
    /// 2026-10-15).
    public func actionTrayMaxY(in view: UIView) -> CGFloat? {
        guard let row = actionRowView else { return nil }
        return row.convert(row.bounds, to: view).maxY
    }

    /// The bubbles' side, and so the action row's height.
    public static let bubbleSize = Metrics.bubbleSize

    /// Fills the action row, leading to trailing. The capsules hug nothing
    /// and give way first, sharing the width the bubbles leave; each bubble
    /// is a circle `bubbleSize` across.
    public func setActions(_ actions: [HeroHeaderAction]) {
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        NSLayoutConstraint.deactivate(bubbleConstraints)
        bubbleConstraints = []
        for action in actions {
            switch action {
            case .capsule(let capsule):
                capsule.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
                capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                actionRow.addArrangedSubview(capsule)
            case .bubble(let bubble):
                actionRow.addArrangedSubview(bubble)
                // The diameter is 999, not required: on the narrowest devices
                // the row can overrun, and the bubbles shaving a point
                // (staying circular via the required square tie) beats an
                // unsatisfiable-constraints break.
                let diameter = bubble.widthAnchor.constraint(equalToConstant: Metrics.bubbleSize)
                diameter.priority = UILayoutPriority(999)
                let round = [diameter, bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor)]
                NSLayoutConstraint.activate(round)
                bubbleConstraints += round
            }
        }
        layoutRevision += 1
    }

    /// The bubbles' sides, let go when the row is filled again.
    private var bubbleConstraints: [NSLayoutConstraint] = []

    /// Invoked with the content's website URL when the link row is tapped.
    public var onWebsiteTapped: ((URL) -> Void)?
    private let imagePipeline: ImagePipeline

    /// Whether both pictures — the avatar and the banner — have stopped
    /// changing: drawn, absent, or failed. What a push waits for so the
    /// header it shows is the one that stays (no initials that become a face,
    /// no banner shape decided after the slide).
    public var arePicturesSettled: Bool { (avatar?.isSettled ?? true) && bannerView.isPictureSettled }
    /// Fires when either picture settles after a fetch.
    public var onPicturesSettled: (() -> Void)?
    private var websiteURL: URL?

    /// - Parameters:
    ///   - counters: the counters' captions, in order — at least one.
    ///   - avatar: what stands in the disc.
    public init(imagePipeline: ImagePipeline, counters captions: [String], avatar slot: HeroHeaderAvatar = .person) {
        precondition(!captions.isEmpty, "a hero header counts at least one thing")
        self.imagePipeline = imagePipeline
        counters = captions.map { HeroStatView(caption: $0) }
        switch slot {
        case .person:
            avatar = AvatarView(diameter: Metrics.avatarSize, size: .px512)
            customAvatar = nil
        case .custom(let view):
            avatar = nil
            customAvatar = view
        }
        bannerView = HeroBannerView(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        // Large and alone on its screen: an animated avatar plays once on the
        // page's first display, scroll or not (#1358), a beat after it is
        // shown (#1424).
        avatar?.animationTrigger = .firstAppearance(AnimatedAvatarScope())
        configureSubviews()
        // The picture decides the shape, whenever it lands.
        bannerView.onImageResolved = { [weak self] image in
            self?.setBannerFormat(.resolved(forImageSize: image.size))
        }
        bannerView.onPictureSettled = { [weak self] in self?.onPicturesSettled?() }
        bannerView.onPicturePresenceChange = { [weak self] in self?.applyIdentityInk() }
        // The blurred picture decides the type's ink — read it again the
        // moment it changes. Off the bake's own dissolve (it lands inside
        // one) when on screen, so the ink's change is its own.
        bannerView.onLevelsChanged = { [weak self] in
            guard let self else { return }
            guard isInVisibleWindow else { return updateInkTones(force: true) }
            DispatchQueue.main.async { [weak self] in self?.updateInkTones(force: true) }
        }
        setBannerFormat(.unresolved)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Configuration

    /// Applies `content`, touching only what differs from the content already
    /// on screen.
    ///
    /// ⚠️ A REFRESH LANDS HERE, AND MOSTLY WITH NEWS FOR ONE NUMBER. Each
    /// write below re-measures its view — the website button rebuilds its
    /// configuration, the bio re-lays its emotes — and the header's height is
    /// measured again after any of them (`layoutRevision`). The same content
    /// again does nothing at all, and does NOT supersede a staggered apply
    /// still landing it.
    public func configure(with content: HeroHeaderContent) {
        guard content != appliedContent else { return }
        // Supersedes any staggered group still waiting to land.
        configureGeneration += 1
        layoutRevision += 1
        #if DEBUG
        debugConfigureCount += 1
        #endif
        // Nil when the screen's state is not a content's: first configure,
        // under the bones, or a staggered apply cut short. Then everything.
        let old = appliedContent
        appliedContent = content
        func changed<T: Equatable>(_ field: KeyPath<HeroHeaderContent, T>) -> Bool {
            guard let old else { return true }
            return old[keyPath: field] != content[keyPath: field]
        }
        if changed(\.avatarMonogram) { avatar?.setMonogram(content.avatarMonogram) }
        if changed(\.avatarFrameID) { avatar?.frameID = content.avatarFrameID }
        if changed(\.title) { nameLabel.text = content.title }
        if changed(\.subtitle) { handleLabel.text = content.subtitle }
        if changed(\.isVerified) { verifiedBadge.isHidden = !content.isVerified }

        if changed(\.bio) { applyBio(content.bio) }

        websiteURL = content.websiteURL
        if changed(\.websiteText) {
            websiteButton.configuration?.title = content.websiteText
            websiteButton.isHidden = content.websiteText == nil
        }

        for (index, counter) in counters.enumerated() {
            let value = content.counterValue(at: index)
            if old?.counterValue(at: index) != value || old == nil { counter.setValue(value) }
        }

        applyBanner(content)
        loadAvatar(content.avatarURL)
    }

    /// The content whose every field is on screen — nil until one is, and
    /// again whenever something else wrote over them (the bones, a staggered
    /// apply).
    private var appliedContent: HeroHeaderContent?

    /// Bumped by everything that can change how tall the header is: content,
    /// the bones, the action row, the banner's shape, the chrome it starts
    /// under. The screen measures the header again only when this (or the
    /// width, the safe area, Dynamic Type) moved — never because it scrolled.
    public private(set) var layoutRevision = 0

    /// For a page kind changing what the header holds (its action row's
    /// state): the header is measured again.
    public func noteLayoutChange() { layoutRevision += 1 }

    #if DEBUG
    /// How many configures actually applied something — what a refresh that
    /// brought nothing new must leave untouched.
    public private(set) var debugConfigureCount = 0
    #endif

    private func applyBio(_ bio: String?) {
        bioLabel.text = bio ?? ""
        bioLabel.isHidden = bio == nil
    }

    /// No picture, no banner — and a picture arriving on a header that had
    /// none takes the unresolved shape until it has said which it is.
    private func applyBannerPresence(_ url: URL?, pending: Bool = false) {
        if url == nil, !pending {
            setBannerFormat(.none)
        } else if bannerFormat == .none {
            setBannerFormat(.unresolved)
        }
    }

    /// The banner's presence, picture and loop — or its skeleton while a
    /// banner may still come (`bannerPending`).
    private func applyBanner(_ content: HeroHeaderContent) {
        let awaiting = content.bannerImageURL == nil && content.bannerPending
        applyBannerPresence(content.bannerImageURL, pending: awaiting)
        if awaiting {
            bannerView.awaitImage()
        } else {
            bannerView.setImageURL(content.bannerImageURL)
        }
        bannerView.setVideoURL(content.bannerVideoURL, pool: bannerVideoPool)
    }

    /// Applies `content` as a set of small, lightly staggered cross-dissolves
    /// — one per element group — instead of one transition over the whole
    /// header.
    ///
    /// A single dissolve across the header is uniform but flat: everything
    /// blinks over at once, so a switch reads as the screen being replaced
    /// rather than as one identity becoming another. Grouping lets the parts
    /// that answer "who is this" resolve first, with the numbers and the prose
    /// following a beat later.
    ///
    /// Each group is a real `UIView.transition`, so its OWN old content is what
    /// dissolves away. That is why the stagger is a delayed transition rather
    /// than an alpha ramp: fading a group in from zero would blank every group
    /// at t=0 and then bring them back in sequence, which flickers.
    ///
    /// Falls back to a plain apply when the view is off screen — an animation
    /// nobody can see is a frame cost and a chance for the snapshot to land at
    /// the wrong size.
    public func configure(with content: HeroHeaderContent, staggered: Bool) {
        guard staggered, window != nil else {
            configure(with: content)
            return
        }
        configureGeneration += 1
        let generation = configureGeneration
        // Lands over three dispatches: until the last, the screen is no one
        // content, and the next plain configure must apply everything.
        appliedContent = nil
        // Identity first: the banner's colour field and the avatar carry most of
        // the "this is someone else now" signal, and the name says it outright.
        dissolve([bannerView, avatarView, nameLabel, handleLabel, verifiedBadge], after: 0, generation: generation) {
            self.avatar?.setMonogram(content.avatarMonogram)
            self.avatar?.frameID = content.avatarFrameID
            self.nameLabel.text = content.title
            self.handleLabel.text = content.subtitle
            self.verifiedBadge.isHidden = !content.isVerified
            self.applyBanner(content)
            self.loadAvatar(content.avatarURL)
        }
        dissolve(counters, after: Metrics.stagger, generation: generation) {
            for (index, counter) in self.counters.enumerated() {
                counter.setValue(content.counterValue(at: index))
            }
        }
        dissolve([bioLabel, websiteButton], after: Metrics.stagger * 2, generation: generation) {
            self.applyBio(content.bio)
            self.websiteURL = content.websiteURL
            self.websiteButton.configuration?.title = content.websiteText
            self.websiteButton.isHidden = content.websiteText == nil
        }
    }

    /// Cross-dissolves `views` around `changes`, optionally after a delay.
    ///
    /// The delay is a dispatch hop rather than an animation delay because
    /// `UIView.transition` takes none — and a transition is what is needed here,
    /// not an alpha animation (see `configure(with:staggered:)`).
    ///
    /// Structural changes (a bio appearing, a website row going away) are made
    /// inside the transition on purpose: they alter this group's own height, and
    /// letting them ride the dissolve is what stops the column below from
    /// jumping while the text is still half faded.
    ///
    /// ⚠️ **A DELAYED GROUP IS DROPPED IF ANY LATER CONFIGURE HAS LANDED.** Each
    /// group captures its own call's model; a render that arrived inside the
    /// 0.05–0.10 s stagger — a fresh fetch applied plainly because the header
    /// had left the window — was then overwritten by the older model's stats and
    /// bio, until the next render. `generation` is the call's; the delayed
    /// groups run only while it is still the newest.
    private func dissolve(
        _ views: [UIView], after delay: TimeInterval, generation: Int,
        _ changes: @escaping () -> Void
    ) {
        let run = {
            self.layoutRevision += 1
            var pending = views
            guard let first = pending.popLast() else { return changes() }
            // Nested so every view dissolves within ONE animation block: separate
            // transitions on siblings drift apart under load, and these are
            // meant to read as a single group changing together.
            let inner: () -> Void = pending.reduce(changes) { accumulated, view in
                {
                    UIView.transition(
                        with: view, duration: Metrics.dissolve,
                        options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                        animations: accumulated
                    )
                }
            }
            UIView.transition(
                with: first, duration: Metrics.dissolve,
                options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                animations: inner
            )
        }
        guard delay > 0 else { return run() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.configureGeneration else { return }
            run()
        }
    }

    #if DEBUG
    public var debugIsRedacted: Bool { isRedacted }
    public var debugHasAvatarPicture: Bool { avatar?.shownPicture != nil }
    #endif

    // MARK: - Redaction

    private var isRedacted = false
    private var redactionBones: [SkeletonBoneView] = []

    /// Structural skeleton state: the redacted header IS the real header. The
    /// same views, constraints, and fonts carry the layout — each awaiting
    /// label holds a blank line of placeholder text so its metric height (and
    /// everything derived from it: the identity column, the avatar span, the
    /// banner's bottom threshold) resolves exactly where content will land —
    /// while shimmer bones anchored to those very elements mask the missing
    /// values. The glass tray and stat captions are chrome, not content, and
    /// stay real. Reveal (`redacted: false`, called after `configure(with:)`
    /// has swapped real text in under the invisible labels) trades only
    /// alphas, so hydration cannot shift a single pixel of structure.
    public func setRedacted(_ redacted: Bool, animated: Bool = false) {
        guard redacted != isRedacted else { return }
        isRedacted = redacted
        layoutRevision += 1

        if redacted {
            // The ballast below writes over the labels: no model is on
            // screen any more.
            appliedContent = nil
            // Layout ballast: one blank line per single-line label, and ONE
            // for the bio (#1757): a profile never seen has a bio of unknown
            // length, or none, and two reserved lines made a one-line bio pull
            // everything below up a line at the reveal (the owner's recording).
            // One is the likeliest, so the smallest step on average; a profile
            // seen before skips the skeleton entirely (its cache draws the
            // header on the first frame). The website row is reserved too —
            // hiding it here and inserting it at reveal would push the whole
            // gallery down mid-fade (most profiles carry a link; a linkless
            // one collapses the row as a content change, not a reveal jump).
            nameLabel.text = " "
            handleLabel.text = " "
            bioLabel.text = " "
            bioLabel.isHidden = false
            websiteButton.configuration?.title = " "
            websiteButton.isHidden = false
            installRedactionBones()
            // Everything data-driven drops to alpha 0 in place — the badge
            // included, so a verified profile fades it in with the name
            // instead of popping it beside the finished text.
            for view in [nameLabel, handleLabel, bioLabel, websiteButton, verifiedBadge] {
                view.alpha = 0
            }
            for bone in redactionBones { bone.isHidden = false; bone.alpha = 1 }
            for stat in counters {
                stat.setRedacted(true)
            }
            bannerView.setRedacted(true)
            return
        }

        // Alpha-only choreography: `configure(with:)` has already committed
        // the real content (and any structural truth like a hidden website
        // row) OUTSIDE this animation, so nothing here can move — the bones
        // dissolve and the content materializes exactly where they were.
        let reveal = {
            for view in [
                self.nameLabel, self.handleLabel, self.bioLabel,
                self.websiteButton, self.verifiedBadge
            ] {
                view.alpha = 1
            }
            for bone in self.redactionBones { bone.alpha = 0 }
            for stat in self.counters {
                stat.setRedacted(false)
            }
            self.bannerView.setRedacted(false)
        }
        let finish = {
            for bone in self.redactionBones { bone.isHidden = true }
        }
        guard animated else {
            reveal()
            finish()
            return
        }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            reveal()
        } completion: { _ in
            // Re-entered redaction mid-fade keeps its bones up.
            guard !self.isRedacted else { return }
            finish()
        }
    }

    /// One-time overlay construction, anchored to the real elements so the
    /// bones inherit their exact resolved positions.
    private func installRedactionBones() {
        guard redactionBones.isEmpty else { return }

        // The avatar's own clipping rounds the bone; the ring border draws
        // above it, staying crisp.
        let avatarBone = SkeletonBoneView(rounding: .fixed(0))
        avatarBone.pin(to: avatarView)

        let nameBone = SkeletonBoneView()
        nameBone.constrain(in: self) { _ in
            nameBone.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor)
            nameBone.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor)
            nameBone.widthAnchor.constraint(equalToConstant: 148)
            nameBone.heightAnchor.constraint(equalToConstant: 16)
        }

        let handleBone = SkeletonBoneView()
        handleBone.constrain(in: self) { _ in
            handleBone.leadingAnchor.constraint(equalTo: handleLabel.leadingAnchor)
            handleBone.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor)
            handleBone.widthAnchor.constraint(equalToConstant: 92)
            handleBone.heightAnchor.constraint(equalToConstant: 12)
        }

        // One caption-pitch bar inside the bio's one placeholder line,
        // short of the column's width, as a bio's line usually is.
        let bioFirst = SkeletonBoneView()
        bioFirst.constrain(in: self) { _ in
            bioFirst.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor)
            bioFirst.widthAnchor.constraint(equalTo: bioLabel.widthAnchor, multiplier: 0.8)
            bioFirst.centerYAnchor.constraint(equalTo: bioLabel.centerYAnchor)
            bioFirst.heightAnchor.constraint(equalToConstant: 12)
        }

        let websiteBone = SkeletonBoneView()
        websiteBone.constrain(in: self) { _ in
            websiteBone.leadingAnchor.constraint(equalTo: websiteButton.leadingAnchor)
            websiteBone.centerYAnchor.constraint(equalTo: websiteButton.centerYAnchor)
            websiteBone.widthAnchor.constraint(equalToConstant: 120)
            websiteBone.heightAnchor.constraint(equalToConstant: 12)
        }

        redactionBones = [avatarBone, nameBone, handleBone, bioFirst, websiteBone]
    }

    /// The quiet buttons' opaque grey — `HeroTray.fill`, which `AppButton`'s
    /// quiet ground wears (see `HeroTray` for why flat and opaque).
    public static let trayFill = HeroTray.fill

    /// The face over the initials. Synchronously from the cache when it can,
    /// as the banner does: the picture is usually already decoded (the origin
    /// drew it — a chat pill, a feed row). ⚠️ AT ITS SIZE, NOT FULL (#1086):
    /// 96 pt is a 512 px decode; the origin's `.avatar` decode stands in (soft
    /// for a beat, never the initials) while the sharp one decodes, and a push
    /// does not wait for the sharper one. A fetched face (or its failure)
    /// tells `onPicturesSettled`.
    private func loadAvatar(_ url: URL?) {
        avatar?.setPicture(url, pipeline: imagePipeline)
    }

    // MARK: - Layout

    @objc private func avatarTapped() {
        avatar?.animation.replay()
    }

    private func configureSubviews() {
        // Avatar: a filled circle with a monogram, overlaid by the image once
        // loaded. The ring keeps it defined while it floats over raw banner
        // media, above the fade.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.clipsToBounds = true
        avatarView.layer.borderWidth = Metrics.avatarRingWidth
        // The ring is the page's tone, so the avatar reads as cut from the
        // page it floats over rather than wearing a whiter halo.
        avatarView.layer.borderColor = Surface.page.resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: HeroHeaderView, _) in
            self.avatarView.layer.borderColor = Surface.page.resolvedColor(with: self.traitCollection).cgColor
        }

        if let avatar {
            avatar.standInSize = .avatar
            avatar.onSettledAfterLoad = { [weak self] in self?.onPicturesSettled?() }
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatarView.addSubview(avatar)
            // A tap replays an animated avatar, every time (#1424). A still
            // one does nothing.
            avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
            NSLayoutConstraint.activate([
                avatar.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
                avatar.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            ])
        } else if let customAvatar {
            // Sized by the disc alone: a picture's intrinsic size must not
            // vote (see `CircleAvatarView`).
            for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
                customAvatar.setContentHuggingPriority(.init(1), for: axis)
                customAvatar.setContentCompressionResistancePriority(.init(1), for: axis)
            }
            customAvatar.pin(to: avatarView)
        }
        // The avatar's side length is resolved by layout (it tracks the
        // identity column), so the monogram scales off the resolved frame —
        // reported by the avatar itself, whose layout pass is the first to
        // see the final size (the header's runs too early for nested stacks).
        avatarView.onSideLengthChange = { [weak self] side in
            guard let self, side > 0 else { return }
            // The disc (initials and face) follows the frame's side.
            self.avatar?.setDiameter(side)
            // The disc's frame is final here — see `placeBannerFade`.
            self.placeBannerFade()
        }

        // The counter row (#687, the owner's call 2026-10-08): the identity
        // column's whole width, beside the avatar and under the name, in
        // ONE EQUAL CELL PER COUNTER — a profile's Followers, Following and
        // Likes, a place's Ranking and Likes — each centred in its cell (the
        // owner, 2026-10-15: the profile's fourth, kept empty for a metric to
        // come, is gone).
        // Each counter sits in a cell of its own, so one with no value (a
        // hidden like count) leaves its cell empty and the others stay put;
        // a counter never grows past its cell (it shrinks to fit inside it).
        for stat in counters {
            statsRow.addArrangedSubview(Self.statCell(holding: stat))
        }
        statsRow.axis = .horizontal
        statsRow.alignment = .center
        statsRow.distribution = .fillEqually
        statsRow.spacing = 0

        // Type hierarchy of the identity block, three clear steps: title3
        // semibold display name (the block's anchor; SF applies its tighter
        // large-size tracking automatically), subheadline secondary @handle,
        // subheadline bio below — name > handle = body copy, one weight jump.
        nameLabel.font = UIFont.scaledFont(forTextStyle: .title3, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        // Page ink until a banner says otherwise — see `applyIdentityInk`.
        nameLabel.textColor = Self.pageNameInk
        // Two lines, not one (#482): at accessibility sizes a one-line name
        // was cut to its first few letters.
        nameLabel.numberOfLines = 2

        handleLabel.font = .appFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = Self.pageHandleInk
        handleLabel.numberOfLines = 1
        // The two lines decide how tall the identity row's halves must be at
        // a large Dynamic Type size; the avatar's side must not squash them
        // (it is only `.defaultHigh`, the labels' default resistance).
        for label in [nameLabel, handleLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        verifiedBadge.tintColor = .systemBlue
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)

        bioLabel.font = .appFont(forTextStyle: .subheadline)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 0
        // Over the banner the bio's ink is `HeroInk`'s: its tokens keep it,
        // in semibold (#524).
        bioLabel.textEntityStyle = .emphasis
        bioLabel.opensTextEntities = true

        // Name + verified badge sit on one line; a spacer keeps them leading
        // while the row itself stretches with the fill-aligned column.
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, verifiedBadge, UIView()])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs
        NSLayoutConstraint.activate([
            verifiedBadge.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            verifiedBadge.heightAnchor.constraint(equalToConstant: Metrics.badgeSize)
        ])

        // The action row (`setActions`) closes the header, the page's width
        // under the bio.
        // ⚠️ A FULL-WIDTH ROW UNDER THE BIO, not a line beside the avatar:
        // the column beside the disc is the title, the subtitle and the
        // counters alone (a profile's two capsules and two bubbles need
        // ~300pt, and that column has ~240).
        actionRowView = actionRow
        actionRow.axis = .horizontal
        actionRow.alignment = .fill
        actionRow.distribution = .fill
        actionRow.spacing = Spacing.sm

        // Beside the avatar, two halves of its height: name over @handle in
        // the top one, on the picture; the counters in the bottom one, on
        // the page. `fillEqually` keeps the halves equal when a large
        // Dynamic Type size grows one of them.
        //
        // ⚠️ PUSHED APART, not centred: the name to the top of its half (level
        // with the disc's top), the counters to the foot of theirs (level with
        // its foot). The page's ramp is centred on the seam between them, and
        // centred content left it ~4pt between the handle's foot and the
        // counters' top — the ramp then whitened the handle's last rows and
        // left the counters' values on a mostly-picture ground. Pushed apart,
        // the seam has ~8pt of air for the ramp to cross.
        nameBlock.addArrangedSubview(nameRow)
        nameBlock.addArrangedSubview(handleLabel)
        nameBlock.axis = .vertical
        nameBlock.alignment = .fill
        nameBlock.spacing = 2
        let nameHalf = UIView()
        let statsHalf = UIView()
        let nameTop = nameBlock.topAnchor.constraint(equalTo: nameHalf.topAnchor)
        nameBlockTop = nameTop
        nameBlock.constrain(in: nameHalf) { half in
            nameBlock.leadingAnchor.constraint(equalTo: half.leadingAnchor)
            nameBlock.trailingAnchor.constraint(equalTo: half.trailingAnchor)
            nameTop
            nameBlock.bottomAnchor.constraint(lessThanOrEqualTo: half.bottomAnchor)
        }
        statsRow.constrain(in: statsHalf) { half in
            statsRow.leadingAnchor.constraint(equalTo: half.leadingAnchor)
            statsRow.trailingAnchor.constraint(equalTo: half.trailingAnchor)
            statsRow.topAnchor.constraint(greaterThanOrEqualTo: half.topAnchor)
            statsRow.bottomAnchor.constraint(equalTo: half.bottomAnchor)
        }
        identityColumn.addArrangedSubview(nameHalf)
        identityColumn.addArrangedSubview(statsHalf)
        identityColumn.axis = .vertical
        identityColumn.alignment = .fill
        identityColumn.distribution = .fillEqually

        topRow.addArrangedSubview(avatarView)
        topRow.addArrangedSubview(identityColumn)
        topRow.axis = .horizontal
        // Top: the column is the avatar's height (see the tie below), and
        // when a large Dynamic Type size outgrows the avatar's cap, the two
        // still share their top edge.
        topRow.alignment = .top
        topRow.spacing = Spacing.md
        #if DEBUG
        actionRowForDebug = actionRow
        #endif

        var websiteConfig = UIButton.Configuration.plain()
        websiteConfig.image = UIImage(systemName: "link")
        websiteConfig.imagePadding = Spacing.xs
        websiteConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        websiteConfig.baseForegroundColor = Palette.entityInk
        websiteConfig.contentInsets = .zero
        websiteConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)
            return attributes
        }
        websiteButton.configuration = websiteConfig
        websiteButton.contentHorizontalAlignment = .leading
        websiteButton.isHidden = true
        websiteButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let websiteURL = self.websiteURL else { return }
                self.onWebsiteTapped?(websiteURL)
            },
            for: .primaryActionTriggered
        )

        // Page column: the identity row (avatar | name/@handle over the
        // counters), then full width — bio, website and the tray closing the
        // header right above the content threshold. Wider vertical rhythm
        // than the standard xs-step stacks: the header sits against a
        // full-bleed banner and needs air between its major containers to
        // read premium.
        let column = UIStackView(arrangedSubviews: [topRow, bioLabel, websiteButton, actionRow])
        identityBlock = column
        column.axis = .vertical
        column.alignment = .fill
        // Air between the block's rows: a step more than the standard stack
        // at every seam, because this block sits alone under a picture and
        // read as packed at the standard pitch — tray on the bio.
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.lg, after: topRow)
        column.setCustomSpacing(Spacing.md, after: bioLabel)
        column.setCustomSpacing(Spacing.md, after: websiteButton)
        // The tray carries its own air above, so the gap holds whether the
        // row before it is the website or the bio.
        actionRow.isLayoutMarginsRelativeArrangement = true
        actionRow.directionalLayoutMargins.top = Metrics.trayGap
        // 999: a hidden tray (`showsActionTray`) collapses to nothing.
        let trayHeight = actionRow.heightAnchor.constraint(equalToConstant: Metrics.bubbleSize + Metrics.trayGap)
        trayHeight.priority = UILayoutPriority(999)
        trayHeight.isActive = true

        // Layering: banner first (back), identity column on top of it — the
        // screen may move the banner further back, behind its content
        // (`moveBanner`). The banner bleeds to the header's very top — the
        // column starts below the navigation chrome via `chromeTopInset`.
        //
        // The top attachment is deliberately soft (high, not required): the
        // owning controller adds a required ≤-viewport-top constraint via
        // `anchorBanner(toViewportTop:)`, and downward overscroll must be able
        // to break this equality so the banner stretches instead of sliding
        // down with the content and exposing the scroll view's background.
        addSubview(bannerView)

        let columnTop = column.topAnchor.constraint(
            equalTo: topAnchor, constant: columnTopConstant
        )
        columnTopConstraint = columnTop
        let floor = column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: columnTopConstant)
        columnTopFloor = floor
        let bandLine = avatarView.centerYAnchor.constraint(equalTo: topAnchor, constant: bandAvatarLineConstant)
        bandLine.priority = .init(999)
        bandAvatarLine = bandLine
        column.constrain(in: self) { parent in
            columnTop
            floor
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.horizontalInset)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.horizontalInset)
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.xl)
        }

        // The avatar is a fixed disc, and the column beside it its height —
        // half for the name, half for the counters.
        //
        // The side is high, not required, and the column's tie to it 999: a
        // Dynamic-Type name that needs more than half the disc grows the
        // column, the disc follows it up to its cap, and past the cap the
        // column simply outgrows it rather than clipping a label.
        let avatarSide = avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        avatarSide.priority = .defaultHigh
        let columnSpansAvatar = identityColumn.heightAnchor.constraint(equalTo: avatarView.heightAnchor)
        columnSpansAvatar.priority = UILayoutPriority(999)
        // Where the banner ENDS is the shape's — see `constrainBanner`.
        constrainBanner()
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalTo: avatarView.heightAnchor),
            avatarSide,
            avatarView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.avatarMaxSize),
            columnSpansAvatar,
            identityColumn.heightAnchor.constraint(greaterThanOrEqualTo: avatarView.heightAnchor)
        ])
    }

    public override func layoutSubviews() {
        // The fonts scale with the text size: the even air follows them.
        if let foot = bandFootAtCounters, foot.constant != leadCounter.evenAirEdge {
            foot.constant = leadCounter.evenAirEdge
        }
        if let baseline = bandHandleBaseline, baseline.constant != bandHandleBaselineConstant {
            baseline.constant = bandHandleBaselineConstant
        }
        super.layoutSubviews()
        // The nested stacks settle AFTER this pass — the note on
        // `CircleAvatarView` — so they are settled here by hand before the
        // frames are read: the fade is placed against where the name and the
        // avatar actually are, not where they were a pass ago.
        topRow.superview?.layoutIfNeeded()
        placeBannerFade()
    }

    /// Hands the banner its run-out from where the avatar actually stands.
    ///
    /// ⚠️ ALSO CALLED WHEN THE AVATAR IS SIZED (`onSideLengthChange`). On a
    /// fresh push the header's first — and, until a scroll, ONLY — pass saw
    /// the disc still at zero size even after settling the stacks above:
    /// the guard below returned, the banner never got a fade, and its baked
    /// blur levels stayed hidden until a scroll moved the header and ran a
    /// second pass (user, on device, 30 September 2026: "the blur doesn't
    /// appear until you scroll"; `-hero-blur-trace` showed `avatar=(20, 316,
    /// 0, 0)` then `fade=nil … shown=0/6`). The disc's own layout is the
    /// moment its frame is final, so it places the fade too.
    private func placeBannerFade() {
        guard bannerFormat != .none else { return }
        // In the header's space, which is the banner's AT REST: its top
        // rests on the header's, and a pull-down that stretches it above
        // must not move the fade (see `HeroBannerPictureView`).
        let avatar = avatarView.convert(avatarView.bounds, to: self)
        // In the header's space wherever the banner stands (`moveBanner`).
        let foot = bannerView.convert(bannerView.bounds, to: self).maxY
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-hero-blur-trace") {
            print("HERO-BLUR header fade format=\(bannerFormat) avatar=\(avatar) foot=\(foot)")
        }
        #endif
        guard avatar.height > 0, foot > avatar.minY else { return }
        // One container for both shapes: from just above the avatar to the
        // banner's foot — the avatar's midline on a band, the tray's foot on
        // a poster — the blur and the page's tone climbing it together.
        var fade = HeroBannerFade.geometry(identityTop: avatar.minY, foot: foot)
        if bannerFormat == .band {
            // ⚠️ A BAND NO LONGER BLURS, AND ITS RAMP IS BLACK (user, 5
            // October 2026) — so it is SHOULDERED, as a poster's: with no
            // blur to calm the strip, only the ramp closes the picture's
            // spread under the name and the handle, and over half of it
            // (`shoulderAlpha`) the ground is always on one side of the inks'
            // crossover — white type over any picture. (Unshouldered, the
            // black arrived only under the handle's foot: a white strip took
            // a dark ink there, then the black came up under it — 1.1:1.)
            // The name rides its handle on a band card (even air above the
            // foot), and can stand above the avatar's top: the ramp starts
            // from whichever is higher, so the type never stands above it.
            let name = nameBlock.convert(nameBlock.bounds, to: self)
            let top = name.height > 0 ? min(avatar.minY, name.minY) : avatar.minY
            fade = HeroBannerFade.shoulderedGeometry(identityTop: top, foot: foot)
            // Whole by the handle's foot, as when the band ended there: the
            // card's foot now stands lower (even air over the counters), and
            // a ramp stretched to it was too thin under the name for AA.
            let handleFoot = handleLabel.convert(handleLabel.bounds, to: self).maxY
            if handleFoot > fade.rampStart, handleFoot < fade.rampEnd {
                fade.rampEnd = handleFoot
            }
        }
        bannerView.setFade(fade)
        updateInkTones()
    }

}

/// An image view that stays a circle whatever side length layout resolves for
/// it. The rounding must live here — in the bounds' owner — because ancestor
/// `layoutSubviews` runs before nested stack views hand this view its final
/// frame, and would round a stale size.
private final class CircleAvatarView: UIView {
    var onSideLengthChange: ((CGFloat) -> Void)?

    /// The avatar is sized purely by constraints. A loaded bitmap must not
    /// vote: even at floor priorities an image view's intrinsic size is an
    /// unopposed preference that distorts any non-required sizing around it
    /// (it once dragged a span equality to its cap, stretching the identity
    /// rows apart).
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        onSideLengthChange?(bounds.height)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }
}
