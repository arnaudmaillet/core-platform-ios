import MapsInterface
import MediaCore
import DesignSystem
import UIKit

/// The profile identity block, layered over an immersive media banner:
/// `ProfileBannerView` runs from the very top of the screen (under the status
/// bar and transparent navigation bar) down to the bottom of the action tray,
/// and the identity content sits directly on top of it. The banner's bottom
/// fade dissolves into `systemBackground` under the identity rows, so they
/// keep standard dynamic label colors.
///
/// Identity anatomy:
/// - a tall banner-viewing window under the chrome (`Metrics.bannerClearance`
///   of raw media) — the relationship button lives in the navigation bar
///   (owned by `ProfileViewController`), NOT in this view;
/// - then the two-column identity block — circular avatar left, sized to span
///   the three lines beside it: display name + verified badge, @handle, and
///   the flat action tray (a leading Message-or-Edit-Profile capsule,
///   then QR-code and see-more bubbles trailing-aligned);
/// - below, full width: the 4-metric counter row (Followers / Following /
///   Reactions / Views) directly under the identity block, then bio and
///   website link closing the header right above the content threshold. The
///   banner ends at the TRAY's bottom (the identity block's baseline); the
///   counters and bio sit on plain background.
/// Pure presentation — it is handed a finished `ProfileDisplayModel` and an
/// `ImagePipeline`; it owns no data.
final class ProfileHeaderView: UIView {
    private enum Metrics {
        /// One element group's cross-dissolve on an account switch.
        static let dissolve: TimeInterval = 0.24
        /// Gap between groups. Small enough to read as one flowing change
        /// rather than three separate ones.
        static let stagger: TimeInterval = 0.05
        /// The avatar's side — what the disc resolved to while it spanned a
        /// three-line identity column, kept now that the column is two.
        static let avatarSize: CGFloat = 96
        /// Dynamic-Type ceiling for the avatar.
        static let avatarMaxSize: CGFloat = 110
        static let avatarRingWidth: CGFloat = 3
        static let badgeSize: CGFloat = 18
        /// Raw-media window between the navigation chrome and the identity
        /// block, per banner shape. A poster's is the picture's whole stage —
        /// nothing sits on it — so it gets more. A band's is exactly half
        /// the avatar: the disc's top sits ON the chrome's bottom edge, with
        /// no strip of picture between the two, and the band ends on the
        /// disc's midline.
        static func bannerClearance(for format: ProfileBannerFormat) -> CGFloat {
            switch format {
            case .band, .none: bandGap
            case .poster: 200
            }
        }
        /// The air between the chrome's bottom edge and the avatar, on a band
        /// and on a header with no picture.
        static let bandGap: CGFloat = Spacing.md
        /// How far down the avatar a band reaches: its first quarter, so the
        /// strip's edge cuts the disc high and the name below sits clear of
        /// it, with air above.
        static let bandOverlap: CGFloat = avatarSize / 4
        /// On a band, how far under the strip's edge the name begins: the
        /// name hangs just below the picture rather than sinking to the foot
        /// of the disc.
        static let bandNameGap: CGFloat = Spacing.sm
        /// The air above the tray, carried by the tray itself so it holds
        /// whether or not a website row sits above it.
        static let trayGap: CGFloat = Spacing.md
        /// How far above the counters the poster's run-out begins. The avatar
        /// and the name sit on the picture itself; the tone arrives for the
        /// numbers and is strong by the bio.
        static let posterFadeLead: CGFloat = 40
        /// Side length of the circular bubbles in the action tray (and
        /// thus the height of the whole tray).
        static let bubbleSize: CGFloat = 44
        /// Content margins of the identity block — wider than the standard
        /// `Spacing.lg` page margin so the header reads airy against the
        /// full-bleed banner.
        static let horizontalInset: CGFloat = 20
    }

    /// The identity block's page margin, published so the selector directly
    /// beneath it can line its own ends up with the name and the bio rather
    /// than with a second opinion about where this page's column starts.
    static let pageMargin = Metrics.horizontalInset

