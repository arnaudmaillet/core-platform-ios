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

    /// What the badge says about the viewer and the person.
    ///
    /// Only `.follow` is an ACTION (the "+"). The others are STATE, drawn so
    /// following someone does not simply make the pill forget it — and so a
    /// friend (a mutual follow) reads apart from a one-way follow, and a
    /// request a private account has not answered reads apart from both. A
    /// state mark takes no tap of its own: it falls through to the pill's.
    public enum Badge: Equatable, Sendable {
        /// Nothing drawn: the viewer themself, someone blocked, a relation not
        /// known yet, or a host that offers no follow at all.
        case none
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
            case .none: nil
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
            case .none, .follow: "plus.circle.fill"
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
            case .none, .follow: 9
            }
        }

        public var accessibilityLabel: String? {
            switch self {
            case .none: nil
            case .follow: "Follow"
            case .following: "Following"
            case .friends: "Friends"
            case .pending: "Requested"
            }
        }
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
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    /// The relation's mark, centred on the face's edge — nil when the pill
    /// carries none (the profile).
    private let statusBadge: PersonPillBadgeView?
    /// The relation's ring around the face (#1298): grey while the viewer
    /// follows, pink once they are friends, none otherwise.
    private let ring = UIView()
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
        avatar = AvatarView(diameter: AvatarImageView.bubbleDiameter, size: faceSize)
        statusBadge = carriesBadge ? PersonPillBadgeView() : nil
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

        let row = UIStackView(arrangedSubviews: [avatar, labelsStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        // A badge reaches half its width past the face (centred on its edge,
        // #1277): the name starts clear of it, whatever the relation — a
        // constant, so a badge arriving never moves the pill's width.
        if statusBadge != nil {
            row.setCustomSpacing(PersonPillBadgeView.overhang + Spacing.xs, after: avatar)
        }
        // The face's leading inset matches its breathing in the wrapper, so it
        // sits evenly in the glass on three sides; the labels end the pill.
        let breathing = max(0, (Self.wrapperHeight - AvatarImageView.bubbleDiameter) / 2)
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // The ring hugs the face from outside, inside the wrapper's
        // breathing room, so it never moves the row or the pill's width.
        ring.isUserInteractionEnabled = false
        ring.layer.borderWidth = PersonPillRing.width
        ring.layer.borderColor = UIColor.clear.cgColor
        // The friends' ring is the accent (#1379): a border holds a CGColor
        // and re-resolves nothing itself.
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, AccentThemeTrait.self]
        ) { (pill: PersonPill, _: UITraitCollection) in
            pill.ring.layer.borderColor = PersonPillRing.ink(for: pill.ringRelation)
                .resolvedColor(with: pill.traitCollection).cgColor
        }
        ring.layer.cornerCurve = .circular
        ring.layer.cornerRadius = AvatarImageView.bubbleDiameter / 2 + PersonPillRing.width
        ring.constrain(in: self) { _ in
            ring.centerXAnchor.constraint(equalTo: avatar.centerXAnchor)
            ring.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)
            ring.widthAnchor.constraint(equalTo: avatar.widthAnchor, constant: PersonPillRing.width * 2)
            ring.heightAnchor.constraint(equalTo: avatar.heightAnchor, constant: PersonPillRing.width * 2)
        }

        // ⚠️ CENTRED ON THE DISC'S EDGE, AT ITS MID-HEIGHT (the owner,
        // 2026-10-16, #1277): the badge's centre sits over the far end of the
        // face's disc, level with the face. Its size is its own: nothing in
        // the row is measured against it. Trailing to trailing, not centre to
        // trailing: only an edge-to-edge offset mirrors under right-to-left.
        if let statusBadge {
            statusBadge.constrain(in: self) { _ in
                statusBadge.trailingAnchor.constraint(
                    equalTo: avatar.trailingAnchor, constant: PersonPillBadgeView.overhang
                )
                statusBadge.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)
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
        return true
    }

    /// The widest the pill is drawn now.
    public var widthCap: CGFloat { maxWidthConstraint?.constant ?? ceiling }

    /// The cold floor holds while the redaction bars show, and never under a
    /// cap narrower than it, which it would otherwise out-argue.
    private func applyWidthFloor() {
        guard let coldWidth else { return }
        minWidthConstraint?.isActive = isRedacted && widthCap >= coldWidth
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
        setRing(badge, animated: animated)
        updateAccessibility()
    }

    // MARK: - Ring

    /// The relation the face's ring draws now (#1298).
    public private(set) var ringRelation: Badge = .none

    /// Rings the face for `relation`: grey while the viewer follows, pink
    /// once they are friends, none otherwise — it follows the badge
    /// (`setBadge`). ⚠️ ONLY WITH A BADGE (the owner, 2026-10-16): a pill
    /// that carries none (the profile's) never wears the ring.
    /// Re-coloured in place, never resized: the ring sits in the face's
    /// breathing room, outside anything the pill's width is made of.
    public func setRing(_ relation: Badge, animated: Bool) {
        guard statusBadge != nil, relation != ringRelation else { return }
        ringRelation = relation
        let ink = PersonPillRing.ink(for: relation).resolvedColor(with: traitCollection).cgColor
        if animated, window != nil {
            let fade = CABasicAnimation(keyPath: "borderColor")
            fade.fromValue = ring.layer.presentation()?.borderColor ?? ring.layer.borderColor
            fade.toValue = ink
            fade.duration = 0.25
            ring.layer.add(fade, forKey: "borderColor")
        }
        ring.layer.borderColor = ink
    }

    /// The ring's ink now — clear for none. Tests.
    public var drawnRingColor: UIColor { UIColor(cgColor: ring.layer.borderColor ?? UIColor.clear.cgColor) }

    /// The symbol the badge draws now — nil for none. Tests.
    public var drawnBadgeSymbol: String? { statusBadge?.drawn.symbolName }
    /// How many badge changes were drawn through the symbol replace. Tests.
    public var badgeReplaceCount: Int { statusBadge?.replaceCount ?? 0 }
    /// The badge's glyph image as drawn now. Tests (#968).
    public var drawnBadgeImage: UIImage? { statusBadge?.glyphImage }

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

