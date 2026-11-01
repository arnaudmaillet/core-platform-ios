import CoreModels
import DesignSystem
import ProfileInterface
import UIKit

/// One row of the switcher, as it is drawn.
struct ProfileSwitcherItem {
    enum Kind: Equatable {
        case profile(ProfileID, isActive: Bool)
        case addProfile
    }

    let kind: Kind
    let title: String
    let image: UIImage?
    /// The profile's unread notifications; nil when not known.
    let count: Int?

    /// What VoiceOver reads: "Ava Moreau, 3 new notifications".
    var accessibilityLabel: String {
        guard let text = ProfileSwitcherCountBadge.text(for: count) else { return title }
        let noun = count == 1 ? "new notification" : "new notifications"
        return "\(title), \(text) \(noun)"
    }
}

/// THE SWITCHER (#2034): the system menu's look — its glass, its corner, its
/// width, rows of a round avatar and a name in two sections — drawn by the
/// app so each row can carry its profile's count on the right, which a
/// `UIMenu` row cannot.
///
/// One order whichever way it opens (the other profiles, then the active
/// one, then "Add Profile"): a `UIButton`'s menu flipped it for a source at
/// the bottom of the screen.
///
/// Touches run through `track(_:)` and `release()`, so a tap, a slide inside
/// the switcher, and the Profile tab's hold-slide-release are one path.
final class ProfileSwitcherMenuController: UIViewController, ProfileSwitcherTracking {
    static let width: CGFloat = 250
    static let cornerRadius: CGFloat = 22
    /// The gap between the source and the switcher.
    static let gap: CGFloat = 8
    /// The switcher keeps this far from the screen's edges.
    static let margin: CGFloat = 8

    private let sections: [[ProfileSwitcherItem]]
    private let sourceRect: () -> CGRect?
    private let onPick: (ProfileSwitcherItem) -> Void
    private let panel = UIVisualEffectView(effect: UIGlassEffect())
    private let stack = UIStackView()
    private(set) var rows: [ProfileSwitcherRowView] = []
    private var highlighted: ProfileSwitcherRowView?
    private var isClosing = false

    /// - Parameters:
    ///   - sourceRect: where the source is, in window coordinates, read at
    ///     each layout.
    ///   - onPick: called after the switcher closed, with the row picked.
    init(
        sections: [[ProfileSwitcherItem]],
        sourceRect: @escaping () -> CGRect?,
        onPick: @escaping (ProfileSwitcherItem) -> Void
    ) {
        self.sections = sections.filter { !$0.isEmpty }
        self.sourceRect = sourceRect
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.layer.cornerRadius = Self.cornerRadius
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.accessibilityViewIsModal = true
        view.addSubview(panel)

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
        ])
        for (index, section) in sections.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.separator()) }
            for item in section {
                let row = ProfileSwitcherRowView(item: item)
                rows.append(row)
                stack.addArrangedSubview(row)
            }
        }
        panel.alpha = 0
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = panel.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        let source = sourceRect().map { view.convert($0, from: nil) } ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        panel.frame = Self.panelFrame(
            size: CGSize(width: Self.width, height: size.height), source: source,
            in: view.bounds.inset(by: view.safeAreaInsets)
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        panel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: rows.first)
    }

    /// Below the source when it sits in the upper half, above it otherwise;
    /// centred on it, kept inside `bounds`. Pure, for tests.
    static func panelFrame(size: CGSize, source: CGRect, in bounds: CGRect) -> CGRect {
        let opensDown = source.midY < bounds.midY
        var y = opensDown ? source.maxY + gap : source.minY - gap - size.height
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - size.height)
        var x = source.midX - size.width / 2
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func separator() -> UIView {
        let band = UIView()
        band.heightAnchor.constraint(equalToConstant: 9).isActive = true
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1 / max(1, UITraitCollection.current.displayScale)),
        ])
        return band
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: nil)
        if panel.frame.contains(view.convert(point, from: nil)) {
            move(to: point)
        } else {
            close(picking: nil)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        move(to: touch.location(in: nil))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        setHighlighted(nil)
    }

    /// The finger at `point` (window coordinates): the row under it lights,
    /// with a tick as it crosses into each new one.
    func move(to point: CGPoint) {
        let local = view.convert(point, from: nil)
        let row = rows.first { $0.convert($0.bounds, to: view).contains(local) }
        setHighlighted(row)
    }

    /// The finger lifted: the row under it is picked; on none, the switcher
    /// stays open, as a system menu does.
    func end() {
        guard let row = highlighted else { return }
        close(picking: row.item)
    }

    private func setHighlighted(_ row: ProfileSwitcherRowView?) {
        guard row !== highlighted else { return }
        highlighted?.isHighlighted = false
        highlighted = row
        row?.isHighlighted = true
        if row != nil { Haptics.play(.tick) }
    }

    /// Closes, then picks — the pick's own presentation (Add Profile) needs
    /// the switcher gone.
    func close(picking item: ProfileSwitcherItem?) {
        guard !isClosing else { return }
        isClosing = true
        UIView.animate(withDuration: 0.18, animations: {
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: { _ in
            self.dismiss(animated: false) {
                if let item { self.onPick(item) }
            }
        })
    }

    override func accessibilityPerformEscape() -> Bool {
        close(picking: nil)
        return true
    }

    #if DEBUG
    /// The rows' titles and counts as drawn, in order. Tests.
    var debugRows: [(title: String, badge: String?)] { rows.map { ($0.item.title, $0.badgeText) } }
    #endif
}

