import DesignSystem
import UIKit

/// The app's ONE person pill (#1277): a face, a name over a handle, and an
/// optional relation badge, drawn inside a bar item's glass.
///
/// ```
///   [ (MH)⊕ Marcus Holt   ]
///          @marcus.holt
/// ```
///
/// It is the post page's toolbar pill, the conversation's bar and the text
/// composer's (through Feed's `SnapAuthorIdentityView`, which adds the swaps
/// between people), and the profile's navigation bar once its tray has
/// scrolled away. It DRAWS; who is shown, and what the relation is, stay
/// with each host.
///
/// - The face follows the avatar contract: the initials first, the picture
///   hydrating over them (`AvatarView`).
/// - It takes its content's width, at most its cap (`setWidthBudget`): the
///   name truncates first, the handle only once the name has nothing left to
///   give (`BarIdentityStyle`).
/// - The badge is OPTIONAL (`carriesBadge`): the profile has none. A pill
///   that carries one keeps a constant gap past the face, so a relation that
///   loads or changes never moves its width, and every change of it is an SF
///   Symbols replace — never a blur of the pill.
/// - Until a person is set it shows redaction bars, at a plausible floor
///   width (`coldWidth`), so the first person is a small glide, not a pop.
public final class PersonPill: UIView {
    /// The bar's item wrapper height on iOS 26 — the box the face centres in.
    public static let wrapperHeight: CGFloat = 36
    /// The relation mark's sizes on the pill's face (#2014): a 20 pt badge.
    nonisolated static let markMetrics = RelationMarkMetrics(faceDiameter: RelationMarkMetrics.pillFace)

    /// What the badge says about the viewer and the person.
    ///
    /// Only `.follow` is an ACTION (the "+"). The others are STATE, drawn so
    /// following someone does not simply make the pill forget it — and so a
    /// friend (a mutual follow) reads apart from a one-way follow, and a
    /// request a private account has not answered reads apart from both. A
    /// state mark takes no tap of its own: it falls through to the pill's.
    public enum Badge: Equatable, Sendable {
        /// Nothing drawn, for good: the viewer themself, someone blocked, or a
        /// host that offers no follow at all. No disc, no cutout.
        case none
        /// The relation is not known yet (#2098): the badge's place is held by
        /// a skeleton bone, its cutout already taken out of the face, so the
        /// mark that lands changes only what the disc draws. No symbol, no
        /// tap, no accessibility element.
        case loading
        /// "+": the viewer does not follow them. A tap follows.
        case follow
        /// The viewer follows them; they do not follow back.
        case following
        /// Both follow each other.
        case friends
        /// The viewer asked a private account to follow them, and the request
        /// is pending (#968).
        case pending

        /// The symbols the owner chose (#925):
        /// - `plus` — the action;
        /// - `checkmark.circle.fill` — the viewer follows them;
        /// - `person.2.fill` — two people: the app already means "Friends" by
        ///   it (the map's Friends filter), and it is the one symbol that says
        ///   the relation goes BOTH ways;
        /// - `clock.circle.fill` — waiting on the other person (#968). Not
        ///   `clock.fill`: that symbol is ONE layer, a white disc with its
        ///   hands cut out, so on the badge it can only be a white disc with
        ///   black hands. `clock.circle.fill` is the same clock in two layers,
        ///   like the check: its circle draws black and its hands white — and
        ///   the two marks a "+" can turn into share one construction.
        public var symbolName: String? {
            switch self {
            case .none, .loading: nil
            case .follow: "plus"
            case .following: "checkmark.circle.fill"
            case .friends: "person.2.fill"
            case .pending: "clock.circle.fill"
            }
        }

        /// The symbol the badge draws: the relation's glyph inside its own
        /// disc (#1199), so the disc and the mark move as one.
        public var circledSymbolName: String {
            switch self {
            case .none, .loading, .follow: "plus.circle.fill"
            case .following: "checkmark.circle.fill"
            case .friends: "person.2.circle.fill"
            case .pending: "clock.circle.fill"
            }
        }

        /// Each glyph's size on the badge's disc: the check and the clock are
        /// discs of their own, as large as it; the "+" and the two people sit
        /// inside it.
        public var pointSize: CGFloat {
            switch self {
            case .following, .pending: 13
            case .friends: 7
            case .none, .loading, .follow: 9
            }
        }

        public var accessibilityLabel: String? {
            switch self {
            case .none, .loading: nil
            case .follow: "Follow"
            case .following: "Following"
            case .friends: "Friends"
            case .pending: "Requested"
            }
        }

