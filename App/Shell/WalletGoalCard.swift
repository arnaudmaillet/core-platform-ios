import CoreStorage
import DesignSystem
import UIKit

/// The hub's gem goal (#1480): the Shop item the gems are headed for, and how
/// far — "320 more for the video banner" with a bar of the way there — or,
/// in reach, "You can get the Violet theme". A tap opens the Shop.
///
/// ```
///   ┌────────────────────────────────────────┐
///   │ (◆) 320 more for the video banner    › │
///   │     ▬▬▬▬▬▬▬▬▬░░░░░░░░░░░░░░░░░░░░░     │
///   └────────────────────────────────────────┘
/// ```
final class WalletGoalCard: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var fillWidth: NSLayoutConstraint?
    private var progress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = WalletSheetMetrics.cardFill
        layer.cornerRadius = WalletSheetMetrics.rowCorner
        layer.cornerCurve = .continuous

        icon.image = GemSymbol.glyphImage(.init(textStyle: .headline))
        icon.tintColor = GemSymbol.tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = .init(textStyle: .footnote, scale: .medium)
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        track.backgroundColor = .tertiarySystemFill
        track.layer.cornerRadius = 2
        fill.backgroundColor = GemSymbol.tint
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let text = UIStackView(arrangedSubviews: [title, track])
        text.axis = .vertical
        text.spacing = Spacing.xs
        let row = UIStackView(arrangedSubviews: [icon, text, chevron])
        row.spacing = Spacing.sm
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let width = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidth = width
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            width,
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
        ])
        PressFeedback.attach(toView: self, sound: nil)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the Shop"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillWidth?.constant = track.bounds.width * progress
    }

    func configure(goal: WalletGemGoal.Goal, gems: Int) {
        let line = Self.text(for: goal)
        title.text = line
        // Within reach, the bar is full; else the share of the price held.
        progress = goal.isAffordable ? 1 : CGFloat(gems) / CGFloat(max(1, goal.item.price))
        progress = min(1, max(0, progress))
        track.isHidden = goal.isAffordable
        setNeedsLayout()
        accessibilityLabel = line
    }

    /// "320 more for the video banner", or "You can get the Violet theme".
    static func text(for goal: WalletGemGoal.Goal) -> String {
        guard !goal.isAffordable else { return "You can get \(goal.item.name)" }
        return "\(goal.missing.formatted()) more for \(goal.item.name)"
    }

    /// The line drawn now. QA.
    var drawnText: String? { title.text }
}

/// The goal card as the hub's list holds it.
final class WalletGoalCardCell: UICollectionViewCell {
    let card = WalletGoalCard()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.pin(to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