    private let bannerView: ProfileBannerView
    private let avatarView = CircleAvatarView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let websiteButton = UIButton(configuration: .plain())
    /// Bumped by every configure — see `dissolve`.
    private var configureGeneration = 0
    private let followersStat = ProfileStatView(caption: "Followers")
    private let followingStat = ProfileStatView(caption: "Following")
    private let reactionsStat = ProfileStatView(caption: "Reactions")
    private let viewsStat = ProfileStatView(caption: "Views")
    private let messageButton = UIButton(configuration: .gray())
    private let editButton = UIButton(configuration: .gray())
    /// Keep-this-profile-on-the-map's-people-rails, immediately right of
    /// Message. Hidden unless the viewer follows this profile — see
    /// `configureMapPin`.
    private let mapPinButton = UIButton(configuration: .gray())
    private let followButton = UIButton(configuration: .gray())
    private let qrCodeButton = UIButton(configuration: .gray())
    private let moreButton = UIButton(configuration: .gray())
    private var columnTopConstraint: NSLayoutConstraint?

    /// Pins the banner's top to the scroll viewport's top edge (required,
    /// as an inequality), so that when the user overscrolls downward the
    /// banner's soft attachment to the header top gives way and the media
    /// stretches to keep covering the screen from y = 0 — no background gap.
    /// When content scrolls up, the inequality is slack and the banner leaves
    /// the screen with the header as usual. Called once by the owning
    /// controller with its scroll view's `frameLayoutGuide.topAnchor`; the
    /// header stays scroll-view-agnostic.
    func anchorBanner(toViewportTop viewportTop: NSLayoutYAxisAnchor) {
        bannerView.topAnchor.constraint(lessThanOrEqualTo: viewportTop).isActive = true
    }

    /// Height of the status-bar + navigation chrome the banner runs under,
    /// supplied by the owning controller (the header can't know it: its own
    /// safe area shifts as the scroll view moves). The identity column starts
    /// a full banner-clearance below this inset; the banner ignores it and
    /// bleeds to y = 0.
    var chromeTopInset: CGFloat = 0 {
        didSet { columnTopConstraint?.constant = columnTopConstant }
    }

    /// The banner's shape — see `ProfileBannerFormat`. Read off the picture
    /// as it lands; settable for QA.
    private(set) var bannerFormat: ProfileBannerFormat = .unresolved

    /// Where the identity column starts: below the chrome and the banner's
    /// clearance. A band's clearance is only the air under the chrome — the
    /// strip reaches down INTO the avatar rather than the avatar climbing up
    /// into the strip.
    private var columnTopConstant: CGFloat {
        chromeTopInset + Metrics.bannerClearance(for: bannerFormat)
    }

    /// Adopts a banner shape: the column's start, where the banner ends, how
    /// the name sits against the avatar, and whether the picture runs out.
    func setBannerFormat(_ format: ProfileBannerFormat) {
        guard format != bannerFormat || !hasAppliedBannerFormat else { return }
        hasAppliedBannerFormat = true
        bannerFormat = format
        columnTopConstraint?.constant = columnTopConstant
        // A band ends a quarter of the way down the avatar, its edge cut by
        // the disc; a poster runs to the foot of the tray; no picture, no
        // banner.
        bannerView.isHidden = format == .none
        bannerEndsAtTray?.isActive = format == .poster
        bannerEndsInAvatar?.isActive = format != .poster
        // Beside a straddling disc the name sits on the page just BELOW the
        // strip's edge: top-aligned with the disc and pushed down by the
        // strip's reach into it plus a small gap. Bottom-aligning it instead
        // sank the name to the foot of the disc, a long way under the
        // picture. On a poster, and with no picture, the two are centred on
        // each other.
        topRow.alignment = format == .band ? .top : .center
        identityColumn.directionalLayoutMargins.top =
            format == .band ? Metrics.bandOverlap + Metrics.bandNameGap : 0
        bannerView.setFormat(format)
        setNeedsLayout()
    }

    /// The scroll, handed down to the banner: the picture lags the content,
    /// and a poster fades out over exactly the travel that brings the
    /// avatar's top to where a band would hold it — under the chrome, a gap
    /// below it — so the two shapes meet at the same picture: none.
    func setTravelled(_ travelled: CGFloat) {
        bannerView.setTravelled(travelled, fadeOutTravel: posterFadeOutTravel)
    }

    /// The travel that brings a poster's avatar to where a band holds its
    /// own — the point the poster is gone by, and a detent the scroll rests
    /// at (see `ProfileScrollDetents`).
    var posterFadeOutTravel: CGFloat {
        Metrics.bannerClearance(for: .poster) - Metrics.bannerClearance(for: .band)
    }

    private var hasAppliedBannerFormat = false
    private var bannerEndsAtTray: NSLayoutConstraint?
    private var bannerEndsInAvatar: NSLayoutConstraint?
    private let topRow = UIStackView()
    private let statsRow = UIStackView()
    private let identityColumn = UIStackView()