/// The person pill's relation badge (#925): a disc centred on the face's edge
/// wearing the relation's symbol.
///
/// ONE CIRCLED SF SYMBOL in a palette (#1199): the disc and the mark are one
/// symbol, so a change of relation is ONE replace — and to or from no badge
/// the same symbol in clear ink, so appearing and disappearing are replaces
/// too. The badge is never faded, scaled or hidden by hand.
///
/// ⚠️ FIXED INK, and a disc that is a SYMBOL, not a background. On glass a
/// semantic ink pair draws vibrant and an inverted badge vanishes in dark mode
/// (memory `sheet-glass-vibrancy-ink`), and the glass repaints a subview's
/// `backgroundColor` with its own corner (`glass-paints-background-color`).
final class PersonPillBadgeView: UIButton {
    /// The disc's side — larger than the 16pt it was (the owner, 2026-10-16,
    /// #1277).
    static let diameter: CGFloat = 20
    /// How far the badge reaches past the face's edge: half its side, its
    /// centre being ON that edge.
    static var overhang: CGFloat { diameter / 2 }
    /// The touch area around the disc: a 20pt disc is still too small a target.
    private static let touchOutset: CGFloat = 8

    private let glyph = UIImageView()
    /// The badge on screen.
    private(set) var drawn: PersonPill.Badge = .none
    /// Changes drawn through the replace transition.
    private(set) var replaceCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        glyph.constrain(in: self) { parent in
            glyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            glyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // Its size is its own and never the pill's to negotiate.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
        glyph.image = Self.glyphImage(.none)
        apply(interactionFor: .none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchOutset, dy: -Self.touchOutset).contains(point)
    }

    var glyphImage: UIImage? { glyph.image }

    func show(_ badge: PersonPill.Badge, animated: Bool) {
        guard badge != drawn else { return }
        drawn = badge
        apply(interactionFor: badge)
        let image = Self.glyphImage(badge)
        guard animated else {
            glyph.image = image
            return
        }
        replaceCount += 1
        glyph.setSymbolImage(image, contentTransition: .replace)
    }

    /// Only the "+" takes touches — a state mark lets them through to the
    /// pill's own tap. The pill is the one accessibility element.
    private func apply(interactionFor badge: PersonPill.Badge) {
        isUserInteractionEnabled = badge == .follow
        isAccessibilityElement = false
    }

    /// The disc's ink for a badge (#1197, the owner 2026-10-15): the "+"
    /// black; a FOLLOWED check and a pending request grey, their mark pink;
    /// FRIENDS pink, their mark white; clear for none.
    static func discInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none: .clear
        case .follow: PersonPillBadgeInks.restingDisc
        case .following, .pending: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.accent
        }
    }

    /// The glyph's ink for a badge: pink on the grey discs, white elsewhere.
    static func glyphInk(for badge: PersonPill.Badge) -> UIColor {
        switch badge {
        case .none: .clear
        case .following, .pending: PersonPillBadgeInks.accent
        case .follow, .friends: PersonPillBadgeInks.glyph
        }
    }

    /// ⚠️ A palette is fixed ink already (no tint reaches it), and must NOT
    /// be re-marked `.alwaysOriginal`: that drops the palette and draws the
    /// whole symbol in the view's tint (measured: the system blue).
    private static func glyphImage(_ badge: PersonPill.Badge) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: diameter - 3, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [glyphInk(for: badge), discInk(for: badge)]))
        return UIImage(systemName: badge.circledSymbolName)?
            .applyingSymbolConfiguration(configuration)
            ?? UIImage()
    }
}

/// The person pill badge's fixed inks (#968, #1197): one value in either
/// appearance — black disc and white glyph at rest.
public enum PersonPillBadgeInks {
    public static let restingDisc = UIColor.black
    public static let glyph = UIColor.white
    /// The tint's light value in the viewer's accent theme (#1379).
    public static let accent = UIColor { traits in
        Palette.tint.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceStyle = .light })
    }
    /// A quiet grey disc.
    public static let quietDisc = UIColor.systemGray5.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
}

/// The face's relation ring (#1298, the owner 2026-10-16): the badge's own
/// inks, so the ring and the badge say the same thing in the same colour.
public enum PersonPillRing {
    /// The ring's thickness, outside the face.
    public static let width: CGFloat = 2

    /// Grey (the badge's quiet disc) while the viewer follows, pink (the
    /// accent) once they are friends, clear otherwise.
    public static func ink(for relation: PersonPill.Badge) -> UIColor {
        switch relation {
        case .following: PersonPillBadgeInks.quietDisc
        case .friends: PersonPillBadgeInks.accent
        case .none, .follow, .pending: .clear
        }
    }
}
