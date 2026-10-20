import CoreStorage
import DesignSystem
import MapsInterface
import UIKit

// The pieces of the wallet redesign, structure B (#1476): the hub's header
// (one big balance, four round actions, the Gems card) and the likes gauge
// both screens show.

// MARK: - Gauge

/// How full the likes are against the server's cap (#901): a thin bar and its
/// line — "282 of 2,000", or, full, that only staking opens the claim again.
/// The device's mock has no cap: the line says what likes are for.
final class WalletLikesGauge: UIView {
    private let track = UIView()
    private let fill = UIView()
    private let caption = UILabel()
    private var fillWidth: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = .tertiarySystemFill
        track.layer.cornerRadius = 3
        track.clipsToBounds = true
        fill.backgroundColor = LikesSymbol.tint
        fill.layer.cornerRadius = 3
        caption.font = .scaledMonospacedDigitSystemFont(ofSize: 12, weight: .medium, relativeTo: .caption1, maximumPointSize: 16)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 2

        [track, fill, caption].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(track)
        track.addSubview(fill)
        addSubview(caption)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            caption.topAnchor.constraint(equalTo: track.bottomAnchor, constant: Spacing.xs),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with snapshot: WalletSnapshot) {
        let text = Self.caption(for: snapshot)
        if snapshot.likesCap.map({ snapshot.balance >= $0 }) == true {
            caption.attributedText = Warning.note(text, font: caption.font)
        } else {
            caption.attributedText = nil
            caption.text = text
        }
        track.isHidden = snapshot.likesCap == nil
        fillWidth?.isActive = false
        fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: Self.fraction(for: snapshot))
        fillWidth?.isActive = true
        accessibilityLabel = text
    }

    /// "282 of 2,000"; full, the way out; no cap, what likes are for.
    static func caption(for snapshot: WalletSnapshot) -> String {
        guard let cap = snapshot.likesCap else { return "To stake on posts" }
        if snapshot.balance >= cap { return "Full · stake to claim again" }
        return "\(snapshot.balance.formatted()) of \(cap.formatted())"
    }

    /// The bar's share, 0…1.
    static func fraction(for snapshot: WalletSnapshot) -> CGFloat {
        guard let cap = snapshot.likesCap, cap > 0 else { return 0 }
        return min(1, max(0, CGFloat(snapshot.balance) / CGFloat(cap)))
    }
}

// MARK: - Hub header

/// The hub's head (#1476):
///
/// ```
///              (♥)
///              282
///             Likes
///   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
///           282 of 2,000
///
///    (+)      (♥)      (🏪)     (≡)
///   Claim    Stake     Shop   Activity
///
///   ┌───────────────────────────────┐
///   │ 💎 37 gems                  › │
///   │    Earned by your stakes      │
///   └───────────────────────────────┘
/// ```
final class WalletHubHeaderView: UIView {
    var onClaim: (() -> Void)?
    var onStake: (() -> Void)?
    var onShop: (() -> Void)?
    var onActivity: (() -> Void)?
    var onGems: (() -> Void)?