    #if DEBUG
    var debugBannerFrame: CGRect { bannerView.frame }
    var debugAvatarFrame: CGRect { avatarView.convert(avatarView.bounds, to: self) }
    var debugTrayFrame: CGRect { actionRowForDebug?.convert(actionRowForDebug!.bounds, to: self) ?? .zero }
    var debugStatsFrame: CGRect { statsRow.convert(statsRow.bounds, to: self) }
    var debugBannerIsHidden: Bool { bannerView.isHidden }
    var debugTrayButtons: [UIButton] {
        [followButton, messageButton, editButton, mapPinButton, qrCodeButton, moreButton]
    }
    var debugBannerShowsFade: Bool { bannerView.debugShowsFade }
    var debugBannerFadeLocations: [CGFloat] { bannerView.debugFadeLocations }
    var debugBannerFadeAlphas: [CGFloat] { bannerView.debugFadeAlphas }
    var debugBannerAlpha: CGFloat { bannerView.alpha }
    var debugBannerPictureShift: CGFloat { bannerView.debugPictureShift }
    private weak var actionRowForDebug: UIView?
    #endif

    /// Builds the mutual's rail menu, resolved at PRESENTATION so the rows
    /// reflect live membership rather than whatever was true when the button
    /// was configured — the same bargain `setMoreMenu` strikes.
    var makeMapPinMenu: (() -> UIMenu)?
    /// Invoked when the Follow / Following capsule is tapped (other users
    /// only). The capsule lives HERE, beside Message, rather than in the
    /// navigation bar: the two are one decision about one person, and a
    /// finger should not have to travel from the bar to the tray to make it.
    var onFollowTapped: (() -> Void)?
    /// Invoked when the Message button is tapped (other users only).
    var onMessageTapped: (() -> Void)?
    /// Invoked when the Edit Profile capsule is tapped (own profile only).
    var onEditTapped: (() -> Void)?
    /// Invoked when the QR-code bubble is tapped.
    var onQRCodeTapped: (() -> Void)?
    /// The see-more (ellipsis) bubble's anchor, for popover-style presentations
    /// the controller puts on it (the share sheet on iPad, the report picker).
    var moreButtonAnchor: UIView { moreButton }
    /// Invoked with the profile's website URL when the link row is tapped.
    var onWebsiteTapped: ((URL) -> Void)?
    /// Invoked when the Followers or Following counter is tapped — the two
    /// columns that lead somewhere. Reactions and Views are read-only totals
    /// with no list behind them, and stay inert.
    var onRelationshipsTapped: ((RelationshipDirection) -> Void)?

    private let imagePipeline: ImagePipeline
    private var avatarTask: Task<Void, Never>?
    private var currentAvatarURL: URL?
    private var websiteURL: URL?

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        bannerView = ProfileBannerView(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        configureSubviews()
        // The picture decides the shape, whenever it lands.
        bannerView.onImageResolved = { [weak self] image in
            self?.setBannerFormat(.resolved(forImageSize: image.size))
        }
        setBannerFormat(.unresolved)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        avatarTask?.cancel()
    }

    // MARK: - Configuration

    func configure(with model: ProfileDisplayModel) {
        // Supersedes any staggered group still waiting to land.
        configureGeneration += 1
        monogramLabel.text = model.avatarMonogram
        nameLabel.text = model.displayName
        handleLabel.text = model.handle
        verifiedBadge.isHidden = !model.isVerified

        bioLabel.text = model.bio
        bioLabel.isHidden = !model.hasBio

        websiteURL = model.websiteURL
        websiteButton.configuration?.title = model.websiteText
        websiteButton.isHidden = model.websiteText == nil

        followersStat.setValue(model.followerText)
        followingStat.setValue(model.followingText)
        reactionsStat.setValue(model.reactionsText)
        viewsStat.setValue(model.viewsText)

        applyBannerPresence(model.bannerImageURL)
        bannerView.setImageURL(model.bannerImageURL)
        loadAvatar(model.avatarURL)
    }

    /// No picture, no banner — and a picture arriving on a header that had
    /// none takes the unresolved shape until it has said which it is.
    private func applyBannerPresence(_ url: URL?) {
        if url == nil {
            setBannerFormat(.none)
        } else if bannerFormat == .none {
            setBannerFormat(.unresolved)
        }
    }

