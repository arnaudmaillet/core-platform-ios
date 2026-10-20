import CoreStorage
import DesignSystem
import UIKit

// The pieces of the Wallet sheet (#1494): its top block, the daily glance at
// both of the sheet's heights; the compact line pinned under the bar once
// that block has scrolled away; and the likes gauge the top block shows.

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


// MARK: - Claim button

/// The Claim capsule's look, the big one's and the compact line's: the
/// brand's ONE pink action (#1124) — prominent glass in the brand's tint, or
/// the brand's gradient where the palette's rules ask for it.
enum WalletClaimButtonStyle {
    static func apply(to button: UIButton) {
        button.configuration?.cornerStyle = .capsule
        button.tintColor = Palette.prominentGlassTint
        guard Palette.rules.heroButton == .gradient else { return }
        var gradient = UIButton.Configuration.filled()
        gradient.cornerStyle = .capsule
        gradient.background.customView = BrandGradientView()
        gradient.baseForegroundColor = .white
        button.configuration = gradient
        button.configurationUpdateHandler = { button in
            button.configuration?.background.customView?.alpha = button.isEnabled ? 1 : 0.4
        }
    }
}

// MARK: - Header

/// The Wallet's head (#1494, the owner 2026-10-20, after Telegram's Wallet):
/// the balance with air around it, the day's progress, and three doors.
///
/// ```
///                  (♥)
///                  282
///                 Likes
///
///   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
///              282 of 2,000
///   ┌───────────────────────────────────────────┐
///   │ 🔥 3-day streak · Kept for today  25 / 200 │
///   │ M  T  W  T  F  S  S       ( ×1.3 tomorrow )│
///   └───────────────────────────────────────────┘
///   ┌───────────────────┐ ┌────────┐ ┌────────┐
///   │      ◆ 127        │ │   ✓    │ │   ≡    │
///   │       Shop        │ │Settled │ │Activity│
///   └───────────────────┘ └────────┘ └────────┘
/// ```
/// The Claim is the sheet's toolbar (`WalletSheetViewController`); the
/// small height ends under the doors.
final class WalletHeaderView: UIView {
    var onShop: (() -> Void)?
    var onSettled: (() -> Void)?
    var onActivity: (() -> Void)?

    private let coin = UIImageView()
    private let balance = UILabel()
    private let unit = UILabel()
    private let gauge = WalletLikesGauge()
    private let streakIcon = UIImageView()
    private let streakLine = UILabel()
    private let earnedLine = UILabel()
    /// The week's claims and what the streak pays next (#1479).
    private let week = WalletWeekStrip()
    /// The balance rolls to its new value on a claim or a stake (#1479).
    private lazy var rollingBalance = WalletRollingNumber(label: balance)
    let shopTile = WalletActionTile(identifier: "wallet.gems.shop")
    let settledTile = WalletActionTile(identifier: "wallet.settled")
    let activityTile = WalletActionTile(identifier: "wallet.activity")

    /// The air under the balance, before the day's progress.
    static let balanceAir: CGFloat = 40

