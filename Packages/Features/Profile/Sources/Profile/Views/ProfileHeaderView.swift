import DesignSystem
import HeroPage
import MediaCore
import UIKit

/// The profile's hero header (`HeroHeaderView`, #1654): the person's avatar,
/// name over @handle, Followers · Following · Likes, bio and link — and its
/// tray, Follow / Message or Edit Profile capsules, then the QR code and
/// see-more bubbles.
///
/// What it adds to the hero header is the profile's own: the tray's states
/// (`configureAction`), the relationship lists behind two of the counters,
/// and the model it shows (`ProfileDisplayModel`).
final class ProfileHeaderView: HeroHeaderView {
    /// The tray is the app's button (#933): quiet capsules and bubbles, one
    /// press each (#866), never glass.
    private let messageButton = AppButton(aspect: .pill(.quiet), size: .header, content: .title("Message"))
    private let editButton = AppButton(aspect: .pill(.quiet), size: .header, content: .title("Edit Profile"))
    /// The relationship's control (`ProfileRelationControl`): Follow, the one
    /// prominent capsule; Requested, its selected, quiet state; and once
    /// followed the mute bell, a quiet bubble the QR's size (#2302). Between
    /// them the content and the ground swap under one blur and the button
    /// springs to its width (#726, #931, #1665) — Follow into the bell and
    /// back is that change, never a pop. While the relationship is unread it
    /// is the button's placeholder, as wide as Requested.
    private let followButton: RelationButton = {
        let button = RelationButton(aspect: .pill(.prominent), size: .header, content: .title("Follow"))
        button.isToggle = true
        button.reservedContents = [.title("Follow"), .title("Requested")]
        return button
    }()
    /// What the tray last showed, so a change of state morphs and a first
    /// answer simply lands.
    private var shownFollowState: ProfileViewModel.FollowButton?
    /// The relationship's control last shown, nil for none.
    private var shownControl: ProfileRelationControl?
    /// Message as wide as Follow or Requested: the two capsules halve the
    /// width the bubbles leave. Let go once the control is the bell (Message
    /// takes the free width, as on the card) or gone.
    private var equalCapsules: NSLayoutConstraint?
    /// The bell's side: the QR bubble's (`HeroHeaderView.bubbleSize`). 999,
    /// as the bubbles' own, so a short row shaves a point rather than breaks.
    private lazy var bellWidth: NSLayoutConstraint = {
        let width = followButton.widthAnchor.constraint(equalToConstant: HeroHeaderView.bubbleSize)
        width.priority = UILayoutPriority(999)
        return width
    }()
    private let qrCodeButton = AppIconButton(style: .bubble(.quiet), content: .symbol("qrcode"))
    private let moreButton = AppIconButton(style: .bubble(.quiet), content: .symbol("ellipsis"))

