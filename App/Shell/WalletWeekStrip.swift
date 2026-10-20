import CoreStorage
import DesignSystem
import UIKit

/// The Claim sheet's week (#1479): seven dots for the current UTC week,
/// Monday first — a claimed day filled in the streak's orange, today ringed —
/// and, at the trailing end, what the streak pays next as a chip
/// ("×1.3 tomorrow").
///
/// ```
///   M  T  W  T  F  S  S             ( ×1.3 tomorrow )
///   ●  ●  ◉  ○  ○  ○  ○
/// ```
final class WalletWeekStrip: UIView {
    private let dots = UIStackView()
    private let chip = UILabel()
    private let chipGround = UIView()
    private var columns: [(letter: UILabel, dot: WalletWeekDot)] = []

    static let dotDiameter: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        for letter in letters {
            let label = UILabel()
            label.text = letter
            label.font = .scaledSystemFont(ofSize: 11, weight: .semibold, relativeTo: .caption2, maximumPointSize: 15)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            let dot = WalletWeekDot()
            let column = UIStackView(arrangedSubviews: [label, dot])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 3
            dots.addArrangedSubview(column)
            columns.append((label, dot))
        }
        dots.spacing = Spacing.sm
        dots.alignment = .bottom
        dots.isAccessibilityElement = false

        chip.font = .scaledMonospacedDigitSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, maximumPointSize: 17)
        chip.adjustsFontForContentSizeCategory = true
        chip.textColor = .systemOrange
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        chipGround.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.14)
        chipGround.layer.cornerCurve = .continuous
        chip.translatesAutoresizingMaskIntoConstraints = false
        chipGround.addSubview(chip)

        let spacer = UIView()
        let row = UIStackView(arrangedSubviews: [dots, spacer, chipGround])
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: chipGround.topAnchor, constant: 4),
            chip.bottomAnchor.constraint(equalTo: chipGround.bottomAnchor, constant: -4),
            chip.leadingAnchor.constraint(equalTo: chipGround.leadingAnchor, constant: 10),
            chip.trailingAnchor.constraint(equalTo: chipGround.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        chipGround.layer.cornerRadius = chipGround.bounds.height / 2
    }

    func configure(with snapshot: WalletSnapshot, now: Date = Date()) {
        let claimedToday = snapshot.claimedToday > 0
        let week = WalletWeek.days(streakDays: snapshot.streakDays, claimedToday: claimedToday, now: now)
        for (column, day) in zip(columns, week) {
            column.dot.configure(claimed: day.isClaimed, today: day.isToday)
            column.letter.textColor = day.isToday ? .label : .secondaryLabel
        }
        let next = WalletWeek.nextMultiplier(streakDays: snapshot.streakDays, claimedToday: claimedToday)
        let multiplier = WalletWeek.multiplierText(next.multiplier)
        // No bonus yet (×1, no streak): no chip — "×1 today" says nothing.
        let hasBonus = next.multiplier > 1
        chip.text = hasBonus ? "\(multiplier) \(next.isTomorrow ? "tomorrow" : "today")" : nil
        chipGround.isHidden = !hasBonus
        let claimedDays = week.filter(\.isClaimed).count
        accessibilityLabel = "This week"
        let when = next.isTomorrow ? "tomorrow" : "today"
        let bonus: String = hasBonus ? ". Next claim pays \(multiplier) \(when)" : ""
        accessibilityValue = "\(claimedDays) of 7 days claimed\(bonus)"
    }

    /// The days as drawn: (claimed, today). Tests and QA.
    var drawnDays: [(claimed: Bool, today: Bool)] { columns.map { ($0.dot.isClaimed, $0.dot.isToday) } }
    var drawnChip: String? { chip.text }
}

/// One day's dot: filled orange when claimed, a hollow ring otherwise; today
/// wears an outer ring in the label's ink.
final class WalletWeekDot: UIView {
    private let fill = CAShapeLayer()
    private let ring = CAShapeLayer()
    private(set) var isClaimed = false
    private(set) var isToday = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(fill)
        layer.addSublayer(ring)
        ring.fillColor = nil
        ring.lineWidth = 1.5
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
        ) { (dot: WalletWeekDot, _: UITraitCollection) in
            dot.applyColours()
        }
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: WalletWeekStrip.dotDiameter + 6, height: WalletWeekStrip.dotDiameter + 6)
    }

    func configure(claimed: Bool, today: Bool) {
        isClaimed = claimed
        isToday = today
        applyColours()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = WalletWeekStrip.dotDiameter / 2
        fill.frame = bounds
        ring.frame = bounds
        fill.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        ring.path = UIBezierPath(
            arcCenter: center, radius: radius + 2.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true
        ).cgPath
        fill.lineWidth = 1.5
    }

    private func applyColours() {
        let traits = traitCollection
        if isClaimed {
            fill.fillColor = UIColor.systemOrange.resolvedColor(with: traits).cgColor
            fill.strokeColor = nil
        } else {
            fill.fillColor = nil
            fill.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traits).cgColor
        }
        ring.strokeColor = isToday ? UIColor.label.resolvedColor(with: traits).cgColor : nil
    }
}