    override init(frame: CGRect) {
        super.init(frame: frame)
        coin.contentMode = .scaleAspectFit
        coin.image = LikesSymbol.coinImage(traits: traitCollection)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (header: WalletHeaderView, _: UITraitCollection) in
            header.coin.image = LikesSymbol.coinImage(traits: header.traitCollection)
        }
        // Rounded and monospaced: a figure that changes under the viewer's
        // eyes must not jostle.
        let base = UIFont.monospacedDigitSystemFont(ofSize: 60, weight: .bold)
        balance.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? base
        balance.textAlignment = .center
        balance.adjustsFontSizeToFitWidth = true
        balance.minimumScaleFactor = 0.5
        unit.text = "Likes"
        unit.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 19)
        unit.adjustsFontForContentSizeCategory = true
        unit.textColor = .secondaryLabel
        unit.textAlignment = .center

        streakIcon.contentMode = .center
        streakIcon.setContentHuggingPriority(.required, for: .horizontal)
        for label in [streakLine, earnedLine] {
            label.font = .scaledMonospacedDigitSystemFont(ofSize: 13, weight: .medium, relativeTo: .footnote, maximumPointSize: 17)
            label.adjustsFontForContentSizeCategory = true
        }
        streakLine.textColor = .label
        streakLine.numberOfLines = 2
        earnedLine.textColor = .secondaryLabel
        earnedLine.textAlignment = .right
        earnedLine.setContentCompressionResistancePriority(.required, for: .horizontal)
        let streak = UIStackView(arrangedSubviews: [streakIcon, streakLine, earnedLine])
        streak.spacing = Spacing.xs
        streak.alignment = .center

        settledTile.configure(symbol: "checkmark.seal", title: "Settled")
        activityTile.configure(symbol: "list.bullet", title: "Activity")
        shopTile.addAction(UIAction { [weak self] _ in self?.onShop?() }, for: .touchUpInside)
        settledTile.addAction(UIAction { [weak self] _ in self?.onSettled?() }, for: .touchUpInside)
        activityTile.addAction(UIAction { [weak self] _ in self?.onActivity?() }, for: .touchUpInside)
        let tiles = UIStackView(arrangedSubviews: [shopTile, settledTile, activityTile])
        tiles.spacing = Spacing.sm
        tiles.alignment = .fill

        // The day's streak and its week, in a card (#1494).
        let days = UIStackView(arrangedSubviews: [streak, week])
        days.axis = .vertical
        days.spacing = Spacing.sm
        days.isLayoutMarginsRelativeArrangement = true
        days.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
        )
        let streakCard = UIView()
        Surface.dressCard(streakCard)
        days.pin(to: streakCard)

        let column = UIStackView(arrangedSubviews: [coin, balance, unit, gauge, streakCard, tiles])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xs
        column.setCustomSpacing(Self.balanceAir, after: unit)
        column.setCustomSpacing(Spacing.lg, after: gauge)
        column.setCustomSpacing(Spacing.sm, after: streakCard)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            coin.heightAnchor.constraint(equalToConstant: 40),
            // The Shop is the large door: twice the others.
            shopTile.widthAnchor.constraint(equalTo: settledTile.widthAnchor, multiplier: 2),
            activityTile.widthAnchor.constraint(equalTo: settledTile.widthAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `sellsShop` false: the Shop tile shows the gems and opens nothing.
    func configure(with snapshot: WalletSnapshot, sellsShop: Bool) {
        rollingBalance.show(snapshot.balance, animated: window != nil)
        balance.accessibilityLabel = "\(snapshot.balance.formatted()) likes"
        gauge.configure(with: snapshot)
        applyStreak(snapshot)
        week.configure(with: snapshot)
        shopTile.configure(gems: snapshot.gems)
        shopTile.isEnabled = sellsShop
    }

    /// The streak's three faces — none yet, fed today, not yet fed — and
    /// today's claims against the day's cap.
    private func applyStreak(_ snapshot: WalletSnapshot) {
        let active = snapshot.streakDays > 0
        streakIcon.image = UIImage(
            systemName: active ? "flame.fill" : "flame",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )?.withTintColor(active ? .systemOrange : .secondaryLabel, renderingMode: .alwaysOriginal)
        streakLine.text = Self.streakText(for: snapshot)
        earnedLine.text = "\(snapshot.claimedToday) / \(snapshot.dailyClaimCap) today"
    }

    static func streakText(for snapshot: WalletSnapshot) -> String {
        guard snapshot.streakDays > 0 else { return "No streak yet · claim daily for up to ×2" }
        let kept = snapshot.claimedToday > 0 ? "Kept for today" : "Claim to keep it"
        return "\(snapshot.streakDays)-day streak · \(kept)"
    }

    /// The claim's payoff: the new number pops.
    func popBalance() {
        balance.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 2) {
            self.balance.transform = .identity
        }
    }
}

final class WalletHeaderCell: UICollectionViewCell {
    let header = WalletHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.pin(to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Action tile

/// One of the head's doors (#1494): a card (`Surface.dressCard`) with its
/// glyph over its word — the Shop's wears the gems instead of a glyph.
final class WalletActionTile: UIControl {
    private let top = UILabel()
    private let title = UILabel()

    override var isEnabled: Bool {
        didSet { accessibilityTraits = isEnabled ? .button : [.button, .notEnabled] }
    }

    init(identifier: String) {
        super.init(frame: .zero)
        Surface.dressCard(self)
        top.textAlignment = .center
        top.adjustsFontForContentSizeCategory = true
        title.font = .scaledSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, maximumPointSize: 17)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        let column = UIStackView(arrangedSubviews: [top, title])
        column.axis = .vertical
        column.spacing = Spacing.xs
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
        ])
        PressFeedback.attach(toView: self, sound: nil)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static var glyphFont: UIFont {
        .scaledSystemFont(ofSize: 20, weight: .semibold, relativeTo: .title3, maximumPointSize: 26)
    }

    /// A door: its glyph over its word.
    func configure(symbol: String, title text: String) {
        top.attributedText = NSAttributedString(attachment: NSTextAttachment(
            image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Self.glyphFont))?
                .withTintColor(.label, renderingMode: .alwaysOriginal) ?? UIImage()
        ))
        title.text = text
        accessibilityLabel = text
    }

    /// The Shop's door: "◆ 127" over "Shop" — the gem first (the owner,
    /// 2026-10-20), a door's glyph in its glyph's place.
    func configure(gems: Int) {
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 20, weight: .bold, relativeTo: .title3, maximumPointSize: 26)
        let line = NSMutableAttributedString(attributedString: walletGlyph(GemSymbol.glyphImage(), font: font))
        line.append(NSAttributedString(string: " \(gems.formatted())", attributes: [.font: font, .foregroundColor: UIColor.label]))
        top.attributedText = line
        title.text = "Shop"
        accessibilityLabel = "Shop"
        accessibilityValue = "\(gems.formatted()) gems"
    }
}