        /// Whether the face loses the badge's disc: for every badge drawn, the
        /// skeleton's included — only "no badge, for good" leaves it whole.
        public var cutsTheFace: Bool { self != .none }
    }

    /// Called when the pill is tapped. Without one the pill takes no tap of
    /// its own: a host that fades it (a swap between people) keeps the tap
    /// on itself, where a faded pill cannot lose it.
    public var onTap: (() -> Void)? {
        didSet { tapRecognizer.isEnabled = onTap != nil }
    }
    private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
    /// Called when the "+" is tapped. Never for a state mark: those take no
    /// tap of their own.
    public var onFollowTapped: (() -> Void)?

    /// The face: the initials, the picture dissolved in over them (#943).
    public let avatar: AvatarView
    /// The face's place in the row (#2233): the person's avatar, or a
    /// group's picture over it (`setGroupAvatar`). A slot, so the avatar can
    /// hide under a group without the row collapsing its place — and hidden,
    /// never faded: a platter flattens a partial alpha.
    private let faceSlot = UIView()
    /// A group's picture, made the first time the pill shows a group.
    private var groupAvatar: GroupAvatarView?
    /// The bucket the face is decoded at, a group's faces included.
    private let faceSize: ImageBucket
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    /// The relation's mark, centred on the face's edge — nil when the pill
    /// carries none (the profile).
    private let statusBadge: RelationBadgeView?
    /// Redacted stand-ins shown where the labels will be until the first
    /// person is set — the system placeholder idiom.
    private let namePlaceholder = PersonPill.makeRedactionBar(width: 96, height: 12)
    private let handlePlaceholder = PersonPill.makeRedactionBar(width: 64, height: 9)
    private let labelsStack = UIStackView()

    /// The widest the pill ever is, whatever the budget.
    private let ceiling: CGFloat
    /// The floor while the redaction bars show; nil for none.
    private let coldWidth: CGFloat?
    private var maxWidthConstraint: NSLayoutConstraint?
    /// The labels' end of the row, `Spacing.md` short of the pill's — none
    /// when the pill is its face alone.
    private var rowTrailingConstraint: NSLayoutConstraint?
    private var minWidthConstraint: NSLayoutConstraint?