    /// Applies `model` as a set of small, lightly staggered cross-dissolves —
    /// one per element group — instead of one transition over the whole header.
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
    func configure(with model: ProfileDisplayModel, staggered: Bool) {
        guard staggered, window != nil else {
            configure(with: model)
            return
        }
        configureGeneration += 1
        let generation = configureGeneration
        // Identity first: the banner's colour field and the avatar carry most of
        // the "this is someone else now" signal, and the name says it outright.
        dissolve([bannerView, avatarView, nameLabel, handleLabel, verifiedBadge], after: 0, generation: generation) {
            self.monogramLabel.text = model.avatarMonogram
            self.nameLabel.text = model.displayName
            self.handleLabel.text = model.handle
            self.verifiedBadge.isHidden = !model.isVerified
            self.applyBannerPresence(model.bannerImageURL)
            self.bannerView.setImageURL(model.bannerImageURL)
            self.loadAvatar(model.avatarURL)
        }
        dissolve([followersStat, followingStat, reactionsStat, viewsStat], after: Metrics.stagger, generation: generation) {
            self.followersStat.setValue(model.followerText)
            self.followingStat.setValue(model.followingText)
            self.reactionsStat.setValue(model.reactionsText)
            self.viewsStat.setValue(model.viewsText)
        }
        dissolve([bioLabel, websiteButton], after: Metrics.stagger * 2, generation: generation) {
            self.bioLabel.text = model.bio
            self.bioLabel.isHidden = !model.hasBio
            self.websiteURL = model.websiteURL
            self.websiteButton.configuration?.title = model.websiteText
            self.websiteButton.isHidden = model.websiteText == nil
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

    /// Installs the see-more bubble's overflow menu. Set once with a menu whose
    /// children are resolved lazily (`UIDeferredMenuElement`), so the tray never
    /// holds a stale copy of state the controller owns.
    func setMoreMenu(_ menu: UIMenu) {
        moreButton.menu = menu
    }

    /// Adjusts the tray's capsules to the viewer's relationship: Follow or
    /// Following beside Message for other users, Edit Profile alone for the
    /// viewer's own profile; the star, QR and see-more bubbles trail whichever
    /// is showing.
    ///
    /// Follow is the one PROMINENT capsule on the screen — the action a
    /// stranger's profile exists to invite — and it goes quiet the moment it
    /// has been taken, so Following reads as a state rather than a second
    /// call to action.
    func configureAction(_ state: ProfileViewModel.FollowButton) {
        switch state {
        case .follow, .following:
            followButton.isHidden = false
            var config = Self.capsule(prominent: state == .follow)
            config.title = state == .follow ? "Follow" : "Following"
            followButton.configuration = config
            followButton.accessibilityLabel = config.title
            messageButton.isHidden = false
            editButton.isHidden = true
        case .edit:
            followButton.isHidden = true
            messageButton.isHidden = true
            editButton.isHidden = false
        case .hidden:
            followButton.isHidden = true
            messageButton.isHidden = true
            editButton.isHidden = true
        }
    }

    #if DEBUG
    /// Fires the follow capsule's own action — the simulator cannot tap it
    /// through the harness, so the QA path presses it from here.
    func debugTapFollow() -> Bool {
        guard !followButton.isHidden else { return false }
        followButton.sendActions(for: .primaryActionTriggered)
        return true
    }
    #endif

    /// Poses the map-favorite star beside Message.
    ///
    /// Visibility is NOT decided here: `ProfileViewModel.MapPinButton` resolves
    /// the relationship rule (only a profile the viewer follows can be kept on
    /// a rail) together with whether the app was wired for it at all, so the
    /// view renders one finished answer instead of re-deriving it from a
    /// second copy of the rule.
    ///
    /// One tap opens the checklist — `showsMenuAsPrimaryAction`, so no long
    /// press. There is no single-toggle case left: with three rails, even
    /// someone merely followed has two of them (the dock and the Following
    /// row), and a tap that picked one for them would be guessing.
    ///
    /// The menu is REBUILT on every publication rather than set once: the rows
    /// carry the checkmarks, and the state they mark is exactly what this call
    /// is delivering.
    func configureMapPin(_ state: ProfileViewModel.MapPinButton) {
        mapPinButton.isHidden = state == .hidden
        guard state != .hidden else {
            mapPinButton.menu = nil
            mapPinButton.showsMenuAsPrimaryAction = false
            return
        }
        mapPinButton.configuration = Self.bubble(
            systemImage: Self.mapFavoriteSymbol(isFavorited: state.isFavorited)
        )
        mapPinButton.showsMenuAsPrimaryAction = true
        mapPinButton.menu = makeMapPinMenu?()
        mapPinButton.accessibilityLabel = "Map favorites"
        // What the star SAYS, since its glyph is a state and VoiceOver users
        // get no glyph: which rails this profile is on, or that it is on none.
        mapPinButton.accessibilityValue = Self.mapFavoriteValue(for: state.categories)
    }

    /// The star's spoken state — the rails, in the order the checklist lists
    /// them, so what is read matches what opening it would show.
    private static func mapFavoriteValue(for categories: Set<MapFavoriteCategory>) -> String {
        let names: [(MapFavoriteCategory, String)] = [
            (.dock, "Map dock"), (.following, "Following filter"), (.friends, "Friends filter")
        ]
        let on = names.filter { categories.contains($0.0) }.map(\.1)
        return on.isEmpty ? "Not on the map" : on.joined(separator: ", ")
    }

    /// Filled on ANY rail, outlined on none — the same read as a bookmark.
    private static func mapFavoriteSymbol(isFavorited: Bool) -> String {
        isFavorited ? "star.circle.fill" : "star.circle"
    }

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
    func setRedacted(_ redacted: Bool, animated: Bool = false) {
        guard redacted != isRedacted else { return }
        isRedacted = redacted

        if redacted {
            // Layout ballast: one blank line per single-line label, two for
            // the bio's typical measure. The website row is reserved too —
            // hiding it here and inserting it at reveal would push the whole
            // gallery down mid-fade (most profiles carry a link; a linkless
            // one collapses the row as a content change, not a reveal jump).
            nameLabel.text = " "
            handleLabel.text = " "
            bioLabel.text = " \n "
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
            for stat in [followersStat, followingStat, reactionsStat, viewsStat] {
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
            for stat in [self.followersStat, self.followingStat, self.reactionsStat, self.viewsStat] {
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

        // Two caption-pitch bars inside the bio's two placeholder lines.
        let bioFirst = SkeletonBoneView()
        bioFirst.constrain(in: self) { _ in
            bioFirst.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor)
            bioFirst.trailingAnchor.constraint(equalTo: bioLabel.trailingAnchor)
            bioFirst.topAnchor.constraint(equalTo: bioLabel.topAnchor, constant: 4)
            bioFirst.heightAnchor.constraint(equalToConstant: 12)
        }
        let bioSecond = SkeletonBoneView()
        bioSecond.constrain(in: self) { _ in
            bioSecond.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor)
            bioSecond.widthAnchor.constraint(equalTo: bioLabel.widthAnchor, multiplier: 0.55)
            bioSecond.bottomAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: -4)
            bioSecond.heightAnchor.constraint(equalToConstant: 12)
        }

        let websiteBone = SkeletonBoneView()
        websiteBone.constrain(in: self) { _ in
            websiteBone.leadingAnchor.constraint(equalTo: websiteButton.leadingAnchor)
            websiteBone.centerYAnchor.constraint(equalTo: websiteButton.centerYAnchor)
            websiteBone.widthAnchor.constraint(equalToConstant: 120)
            websiteBone.heightAnchor.constraint(equalToConstant: 12)
        }

        redactionBones = [avatarBone, nameBone, handleBone, bioFirst, bioSecond, websiteBone]
    }

    /// The tray's text capsules, FLAT.
    ///
    /// ⚠️ NOT GLASS. Liquid Glass is a material for chrome that floats over
    /// content — it earns its place by showing what passes beneath it. These
    /// buttons sit on the page with nothing behind them, so glass here was
    /// a blur of a flat grey, which reads as a rendering fault rather than
    /// as depth. The platform's own answer for a button on a page is the
    /// filled family: one PROMINENT capsule in the tint, for the action the
    /// screen invites (Follow), and quiet grey capsules with page ink for
    /// the rest (Following, Message, Edit Profile). That is the pairing every
    /// profile screen on the platform has settled on, and it is the same
    /// grey the cards' pills wear, so the tray and the list read as one
    /// system.
    private static func capsule(prominent: Bool) -> UIButton.Configuration {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        if !prominent { config.baseForegroundColor = .label }
        config.cornerStyle = .capsule
        // md, not lg, side insets: the capsule shares the avatar-side column
        // with three bubbles; the tighter title keeps the tray within budget.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        return config
    }

    /// A circular flat bubble holding a single SF Symbol, in the same grey as
    /// the quiet capsules beside it, with page ink.
    private static func bubble(systemImage: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        config.contentInsets = .zero
        return config
    }

    private func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil // fall back to the monogram until (and unless) the image resolves
        monogramLabel.isHidden = false

        guard let url else { return }
        let pipeline = imagePipeline
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.currentAvatarURL == url else { return }
            // Async arrival dissolves over the monogram instead of popping.
            UIView.transition(
                with: self.avatarView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.avatarView.image = image
                // ⚠️ The initials GO when the picture lands. They are a
                // subview of the image view, so they draw ABOVE it — left
                // visible, "KT" sat across the photograph for as long as the
                // profile was on screen. The contract is initials first, then
                // the picture, not both.
                self.monogramLabel.isHidden = true
            }
        }
    }