    private let coin = UIImageView()
    private let balance = UILabel()
    private lazy var rollingBalance = WalletRollingNumber(label: balance)
    private let unit = UILabel()
    private let gauge = WalletLikesGauge()
    private let claim = WalletHubAction(
        image: WalletHubAction.systemImage("plus"), title: "Claim", identifier: "wallet.hub.claim"
    )
    private let stake = WalletHubAction(
        image: LikesSymbol.glyphImage(WalletHubAction.symbolConfiguration)?.withRenderingMode(.alwaysTemplate),
        title: "Stake", identifier: "wallet.hub.stake"
    )
    private let shop = WalletHubAction(
        image: WalletHubAction.systemImage(CountryShopEntry.symbolName), title: "Shop", identifier: "wallet.hub.shop"
    )
    private let activity = WalletHubAction(
        image: WalletHubAction.systemImage("list.bullet"), title: "Activity", identifier: "wallet.hub.activity"
    )
    private let gemsCard = WalletHubGemsCard()
    private let claimLine = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        coin.image = LikesSymbol.coinImage(traits: traitCollection)
        coin.contentMode = .scaleAspectFit
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (header: WalletHubHeaderView, _: UITraitCollection) in
            header.coin.image = LikesSymbol.coinImage(traits: header.traitCollection)
        }
        // Rounded and monospaced, as the sheet's balances: a figure that
        // changes under the viewer's eyes must not jostle.
        let base = UIFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        balance.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? base
        balance.textAlignment = .center
        balance.adjustsFontSizeToFitWidth = true
        balance.minimumScaleFactor = 0.5
        unit.text = "Likes"
        unit.font = .scaledSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, maximumPointSize: 17)
        unit.adjustsFontForContentSizeCategory = true
        unit.textColor = .secondaryLabel
        unit.textAlignment = .center
        claimLine.font = .scaledMonospacedDigitSystemFont(ofSize: 12, weight: .medium, relativeTo: .caption1, maximumPointSize: 16)
        claimLine.adjustsFontForContentSizeCategory = true
        claimLine.textColor = .secondaryLabel
        claimLine.textAlignment = .center
        claimLine.numberOfLines = 2

        claim.addAction(UIAction { [weak self] _ in self?.onClaim?() }, for: .touchUpInside)
        stake.addAction(UIAction { [weak self] _ in self?.onStake?() }, for: .touchUpInside)
        shop.addAction(UIAction { [weak self] _ in self?.onShop?() }, for: .touchUpInside)
        activity.addAction(UIAction { [weak self] _ in self?.onActivity?() }, for: .touchUpInside)
        gemsCard.addAction(UIAction { [weak self] _ in self?.onGems?() }, for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [claim, stake, shop, activity])
        actions.distribution = .fillEqually
        actions.alignment = .top

        let column = UIStackView(arrangedSubviews: [coin, balance, unit, gauge, actions, claimLine, gemsCard])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xs
        column.setCustomSpacing(Spacing.md, after: unit)
        column.setCustomSpacing(Spacing.lg, after: gauge)
        column.setCustomSpacing(Spacing.xs, after: actions)
        column.setCustomSpacing(Spacing.lg, after: claimLine)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            coin.heightAnchor.constraint(equalToConstant: 36),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with snapshot: WalletSnapshot, claimTitle: String, canClaim: Bool, sellsShop: Bool) {
        // Rolls to a new value on a claim or a stake (#1479).
        rollingBalance.show(snapshot.balance, animated: window != nil)
        balance.accessibilityLabel = "\(snapshot.balance.formatted()) likes"
        gauge.configure(with: snapshot)
        gemsCard.configure(gems: snapshot.gems)
        shop.isHidden = !sellsShop
        gemsCard.isEnabled = sellsShop
        applyClaim(title: claimTitle, canClaim: canClaim)
    }

    /// The Claim action's state and the line under the actions — what the
    /// claim does now or when it opens. Once a second while shown.
    func applyClaim(title: String, canClaim: Bool) {
        claim.isPrimary = canClaim
        claim.isEnabled = canClaim
        claimLine.text = title
    }

    /// The claim's payoff: the new number pops.
    func popBalance() {
        balance.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 2) {
            self.balance.transform = .identity
        }
    }
}

final class WalletHubHeaderCell: UICollectionViewCell {
    let header = WalletHubHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One round action: a disc and its word under it. The primary one (Claim,
/// when a claim is ready) is the brand's filled disc; the others are quiet.
final class WalletHubAction: UIControl {
    private static let disc: CGFloat = 52
    private let circle = UIView()
    private let icon = UIImageView()
    private let label = UILabel()

    var isPrimary = false { didSet { applyLook() } }

    override var isEnabled: Bool { didSet { applyLook() } }
    override var isHighlighted: Bool {
        didSet { circle.alpha = isHighlighted ? 0.6 : 1 }
    }

    static let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)

    static func systemImage(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: symbolConfiguration)
    }

    init(image: UIImage?, title: String, identifier: String) {
        super.init(frame: .zero)
        icon.image = image
        icon.contentMode = .center
        label.text = title
        label.font = .scaledSystemFont(ofSize: 12, weight: .medium, relativeTo: .caption1, maximumPointSize: 16)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        circle.layer.cornerRadius = Self.disc / 2
        circle.isUserInteractionEnabled = false
        icon.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        [circle, icon, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(circle)
        circle.addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: Self.disc),
            circle.heightAnchor.constraint(equalToConstant: Self.disc),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            label.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: Spacing.xs),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        accessibilityIdentifier = identifier
        applyLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyLook() {
        circle.backgroundColor = isPrimary ? LikesSymbol.tint : .tertiarySystemFill
        icon.tintColor = isPrimary ? .white : LikesSymbol.tint
        label.textColor = .label
        alpha = isEnabled ? 1 : 0.4
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }
}

/// The Gems card: the balance of the earned currency and where it goes —
/// pressed, the Shop.
final class WalletHubGemsCard: UIControl {
    private let glyph = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let chevron = UIImageView()

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .quaternarySystemFill : WalletSheetMetrics.cardFill }
    }

    override var isEnabled: Bool {
        didSet { chevron.isHidden = !isEnabled }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = WalletSheetMetrics.cardFill
        layer.cornerRadius = WalletSheetMetrics.rowCorner
        layer.cornerCurve = .continuous
        glyph.image = GemSymbol.glyphImage(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        glyph.contentMode = .center
        title.font = .scaledMonospacedDigitSystemFont(ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 22)
        title.adjustsFontForContentSizeCategory = true
        detail.text = "Earned by your stakes · spend them in the Shop"
        detail.font = .scaledSystemFont(ofSize: 12, relativeTo: .caption1, maximumPointSize: 16)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 2
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [glyph, text, chevron])
        row.alignment = .center
        row.spacing = Spacing.sm
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 28),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "wallet.hub.gems"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(gems: Int) {
        title.text = "\(gems.formatted()) gems"
        accessibilityLabel = "\(gems.formatted()) gems, earned by your stakes"
    }
}