/// One row: a 36 pt round avatar, the name, and the count on the right.
final class ProfileSwitcherRowView: UIView {
    let item: ProfileSwitcherItem
    private let highlight = UIView()
    private let badge: ProfileSwitcherCountBadge?

    var badgeText: String? { badge?.text }

    var isHighlighted = false {
        didSet { highlight.alpha = isHighlighted ? 1 : 0 }
    }

    init(item: ProfileSwitcherItem) {
        self.item = item
        badge = ProfileSwitcherCountBadge.text(for: item.count).map { ProfileSwitcherCountBadge(text: $0) }
        super.init(frame: .zero)
        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        highlight.alpha = 0
        highlight.isUserInteractionEnabled = false
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        let avatar = UIImageView(image: item.image ?? Self.fallbackImage(for: item.kind))
        avatar.tintColor = .label
        avatar.contentMode = .scaleAspectFit
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        let name = UILabel()
        name.text = item.title
        name.font = .appFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.numberOfLines = 2
        // The name gives way before the count does.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [avatar, name] + [badge].compactMap { $0 })
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isAccessibilityElement = true
        accessibilityLabel = item.accessibilityLabel
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityActivate() -> Bool {
        var responder: UIResponder? = next
        while let current = responder, !(current is ProfileSwitcherMenuController) { responder = current.next }
        (responder as? ProfileSwitcherMenuController)?.close(picking: item)
        return true
    }

    private static func fallbackImage(for kind: ProfileSwitcherItem.Kind) -> UIImage? {
        switch kind {
        case .addProfile: UIImage(systemName: "person.badge.plus")
        case .profile: UIImage(systemName: "person.crop.circle.fill")
        }
    }
}

/// A profile's count on its row (#2034): a capsule of the brand gradient,
/// pink to violet, the count in white bold at the row's footnote size.
final class ProfileSwitcherCountBadge: UIView {
    let text: String
    private let gradient = BrandGradientView()
    private let label = UILabel()
    private var height: CGFloat = 0

    /// Its count's width and the padding: it hugs its count, so "11" is not
    /// as wide as "99+".
    override var intrinsicContentSize: CGSize {
        CGSize(width: max(ceil(label.intrinsicContentSize.width) + 14, height), height: height)
    }

    /// The count as the badge writes it: none at zero or unknown, "99+" past
    /// 99. Pure, for tests.
    static func text(for count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        gradient.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gradient)
        let font = UIFont.appFont(forTextStyle: .footnote)
        label.font = UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
        label.textColor = .white
        label.text = text
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        height = ceil(label.font.lineHeight) + 4
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true
        NSLayoutConstraint.activate([
            gradient.topAnchor.constraint(equalTo: topAnchor),
            gradient.bottomAnchor.constraint(equalTo: bottomAnchor),
            gradient.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradient.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