    // MARK: - Layout

    private func configureSubviews() {
        // Avatar: a filled circle with a monogram, overlaid by the image once
        // loaded. The ring keeps it defined while it floats over raw banner
        // media, above the fade.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.borderWidth = Metrics.avatarRingWidth
        // The ring is the page's tone, so the avatar reads as cut from the
        // page it floats over rather than wearing a whiter halo.
        avatarView.layer.borderColor = Surface.page.resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProfileHeaderView, _) in
            self.avatarView.layer.borderColor = Surface.page.resolvedColor(with: self.traitCollection).cgColor
        }

        monogramLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)
        // The avatar's side length is resolved by layout (it tracks the
        // identity column), so the monogram scales off the resolved frame —
        // reported by the avatar itself, whose layout pass is the first to
        // see the final size (the header's runs too early for nested stacks).
        avatarView.onSideLengthChange = { [weak self] side in
            guard let self, side > 0 else { return }
            let monogramSize = (side * 0.4).rounded()
            if abs(self.monogramLabel.font.pointSize - monogramSize) > 0.5 {
                self.monogramLabel.font = .systemFont(ofSize: monogramSize, weight: .semibold)
            }
        }

        // Followers and Following open the relationship lists; the other two
        // columns are totals with nothing behind them.
        for (stat, direction) in [
            (followersStat, RelationshipDirection.followers),
            (followingStat, RelationshipDirection.following)
        ] {
            stat.isTappable = true
            stat.addAction(
                UIAction { [weak self] _ in self?.onRelationshipsTapped?(direction) },
                for: .touchUpInside
            )
        }

        // The 4-metric counter row, last element of the header: equal cells
        // across the full content width, right above the content threshold.
        for stat in [followersStat, followingStat, reactionsStat, viewsStat] {
            statsRow.addArrangedSubview(stat)
        }
        statsRow.axis = .horizontal
        statsRow.alignment = .center
        statsRow.distribution = .fillEqually

        // Type hierarchy of the identity block, three clear steps: title3
        // semibold display name (the block's anchor; SF applies its tighter
        // large-size tracking automatically), subheadline secondary @handle,
        // subheadline bio below — name > handle = body copy, one weight jump.
        nameLabel.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel
        handleLabel.numberOfLines = 1

        verifiedBadge.tintColor = .systemBlue
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)

        bioLabel.font = .preferredFont(forTextStyle: .subheadline)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 0

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

        followButton.isHidden = true
        followButton.addAction(
            UIAction { [weak self] _ in self?.onFollowTapped?() },
            for: .primaryActionTriggered
        )

        var messageConfig = Self.capsule(prominent: false)
        messageConfig.title = "Message"
        messageButton.configuration = messageConfig
        messageButton.isHidden = true
        messageButton.addAction(
            UIAction { [weak self] _ in self?.onMessageTapped?() },
            for: .primaryActionTriggered
        )

        // Edit Profile: the own-profile action, a glass capsule sharing the
        // leading slot with Message (never both shown). Same capsule styling as
        // Message so the two read as one action affordance beside the avatar.
        var editConfig = Self.capsule(prominent: false)
        editConfig.title = "Edit Profile"
        editButton.configuration = editConfig
        editButton.isHidden = true
        editButton.addAction(
            UIAction { [weak self] _ in self?.onEditTapped?() },
            for: .primaryActionTriggered
        )

        // Same bubble as QR and see-more, but sitting with the LEADING capsule
        // rather than with the trailing pair: it acts on the person Message
        // acts on, so it belongs beside it.
        mapPinButton.configuration = Self.bubble(
            systemImage: Self.mapFavoriteSymbol(isFavorited: false)
        )
        mapPinButton.isHidden = true

        qrCodeButton.configuration = Self.bubble(systemImage: "qrcode")
        qrCodeButton.addAction(
            UIAction { [weak self] _ in self?.onQRCodeTapped?() },
            for: .primaryActionTriggered
        )
        moreButton.configuration = Self.bubble(systemImage: "ellipsis")
        moreButton.accessibilityLabel = "More actions"
        // The menu IS the primary action — one tap opens it, no intermediate
        // callback. The controller supplies the content (see `setMoreMenu`).
        moreButton.showsMenuAsPrimaryAction = true
        // The app's one press (`PressFeedback`): the tray's controls give a
        // little under the finger like every card control does. Their system
        // highlight is the dim, so only the shrink is added; silent — the
        // action answers.
        for button in [followButton, messageButton, editButton, mapPinButton, qrCodeButton, moreButton] {
            PressFeedback.attach(to: button, sound: nil)
        }

        // The Liquid Glass tray, split composition: the leading capsule
        // (Message for others, Edit Profile for the viewer) leads the identity
        // stack; a stretching mid-spacer forces the QR and see-more bubbles
        // flush against the identity block's trailing edge. The spacer's
        // neighbors get zero stack spacing — the spacer IS the gap — so the
        // tray degrades gracefully when width is scarce. The split holds
        // whichever leading capsule is visible.
        // ⚠️ THE TRAY IS A FULL-WIDTH ROW UNDER THE BIO, not a line beside
        // the avatar.
        //
        // Follow used to live in the navigation bar and Message in the
        // identity column, two decisions about one person a finger's travel
        // apart. Put together they no longer fit beside a disc: Following +
        // Message + three bubbles need ~300pt and the column has ~240. So the
        // whole tray moved down to the header's last line, the width of the
        // page — the arrangement a profile screen has settled on everywhere
        // else — and the identity column beside the avatar is the name and
        // the handle alone.
        //
        // The two capsules share the width left by the bubbles equally: the
        // pair reads as one control with two halves, and Follow is the one
        // that is prominent.
        let actionRow = UIStackView(
            arrangedSubviews: [followButton, messageButton, editButton, mapPinButton, qrCodeButton, moreButton]
        )
        actionRow.axis = .horizontal
        actionRow.alignment = .fill
        actionRow.distribution = .fill
        actionRow.spacing = Spacing.sm
        for capsule in [followButton, messageButton, editButton] {
            capsule.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
            capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let equalCapsules = messageButton.widthAnchor.constraint(equalTo: followButton.widthAnchor)
        equalCapsules.priority = UILayoutPriority(999)
        equalCapsules.isActive = true
        // ⚠️ The map pin is the one bubble that HIDES, and it must not carry
        // the square tie the other two do. `height == width` is required, the
        // row is `.fill` (every arranged subview's height equals the row's,
        // also required), and a hidden arranged subview gets its width forced
        // to zero by the stack — three required constraints that cannot all
        // hold. UIKit then broke one of the row's own, and the whole tray
        // spilled out of the identity column: the Message label landed on the
        // counters and the QR bubble in the corner, on every profile the
        // viewer does not follow.
        //
        // Width alone is enough: `.fill` supplies the height, and at a 44pt
        // row that is the same 44x44 circle.
        let pinWidth = mapPinButton.widthAnchor.constraint(equalToConstant: Metrics.bubbleSize)
        pinWidth.priority = UILayoutPriority(999)
        pinWidth.isActive = true

        for bubble in [qrCodeButton, moreButton] {
            // The diameter is 999, not required: on the narrowest devices the
            // tray can overrun the column beside the avatar, and the bubbles
            // shaving a point (staying circular via the required square tie)
            // beats an unsatisfiable-constraints break.
            let diameter = bubble.widthAnchor.constraint(equalToConstant: Metrics.bubbleSize)
            diameter.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                diameter,
                bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor)
            ])
        }

        // Right column of the top block: name over @handle, centred against
        // the avatar.
        identityColumn.addArrangedSubview(nameRow)
        identityColumn.addArrangedSubview(handleLabel)
        identityColumn.axis = .vertical
        identityColumn.alignment = .fill
        identityColumn.spacing = Spacing.xs
        // The band pushes the name down inside the column — see
        // `setBannerFormat`.
        identityColumn.isLayoutMarginsRelativeArrangement = true
        identityColumn.directionalLayoutMargins = .zero

        topRow.addArrangedSubview(avatarView)
        topRow.addArrangedSubview(identityColumn)
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = Spacing.md
        #if DEBUG
        actionRowForDebug = actionRow
        #endif

        var websiteConfig = UIButton.Configuration.plain()
        websiteConfig.image = UIImage(systemName: "link")
        websiteConfig.imagePadding = Spacing.xs
        websiteConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        websiteConfig.baseForegroundColor = .systemBlue
        websiteConfig.contentInsets = .zero
        websiteConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
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

        // Page column: the two-column identity block (avatar | name/@handle/
        // tray), then full width — the counter row directly under the identity
        // block, then bio and website closing the header right above the
        // content threshold. Wider vertical rhythm than the standard xs-step
        // stacks: the header sits against a full-bleed banner and needs air
        // between its major containers to read premium.
        let column = UIStackView(arrangedSubviews: [topRow, statsRow, bioLabel, websiteButton, actionRow])
        column.axis = .vertical
        column.alignment = .fill
        // Air between the block's rows: a step more than the standard stack
        // at every seam, because this block sits alone under a picture and
        // read as packed at the standard pitch — counters on the name, tray
        // on the bio.
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.xl, after: topRow)
        column.setCustomSpacing(Spacing.lg, after: statsRow)
        column.setCustomSpacing(Spacing.md, after: bioLabel)
        column.setCustomSpacing(Spacing.md, after: websiteButton)
        // The tray carries its own air above, so the gap holds whether the
        // row before it is the website or the bio.
        actionRow.isLayoutMarginsRelativeArrangement = true
        actionRow.directionalLayoutMargins.top = Metrics.trayGap
        actionRow.heightAnchor.constraint(equalToConstant: Metrics.bubbleSize + Metrics.trayGap).isActive = true

        // Layering: banner first (back), identity column on top of it. The
        // banner bleeds to the header's very top — the column starts below the
        // navigation chrome via `chromeTopInset` — and its bottom edge is tied
        // to the action tray's, so it always ends exactly at the tray's bottom
        // threshold no matter which identity rows are visible.
        //
        // The top attachment is deliberately soft (high, not required): the
        // owning controller adds a required ≤-viewport-top constraint via
        // `anchorBanner(toViewportTop:)`, and downward overscroll must be able
        // to break this equality so the banner stretches instead of sliding
        // down with the content and exposing the scroll view's background.
        let bannerTop = bannerView.topAnchor.constraint(equalTo: topAnchor)
        bannerTop.priority = .defaultHigh
        bannerView.constrain(in: self) { parent in
            bannerTop
            bannerView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            bannerView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }

        let columnTop = column.topAnchor.constraint(
            equalTo: topAnchor, constant: columnTopConstant
        )
        columnTopConstraint = columnTop
        column.constrain(in: self) { parent in
            columnTop
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.horizontalInset)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.horizontalInset)
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.xl)
        }

        // The avatar is a fixed disc now that the tray no longer sits beside
        // it: the identity column is two lines, which is no height to tie a
        // disc to. `avatarSize` is what the three-line column used to resolve
        // to, so the block keeps the proportions it had.
        //
        // High, not required, so a Dynamic-Type name that needs more than the
        // disc's height is not clipped — the column then grows and the disc
        // re-centres against it.
        let avatarSide = avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        avatarSide.priority = .defaultHigh
        // Where the banner ENDS is the shape's — see `setBannerFormat`, which
        // activates exactly one of these.
        bannerEndsAtTray = bannerView.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor)
        bannerEndsInAvatar = bannerView.bottomAnchor.constraint(
            equalTo: avatarView.topAnchor, constant: Metrics.bandOverlap
        )
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalTo: avatarView.heightAnchor),
            avatarSide,
            avatarView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.avatarMaxSize)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bannerFormat == .poster else { return }
        // The nested stacks settle AFTER this pass — the note on
        // `CircleAvatarView` — so they are settled here by hand before the
        // frames are read: the run-out is placed against where the avatar
        // and the counters actually are, not where they were a pass ago.
        topRow.superview?.layoutIfNeeded()
        let stats = statsRow.convert(statsRow.bounds, to: bannerView)
        guard stats.height > 0 else { return }
        // Clear until just above the counters, strong by the bio: the
        // counters climb through the steep part of the curve, and the avatar
        // and the name above them stand on the picture itself.
        bannerView.setFade(
            start: stats.minY - Metrics.posterFadeLead,
            opaque: stats.maxY + Spacing.md
        )
    }
}

/// An image view that stays a circle whatever side length layout resolves for
/// it. The rounding must live here — in the bounds' owner — because ancestor
/// `layoutSubviews` runs before nested stack views hand this view its final
/// frame, and would round a stale size.
private final class CircleAvatarView: UIImageView {
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