    init(imagePipeline: ImagePipeline) {
        // The likes the profile's posts have received, summed — the heart
        // every tile of the gallery below counts. Was "Reactions" beside a
        // "Views" total until 2026-09-30.
        super.init(imagePipeline: imagePipeline, counters: ["Followers", "Following", "Likes"])
        configureTray()
        // The avatar's "+" is the tray's Follow, exactly (#2050): one
        // relationship, two places.
        onRelationBadgeTapped = { [weak self] in self?.onFollowTapped?() }
        // Followers and Following open the relationship lists; Likes is a
        // total with nothing behind it.
        for (stat, direction) in zip(counters, [RelationshipDirection.followers, .following]) {
            stat.isTappable = true
            stat.addAction(
                UIAction { [weak self] _ in self?.onRelationshipsTapped?(direction) },
                for: .touchUpInside
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Invoked when the Follow / Requested capsule is tapped (other users
    /// only) — never by the bell, which opens its menu. The capsule lives
    /// HERE, beside Message, rather than in the navigation bar: the two are
    /// one decision about one person, and a finger should not have to travel
    /// from the bar to the tray to make it.
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
    /// Invoked when the Followers or Following counter is tapped — the two
    /// columns that lead somewhere. Likes is a read-only total with no list
    /// behind it, and stays inert.
    var onRelationshipsTapped: ((RelationshipDirection) -> Void)?

    // MARK: - Configuration

    /// Shows `model` — see `HeroHeaderView.configure(with:)`.
    func configure(with model: ProfileDisplayModel) {
        configure(with: HeroHeaderContent(model))
    }

    /// Shows `model` group by group — see
    /// `HeroHeaderView.configure(with:staggered:)`.
    func configure(with model: ProfileDisplayModel, staggered: Bool) {
        configure(with: HeroHeaderContent(model), staggered: staggered)
    }

    // MARK: - The profile's phases (#1757)

    /// THE ONE MAPPING from the profile's phase to the header, for every
    /// screen that shows a profile's header — the profile and the profile
    /// card. Each screen used to write its own; the two drifted (the card
    /// never drew its loading state, nor kept the profile's switch), and the
    /// card opened on the header's blank default: a "transparent" avatar, a
    /// bare banner (the owner's recording, 2026-10-27).
    ///
    /// - Parameters:
    ///   - profileKnown: whether a profile has ever loaded — a failure keeps
    ///     its header, a first failure shows none.
    ///   - switching: a profile switch — the header is HELD rather than
    ///     redacted (a fast load's shimmer read as a wipe), and the content
    ///     lands group by group.
    ///   - animated: the reveal cross-fades (on screen).
    func render(_ phase: ProfileViewModel.Phase, profileKnown: Bool, switching: Bool = false, animated: Bool) {
        switch phase {
        case .loading:
            isHidden = false
            if !switching { setRedacted(true) }
        case .seeded(let seed):
            // The person as the origin showed them, for real (#1859): only
            // the counters are bones, and nothing is reserved that may not
            // exist — no bio, no link, a banner only when certain.
            isHidden = false
            setRedacted(false)
            super.configure(with: HeroHeaderContent(seed))
            setCountersRedacted(true)
        case .content(let model):
            isHidden = false
            // Content first — the labels adopt their text while still
            // invisible under the bones — then the alpha-only reveal. Over a
            // seed it replaces field by field: an equal name or avatar does
            // not move (`HeroHeaderView.configure` diffs).
            configure(with: model, staggered: switching)
            setRedacted(false, animated: animated)
            setCountersRedacted(false, animated: animated)
        case .failed:
            setRedacted(false)
            // Nothing ever loaded: an empty badge, counters and buttons would
            // show around the screen's failure block.
            isHidden = !profileKnown
        case .notFound:
            // A plain page (#1406): no header for no one.
            setRedacted(false)
            isHidden = true
        }
    }

    /// Installs the see-more bubble's overflow menu. Set once with a menu whose
    /// children are resolved lazily (`UIDeferredMenuElement`), so the tray never
    /// holds a stale copy of state the controller owns.
    func setMoreMenu(_ menu: UIMenu) {
        moreButton.menu = menu
    }

    /// Edits the see-more menu while it is open — its Map rows keep it
    /// presented (#689) and their marks follow in place. No-op when closed.
    func updateVisibleMoreMenu(_ transform: @escaping (UIMenu) -> UIMenu) {
        moreButton.contextMenuInteraction?.updateVisibleMenu(transform)
    }

    /// The bell, as the tray shows it once followed (#2302): the muted scopes
    /// (`bell` / `bell.slash`), and whether it can be used yet — a handle or
    /// link route has no one to mute until its read names someone else.
    struct Bell: Equatable {
        var scopes: MuteScopes
        var isEnabled = true
    }

    /// One place of the action row, leading to trailing.
    nonisolated enum TrayItem: Equatable, Sendable {
        /// The relationship's slot while it is unread: a bone as wide as
        /// Requested.
        case placeholder
        case follow, requested, bell
        case message, edit, qr, more
    }

    /// ⚠️ THE ROW PER RELATION (#2302, the owner 2026-11-11), the card's rule
    /// (#1562) — the relationship's control from the one rule the card's
    /// toolbar reads too (`ProfileRelationControl.control`):
    ///
    /// | Relation              | Row                              |
    /// |-----------------------|----------------------------------|
    /// | not followed          | `[Follow][Message][QR][…]`       |
    /// | requested             | `[Requested][Message][QR][…]`    |
    /// | followed              | `[bell][——Message——][QR][…]`     |
    /// | followed, no bell     | `[——Message——][QR][…]`           |
    /// | not followable        | `[——Message——][QR][…]`           |
    /// | not read yet          | `[bone][Message][QR][…]`         |
    /// | the viewer's own      | `[Edit Profile][QR][…]`          |
    ///
    /// `showsBell`: the bell's own rule (`ProfileRelationControl.showsMuteBell`).
    /// Pure, for tests.
    nonisolated static func trayItems(
        for state: ProfileViewModel.FollowButton, showsBell: Bool
    ) -> [TrayItem] {
        let bubbles: [TrayItem] = [.qr, .more]
        switch state {
        case .edit:
            return [.edit] + bubbles
        case .hidden:
            return [.placeholder, .message] + bubbles
        case .follow, .following, .requested, .unavailable:
            let control: [TrayItem] = switch ProfileRelationControl.control(for: state, showsBell: showsBell) {
            case .follow?: [.follow]
            case .requested?: [.requested]
            case .bell?: [.bell]
            case nil: []
            }
            return control + [.message] + bubbles
        }
    }

    /// Installs the bell's menu — the scoped Mute menu — once, its children
    /// resolved when it opens (`UIDeferredMenuElement`), as the see-more's.
    func setBellMenu(_ menu: UIMenu) {
        bellMenu = menu
        if shownControl == .bell { followButton.menu = menu }
    }

    private var bellMenu: UIMenu?

    /// Adjusts the tray to the viewer's relationship (`trayItems`): the
    /// relationship's control beside Message for other users, Edit Profile
    /// alone for the viewer's own profile; the QR and see-more bubbles trail
    /// whichever is showing.
    ///
    /// Follow is the one PROMINENT capsule on the screen — the action a
    /// stranger's profile exists to invite. Once taken, it becomes the bell
    /// (`bell`: the bell's state, nil when there is none to show), and
    /// Message takes the width it leaves (#2302).
    func configureAction(_ state: ProfileViewModel.FollowButton, bell: Bell? = nil) {
        noteLayoutChange()
        // A tray already showing a state changes on screen: what comes in
        // bounces in, what goes scales out (#931). A first answer lands.
        let onScreen = shownFollowState != nil && window != nil
        defer { shownFollowState = state }
        switch state {
        case .follow, .following, .requested:
            guard let control = ProfileRelationControl.control(for: state, showsBell: bell != nil) else {
                // Followed with no bell (a guest, a composition that cannot
                // mute): Message alone, across the free width.
                followButton.setPhase(.content, animated: false)
                applyControl(nil, bell: nil)
                show(followButton, false, animated: onScreen)
                show(messageButton, true, animated: onScreen)
                show(editButton, false, animated: onScreen)
                return
            }
            let content: AppButton.Content = switch control {
            case .follow: .title("Follow")
            case .requested: .title("Requested")
            case .bell: .symbol(ProfileRelationControl.bellSymbol(for: bell?.scopes ?? .none))
            }
            // A change of what the button shows morphs — Follow into the bell
            // and back on the follow's optimistic flip and its rollback, the
            // bell's glyph on a mute — never a first answer, never a button
            // coming back from hidden.
            let changes = !followButton.isHidden && followButton.phase == .content
                && (shownControl != control || followButton.content != content)
            if followButton.phase == .placeholder {
                // The read landed: the bone fades into the answer, the row
                // springing to the bell's width if that is the answer.
                applyControl(control, bell: bell)
                followButton.setContent(content, selected: control != .follow, animated: false)
                followButton.setPhase(.content, animated: onScreen)
                if onScreen { springRow() }
            } else {
                // The row's widths change with the content, in the morph's
                // own spring (`AppButton.blurMorph` lays the row out in it).
                applyControl(control, bell: bell)
                followButton.setContent(content, selected: control != .follow, animated: changes && onScreen)
            }
            show(followButton, true, animated: onScreen)
            show(messageButton, true, animated: onScreen)
            show(editButton, false, animated: onScreen)
        case .edit:
            applyControl(nil, bell: nil)
            show(followButton, false, animated: onScreen)
            show(messageButton, false, animated: onScreen)
            show(editButton, true, animated: onScreen)
        case .unavailable:
            // No Follow where following is impossible (#726); Message stays.
            followButton.setPhase(.content, animated: false)
            applyControl(nil, bell: nil)
            show(followButton, false, animated: onScreen)
            show(messageButton, true, animated: onScreen)
            show(editButton, false, animated: onScreen)
        case .hidden:
            // ⚠️ NOT YET KNOWN IS NOT "FOLLOW". The capsule used to open on a
            // prominent Follow — "the statistical prior" — and a followed
            // author's profile then arrived wearing a blue call to action that
            // turned grey a moment later (filmed, 1 October 2026). Until the
            // relationship is read the slot holds a BLANK quiet capsule as
            // wide as Following, inert, beside Message: the tray's geometry is
            // already right, and nothing on it claims an answer it does not
            // have. The push never waits for the answer (#778): this holds
            // the slot until the read lands.
            // It is the button's PLACEHOLDER (#933): a bone as wide as the
            // widest capsule answer, inert, hidden from VoiceOver.
            applyControl(nil, bell: nil, holdsCapsuleSlot: true)
            followButton.setPhase(.placeholder, animated: false)
            show(followButton, true, animated: false)
            show(messageButton, true, animated: onScreen)
            show(editButton, false, animated: onScreen)
        }
    }

    /// The control's geometry, tap and voice. Called before the content
    /// changes, so an animated change lays the new widths out in its own
    /// spring.
    ///
    /// - Follow and Requested halve the free width with Message
    ///   (`equalCapsules`); the bell is a bubble the QR's size and Message
    ///   takes the rest, as on the card.
    /// - The bell's tap is its menu (the scoped Mute menu, `setBellMenu`);
    ///   Follow's is `onFollowTapped`.
    private func applyControl(_ control: ProfileRelationControl?, bell: Bell?, holdsCapsuleSlot: Bool = false) {
        shownControl = control
        let isBell = control == .bell
        equalCapsules?.isActive = holdsCapsuleSlot || control == .follow || control == .requested
        bellWidth.isActive = isBell
        followButton.showsMenuAsPrimaryAction = isBell
        followButton.menu = isBell ? bellMenu : nil
        // A bell is a menu, not a toggle.
        followButton.isToggle = !isBell
        followButton.isEnabled = isBell ? (bell?.isEnabled ?? true) : true
        switch control {
        case .follow?:
            followButton.accessibilityLabel = "Follow"
            followButton.accessibilityHint = nil
            followButton.stateValue = nil
        case .requested?:
            followButton.accessibilityLabel = "Requested"
            // Tapping Requested withdraws it; say so to VoiceOver.
            followButton.accessibilityHint = "Withdraws your follow request."
            followButton.stateValue = nil
        case .bell?:
            // The words the bar's bell spoke (#689).
            followButton.accessibilityLabel = "Notifications"
            followButton.accessibilityHint = nil
            followButton.stateValue = ProfileRelationControl.bellAccessibilityValue(for: bell?.scopes ?? .none)
        case nil:
            followButton.accessibilityLabel = nil
            followButton.accessibilityHint = nil
            followButton.stateValue = nil
        }
    }

    /// Lays the row out on the morph's spring — a placeholder answered with
    /// the bell, whose width is not the bone's.
    private func springRow() {
        UIView.animate(
            springDuration: AppButton.MorphMetrics.morphDuration, bounce: AppButton.MorphMetrics.morphBounce,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutIfNeeded()
        }
    }

    // MARK: - The relation mark (#2014)

    /// THE ONE MAPPING from the relationship to the badge, for the bar's
    /// pill (#1451) and the avatar (#2014), on the profile and its card:
    /// "+" while not followed, pending while asked, following, friends when
    /// mutual. Nil for a profile with no relation to show: the viewer's own,
    /// one the viewer cannot follow, one not read yet.
    static func relationBadge(for state: ProfileViewModel.FollowButton, mutual: Bool) -> PersonPill.Badge? {
        switch state {
        case .follow: .follow
        case .requested: .pending
        case .following: mutual ? .friends : .following
        default: nil
        }
    }

    /// The avatar's mark (#2014, #2050): the one mapping, WHOLE — "+",
    /// the pending clock, the check and the two people, as the author pill
    /// and the inbox wear it (the owner, 2026-11-02, reversing 2026-11-01's
    /// "never the '+'" to avoid exceptions). The "+" follows, through the
    /// tray's own Follow.
    ///
    /// None for good for the viewer's own profile (known at once, so it never
    /// wears the skeleton's badge first), someone blocked, and a profile the
    /// viewer cannot follow. A relation not read yet wears the skeleton's
    /// badge (#2098), never nothing. A guest wears what the author pill shows
    /// a guest: the "+" (their relation reads as not followed, #442), behind
    /// the member gate the tray's Follow already goes through. Pure, for
    /// tests.
    static func avatarMark(
        for state: ProfileViewModel.FollowButton, mutual: Bool, blocked: Bool, isOwnProfile: Bool
    ) -> PersonPill.Badge {
        guard !blocked, !isOwnProfile else { return .none }
        if state == .hidden { return .loading }
        return relationBadge(for: state, mutual: mutual) ?? .none
    }

    /// Wears the relationship on the avatar — through the badge's replace
    /// once on screen; the header never moves for it.
    func configureRelationMark(
        _ state: ProfileViewModel.FollowButton, mutual: Bool, blocked: Bool, isOwnProfile: Bool
    ) {
        setRelationMark(
            Self.avatarMark(for: state, mutual: mutual, blocked: blocked, isOwnProfile: isOwnProfile),
            animated: window != nil
        )
    }

    /// Shows or hides one of the tray's buttons — through its own motion when
    /// the tray changes on screen, at once otherwise.
    private func show(_ button: AppControl, _ shown: Bool, animated: Bool) {
        guard button.isHidden == shown else { return }
        if shown {
            button.appear(animated: animated)
        } else {
            button.disappear(animated: animated)
        }
    }

    #if DEBUG
    /// What the relationship capsule currently says — nil while it is the
    /// blank placeholder, hidden, or the bell. For tests and QA probes.
    var debugFollowTitle: String? {
        guard !followButton.isHidden, followButton.phase == .content else { return nil }
        return followButton.content.title
    }
    /// A hidden capsule (a followed profile with no bell, #2302) calls for
    /// nothing, whatever ground it kept.
    var debugFollowIsProminent: Bool {
        !followButton.isHidden && followButton.phase == .content && followButton.currentGround == .prominent
    }
    var debugFollowButton: AppButton { followButton }
    var debugTrayButtons: [AppControl] {
        [followButton, messageButton, editButton, qrCodeButton, moreButton]
    }
    /// The bell, when the row shows it (#2302).
    var debugBell: AppButton? {
        guard !followButton.isHidden, followButton.phase == .content, shownControl == .bell else { return nil }
        return followButton
    }
    /// What the row shows, leading to trailing — `trayItems`, read off the
    /// buttons on screen.
    var debugTrayItems: [TrayItem] {
        var items: [TrayItem] = []
        if !followButton.isHidden {
            if followButton.phase == .placeholder {
                items.append(.placeholder)
            } else {
                switch shownControl {
                case .follow?: items.append(.follow)
                case .requested?: items.append(.requested)
                case .bell?: items.append(.bell)
                case nil: break
                }
            }
        }
        if !messageButton.isHidden { items.append(.message) }
        if !editButton.isHidden { items.append(.edit) }
        if !qrCodeButton.isHidden { items.append(.qr) }
        if !moreButton.isHidden { items.append(.more) }
        return items
    }

    /// Fires the follow capsule's own action — the simulator cannot tap it
    /// through the harness, so the QA path presses it from here. Not the
    /// bell: its tap is its menu.
    func debugTapFollow() -> Bool {
        guard !followButton.isHidden, shownControl != .bell else { return false }
        followButton.sendActions(for: .primaryActionTriggered)
        return true
    }
    #endif

    // MARK: - Tray

    private func configureTray() {
        followButton.isHidden = true
        followButton.addAction(
            UIAction { [weak self] _ in
                // The bell's tap is its menu, never a follow.
                guard let self, shownControl != .bell else { return }
                onFollowTapped?()
            },
            for: .primaryActionTriggered
        )

        messageButton.isHidden = true
        messageButton.addAction(
            UIAction { [weak self] _ in self?.onMessageTapped?() },
            for: .primaryActionTriggered
        )

        // Edit Profile: the own-profile action, a quiet capsule sharing the
        // leading slot with Message (never both shown). Same capsule styling as
        // Message so the two read as one action affordance beside the avatar.
        editButton.isHidden = true
        editButton.addAction(
            UIAction { [weak self] _ in self?.onEditTapped?() },
            for: .primaryActionTriggered
        )

        qrCodeButton.accessibilityLabel = "QR code"
        qrCodeButton.addAction(
            UIAction { [weak self] _ in self?.onQRCodeTapped?() },
            for: .primaryActionTriggered
        )
        moreButton.accessibilityLabel = "More actions"
        // The menu IS the primary action — one tap opens it, no intermediate
        // callback. The controller supplies the content (see `setMoreMenu`).
        moreButton.showsMenuAsPrimaryAction = true
        // ⚠️ NO PRESS ATTACHED HERE: every `AppControl` carries the app's one
        // press already, and a second one stacked two shrinks on one finger
        // (#866).


        // The tray, split composition: the leading capsule (Follow beside
        // Message for others, Edit Profile for the viewer), then the QR and
        // see-more bubbles flush against the identity block's trailing edge.
        //
        // Follow used to live in the navigation bar and Message in the
        // identity column, two decisions about one person a finger's travel
        // apart. Put together they no longer fit beside a disc: Following +
        // Message + three bubbles need ~300pt and the column has ~240. So the
        // whole tray moved down to the header's last line, the width of the
        // page (`setActions`) — the arrangement a profile screen has settled
        // on everywhere else.
        //
        // The two capsules share the width left by the bubbles equally: the
        // pair reads as one control with two halves, and Follow is the one
        // that is prominent. Once followed Follow is the bell, a bubble, and
        // Message takes the rest (#2302, `applyControl`).
        // ⚠️ NO STAR IN THE ROW ANY MORE (#689, the owner's call 2026-10-08):
        // keeping a profile on the map's rails is the "Map" submenu of the
        // see-more menu, so the row reads Follow · Message · QR · ⋯ and the
        // two capsules take the width the star held.
        setActions([
            .capsule(followButton), .capsule(messageButton), .capsule(editButton),
            .bubble(qrCodeButton), .bubble(moreButton)
        ])
        let halves = messageButton.widthAnchor.constraint(equalTo: followButton.widthAnchor)
        halves.priority = UILayoutPriority(999)
        halves.isActive = true
        equalCapsules = halves
    }
}

/// The relationship's button: the app's button, with the bell's state
/// spoken as its value (#2302) — `AppButton` writes its own value (the count,
/// a load) on every refresh, which would drop "Muted: Posts".
private final class RelationButton: AppButton {
    /// What VoiceOver hears as the value while the content is shown.
    var stateValue: String? {
        didSet { refreshAccessibility() }
    }

    override func refreshAccessibility() {
        super.refreshAccessibility()
        if phase == .content, let stateValue { accessibilityValue = stateValue }
    }
}

extension HeroHeaderContent {
    /// A person known from where they were opened (#1859): the counters'
    /// cells hold a blank figure under their bones.
    init(_ seed: ProfileSeedModel) {
        self.init(
            title: seed.displayName,
            subtitle: seed.handle ?? "",
            counterValues: [" ", " ", " "],
            avatarURL: seed.avatarURL,
            avatarMonogram: seed.avatarMonogram,
            avatarFrameID: seed.avatarFrameID,
            bannerPending: seed.reservesBanner
        )
    }

    /// A profile, as the hero header shows it.
    init(_ model: ProfileDisplayModel) {
        self.init(
            title: model.displayName,
            subtitle: model.handleLine,
            isVerified: model.isVerified,
            bio: model.hasBio ? model.bio : nil,
            websiteText: model.websiteText,
            websiteURL: model.websiteURL,
            counterValues: [model.followerText, model.followingText, model.likesText],
            avatarURL: model.avatarURL,
            avatarMonogram: model.avatarMonogram,
            avatarFrameID: model.avatarFrameID,
            bannerImageURL: model.bannerImageURL,
            bannerVideoURL: model.bannerVideoURL
        )
    }
}