    /// - Parameters:
    ///   - height: the pill's height, under its bar's own wrapper (999).
    ///   - carriesBadge: whether the pill has a relation badge at all.
    ///   - ceiling: the widest it ever is.
    ///   - coldWidth: its floor while no person is set.
    public init(
        height: CGFloat = PersonPill.wrapperHeight,
        carriesBadge: Bool,
        ceiling: CGFloat = .greatestFiniteMagnitude,
        coldWidth: CGFloat? = nil,
        faceSize: ImageBucket = .avatar
    ) {
        self.ceiling = ceiling
        self.coldWidth = coldWidth
        self.faceSize = faceSize
        avatar = AvatarView(diameter: AvatarImageView.bubbleDiameter, size: faceSize)
        statusBadge = carriesBadge ? RelationBadgeView(metrics: Self.markMetrics) : nil
        super.init(frame: .zero)

        // Clear: with no picture (yet) the initials behind show through.
        avatar.picture.backgroundColor = .clear
        // The bars' one identity look (`BarIdentityStyle`): the name at a bar
        // item's title size over the handle, the name giving way first.
        BarIdentityStyle.apply(name: nameLabel, handle: handleLabel)
        for label in [nameLabel, handleLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        for view in [nameLabel, namePlaceholder, handleLabel, handlePlaceholder] {
            labelsStack.addArrangedSubview(view)
        }
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        // Any width the pill has beyond (or short of) its content — the cold
        // floor, the cap — is the labels area's: it is the one member that
        // gives way.
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        avatar.pin(to: faceSlot)
        let row = UIStackView(arrangedSubviews: [faceSlot, labelsStack])
        faceRow = row
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        // A badge reaches half its width past the face (centred on its edge,
        // #1277): the name starts clear of it, whatever the relation — a
        // constant, so a badge arriving never moves the pill's width.
        if statusBadge != nil {
            row.setCustomSpacing(Self.markMetrics.overhang + Spacing.xs, after: faceSlot)
        }
        // The face's leading inset matches its breathing in the wrapper, so it
        // sits evenly in the glass on three sides; the labels end the pill.
        let breathing = max(0, (Self.wrapperHeight - AvatarImageView.bubbleDiameter) / 2)
        let rowTrailing = row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md)
        rowTrailingConstraint = rowTrailing
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            rowTrailing
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // ⚠️ ON THE FACE'S CIRCLE, 45° BELOW ITS TRAILING SIDE (the owner,
        // 2026-10-28, #1793 — replacing #1277's "centred on the disc's edge,
        // at its mid-height"): the badge's centre sits on the face's rim at
        // its bottom-trailing corner, overlapping it the way an iOS status
        // badge does. Its size is its own: nothing in the row is measured
        // against it, and it reaches no further than the room the row keeps
        // after the face (`overhang`). Edge to edge, never centre to trailing:
        // only an edge offset mirrors under right-to-left.
        if let statusBadge {
            let offset = Self.markMetrics.cornerOffset
            statusBadge.constrain(in: self) { _ in
                statusBadge.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: offset)
                statusBadge.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: offset)
            }
            statusBadge.addAction(UIAction { [weak self] _ in
                guard let self, self.badge == .follow else { return }
                self.onFollowTapped?()
            }, for: .primaryActionTriggered)
        }

        // 999, never required: the bar pins its wrapper with autoresizing
        // constraints on its first pass; a required height fights it.
        let heightConstraint = heightAnchor.constraint(equalToConstant: height)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true
        // Before any budget: the ceiling, or a sane bar width without one.
        let maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: ceiling.isFinite ? ceiling : 220)
        maxWidth.isActive = true
        maxWidthConstraint = maxWidth
        if let coldWidth {
            let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: coldWidth)
            minWidth.priority = UILayoutPriority(999)
            minWidthConstraint = minWidth
        }
        setRedacted(true)

        // ONE element (#1277): "Name, @handle, Following", the "+" offered as
        // a custom action rather than a separate tiny target.
        isAccessibilityElement = true
        accessibilityTraits = .button
        tapRecognizer.isEnabled = false
        addGestureRecognizer(tapRecognizer)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Person

    /// The name and the handle line, as shown. An empty handle leaves the
    /// name alone on the pill. Clears the redaction bars.
    public func setName(_ name: String, handle: String) {
        setRedacted(false)
        nameLabel.text = name
        handleLabel.text = handle
        updateAccessibility()
    }

    /// The handle line alone.
    public func setHandle(_ handle: String) {
        handleLabel.text = handle
        updateAccessibility()
    }

    public var name: String? { nameLabel.text }
    public var handle: String? { handleLabel.text }

    /// Whether the redaction bars show: no person set yet.
    public private(set) var isRedacted = true

    private func setRedacted(_ redacted: Bool) {
        isRedacted = redacted
        nameLabel.isHidden = redacted
        namePlaceholder.isHidden = !redacted
        handleLabel.isHidden = redacted
        handlePlaceholder.isHidden = !redacted
        // The stand-in bars need a gap of their own; label line-heights carry
        // it once hydrated.
        labelsStack.spacing = redacted ? 5 : 0
        applyWidthFloor()
    }

    // MARK: - Width

    /// Caps the pill's width — the room its bar leaves it, under its ceiling.
    /// It takes its intrinsic width, at most this, and truncates past it.
    /// Returns whether the cap changed, so a host can ask its bar for a pass.
    @discardableResult
    public func setWidthBudget(_ budget: CGFloat?) -> Bool {
        let target = min(ceiling, budget ?? ceiling)
        guard target > 0, target.isFinite, maxWidthConstraint?.constant != target else { return false }
        maxWidthConstraint?.constant = target
        applyWidthFloor()
        applyFaceOnly()
        return true
    }

    /// The narrowest a pill is drawn (#1924, the owner): its face alone, in
    /// a circle — the bar's bubble around the avatar.
    public static let faceOnlyWidth: CGFloat = AvatarImageView.bubbleDiameter

    /// The cap under which the labels give way altogether: the face, the
    /// gap past it and the pill's end, and room for a few letters. Squeezed
    /// below it, the row crushed the face into an oval.
    static var faceOnlyThreshold: CGFloat {
        faceOnlyWidth + markMetrics.overhang + Spacing.xs + Spacing.md + 32
    }

    /// Whether the pill shows its face alone, its cap too narrow for a name.
    public var showsFaceOnly: Bool { labelsStack.isHidden }

    private func applyFaceOnly() {
        let faceOnly = widthCap < Self.faceOnlyThreshold
        guard faceOnly != labelsStack.isHidden else { return }
        labelsStack.isHidden = faceOnly
        rowTrailingConstraint?.constant = faceOnly ? 0 : -Spacing.md
        updateAccessibility()
    }

    /// The widest the pill is drawn now.
    public var widthCap: CGFloat { maxWidthConstraint?.constant ?? ceiling }

    /// The cold floor holds while the redaction bars show, and never under a
    /// cap narrower than it, which it would otherwise out-argue.
    private func applyWidthFloor() {
        guard let coldWidth else { return }
        minWidthConstraint?.isActive = isRedacted && widthCap >= coldWidth
    }

    // MARK: - A group (#2233)

    /// Draws a group's picture in the face's place (#2233) — its photo, its
    /// members' faces cut apart, or its initials (`GroupAvatarView`), the
    /// same component as its inbox row, so the two always agree. Nil gives
    /// the face back to the person's avatar. A group wears no badge.
    ///
    /// The same content again changes nothing; new faces or a photo update
    /// the picture in place, the faces already drawn kept — no flash.
    public func setGroupAvatar(_ content: GroupAvatarContent?, pipeline: ImagePipeline?) {
        guard let content else {
            groupAvatar?.setContent(nil, pipeline: nil)
            groupAvatar?.isHidden = true
            avatar.isHidden = false
            return
        }
        let view = groupAvatar ?? makeGroupAvatar()
        view.isHidden = false
        view.setContent(content, pipeline: pipeline)
        avatar.isHidden = true
    }

    /// The group drawn in the face's place, nil for a person.
    public var groupAvatarContent: GroupAvatarContent? {
        guard let groupAvatar, !groupAvatar.isHidden else { return nil }
        return groupAvatar.content
    }

    /// The group's picture view, nil before the pill first showed a group.
    /// Tests.
    public var debugGroupAvatar: GroupAvatarView? { groupAvatar }

    private func makeGroupAvatar() -> GroupAvatarView {
        let view = GroupAvatarView(diameter: AvatarImageView.bubbleDiameter, size: faceSize)
        // The pill is the one element: it says the group's name.
        view.isAccessibilityElement = false
        view.pin(to: faceSlot)
        groupAvatar = view
        return view
    }

    // MARK: - Badge

    /// The badge drawn now; `.none` on a pill that carries none.
    public private(set) var badge: Badge = .none

    /// Draws `badge` — through SF Symbols' replace when `animated`, at once
    /// otherwise. Nothing else on the pill moves. A pill that carries no
    /// badge ignores it.
    public func setBadge(_ badge: Badge, animated: Bool) {
        guard let statusBadge else { return }
        self.badge = badge
        statusBadge.show(badge, animated: animated)
        // Gone for good (the skeleton's relation turned out to be none): the
        // cutout closes as the bone fades, in the same motion (#2098).
        if !badge.cutsTheFace { faceCutout.close(avatar.layer, animated: animated && window != nil) }
        setNeedsLayout()
        updateAccessibility()
    }

    // MARK: - The badge's cutout (#1912)

    /// What the badge is cut out of: the face loses a disc the badge's
    /// radius plus `cutoutGap`, so whatever is behind the
    /// pill shows round the badge — the system's idiom for a status mark on
    /// a face. A true cutout, never a stroke in a guessed colour: the pill
    /// is glass over moving video.
    public static let cutoutGap = RelationMarkMetrics.cutoutGap
    private let faceCutout = FaceCutout()
    /// The row holding the face, laid out before the cutout is measured.
    private weak var faceRow: UIStackView?

    public override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ THE FACE IS THE ROW'S, laid out in the ROW's pass, which runs
        // after this one returns: read now, its bounds can still be zero
        // (the owner's device, 2026-10-30 — a mask cut from them showed a
        // corner of the face and nothing else, until some later pass).
        faceRow?.layoutIfNeeded()
        applyBadgeCutout()
    }

    /// The badge's centre in `view`'s space — where its cutout is taken
    /// out — nil with no badge drawn.
    private func cutoutCentre(in view: UIView) -> CGPoint? {
        guard let statusBadge, badge.cutsTheFace, !statusBadge.isHidden, statusBadge.bounds.width > 0 else { return nil }
        return statusBadge.convert(CGPoint(x: statusBadge.bounds.midX, y: statusBadge.bounds.midY), to: view)
    }

    /// The face's mask. Everything the face draws is a layer's content or a
    /// shape — its skeleton's bone included (`SkeletonBoneView.fill`) — so the
    /// mask reaches all of it, loading or not.
    private func applyBadgeCutout() {
        guard let centre = cutoutCentre(in: avatar) else {
            if !faceCutout.isClosing { faceCutout.close(avatar.layer, animated: false) }
            return
        }
        faceCutout.cut(avatar.layer, centre: centre, metrics: Self.markMetrics)
    }

    /// Whether the face's mask lets `point` (in the face's space) show.
    /// Tests.
    public func faceShows(at point: CGPoint) -> Bool {
        guard faceCutout.isCut(avatar.layer), let path = faceCutout.mask.path else { return true }
        return path.contains(point, using: .evenOdd)
    }

    /// The badge's cutout as drawn on the face: its radius, nil without one.
    /// Tests.
    public var drawnCutoutRadius: CGFloat? {
        guard faceCutout.isCut(avatar.layer), faceCutout.mask.path != nil else { return nil }
        return Self.markMetrics.cutoutRadius
    }

    /// Whether anything is drawn round the face — a ring, a border: never
    /// (#2082, the badge alone). Tests.
    public var drawsAnythingRoundTheFace: Bool {
        avatar.layer.borderWidth > 0 || subviews.contains { $0 !== faceRow && $0 !== statusBadge }
    }

    /// The symbol the badge draws now — nil for none. Tests.
    public var drawnBadgeSymbol: String? { statusBadge?.drawn.symbolName }
    /// How many badge changes were drawn through the symbol replace. Tests.
    public var badgeReplaceCount: Int { statusBadge?.replaceCount ?? 0 }
    /// The badge's glyph image as drawn now. Tests (#968).
    public var drawnBadgeImage: UIImage? { statusBadge?.glyphImage }
    /// Whether the badge shows the skeleton's bone. Tests (#2098).
    public var debugBadgeShowsBone: Bool { statusBadge?.showsBone ?? false }

    // MARK: - Look

    /// The labels' SHADOW, for a pill floating over an arbitrary photo with
    /// no background of its own. The colours are semantic and resolve from
    /// the bar's theme.
    public func setOverMedia(_ overMedia: Bool) {
        for label in [nameLabel, handleLabel] {
            label.layer.shadowOpacity = overMedia ? 0.5 : 0
        }
    }

    // MARK: - Interaction

    @objc private func tapped() { onTap?() }

    private func updateAccessibility() {
        let lines = [nameLabel.text, handleLabel.text].compactMap { $0 }.filter { !$0.isEmpty }
        let state = badge == .follow ? nil : badge.accessibilityLabel
        accessibilityLabel = (lines + [state].compactMap { $0 }).joined(separator: ", ")
        accessibilityCustomActions = badge == .follow ? [
            UIAccessibilityCustomAction(name: "Follow") { [weak self] _ in
                self?.onFollowTapped?()
                return true
            },
        ] : nil
    }

    private static func makeRedactionBar(width: CGFloat, height: CGFloat) -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        bar.layer.cornerRadius = height / 2
        bar.layer.cornerCurve = .continuous
        // Below the width cap: a narrow pill shortens the bar rather than
        // being widened by it.
        let length = bar.widthAnchor.constraint(equalToConstant: width)
        length.priority = .defaultHigh
        length.isActive = true
        bar.heightAnchor.constraint(equalToConstant: height).isActive = true
        return bar
    }

    #if DEBUG
    /// The lines the pill shows, top to bottom.
    public var debugShownLines: [String] {
        [nameLabel, handleLabel].filter { !$0.isHidden }.compactMap(\.text)
    }
    public var debugNameFont: UIFont { nameLabel.font }
    public var debugHandleFont: UIFont { handleLabel.font }
    /// The face's, the badge's and the name's frames in the pill's space.
    public var debugGeometry: (face: CGRect, badge: CGRect?, name: CGRect) {
        layoutIfNeeded()
        return (avatar.convert(avatar.bounds, to: self),
                statusBadge.map { $0.convert($0.bounds, to: self) },
                nameLabel.convert(nameLabel.bounds, to: self))
    }
    #endif
}

/// The person pill badge's fixed inks (#968, #1197): one value in either
/// appearance — black disc and white glyph at rest.
public enum PersonPillBadgeInks {
    public static let restingDisc = UIColor.black
    public static let glyph = UIColor.white
    /// The tint's light value.
    public static let accent = UIColor { traits in
        Palette.tint.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceStyle = .light })
    }
    /// A quiet grey disc: the avatar's own fixed ground (#2051), the one
    /// grey a loading face and this disc share.
    public static let quietDisc = Surface.avatarGround
}
