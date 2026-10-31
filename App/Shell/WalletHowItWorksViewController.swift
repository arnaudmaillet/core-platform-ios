import CoreStorage
import DesignSystem
import UIKit

/// How Rewards work (#1480), as a numbered list — claim, stake, settle,
/// gems, Shop. Nothing to press (#1494): the Claim is the Rewards sheet's.
///
/// Pushed in the Rewards sheet: once per account, the first time the sheet
/// opens (`WalletHowItWorks.shouldShow`, CoreStorage), then only from the sheet's **?**.
final class WalletHowItWorksViewController: UIViewController {

    /// The steps, in the loop's order.
    static let steps: [(symbol: String, title: String, detail: String)] = [
        ("plus.circle.fill", "Claim likes", "Free likes every hour. Claim every day to grow your streak bonus, up to ×2."),
        (LikesSymbol.glyph, "Stake them", "A like is a stake: the likes you give a post are staked on it."),
        ("clock.fill", "It settles", "A day later the stake settles, rewarded if the post turned out to matter to people."),
        (GemSymbol.glyph, "Earn gems", "Rewarded stakes earn gems. Gems are only ever earned, never bought."),
        ("storefront.fill", "Spend them", "In the Shop: themes, countries, boosts and more."),
    ]

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "How it works"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own ground is the surface (the Wallet sheet's note).
        view.backgroundColor = .clear
        navigationItem.largeTitleDisplayMode = .never

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.topEdgeEffect.style = .soft
        view.addSubview(scroll)
        scroll.pin(to: view)
        setContentScrollView(scroll, for: .top)

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        for (index, step) in Self.steps.enumerated() {
            column.addArrangedSubview(Self.stepRow(number: index + 1, step: step))
        }

        let margin = WalletSheetMetrics.sideMargin
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: margin),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -margin),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * margin),
        ])
    }

    /// "① (glyph) Claim likes / Free likes every hour…"
    private static func stepRow(number: Int, step: (symbol: String, title: String, detail: String)) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = .scaledMonospacedDigitSystemFont(ofSize: 15, weight: .bold, relativeTo: .subheadline, maximumPointSize: 20)
        badge.adjustsFontForContentSizeCategory = true
        badge.textAlignment = .center
        badge.textColor = .label
        badge.backgroundColor = .tertiarySystemFill
        badge.layer.cornerRadius = 15
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        let icon = UIImageView(image: UIImage.symbol(named: step.symbol))
        icon.preferredSymbolConfiguration = .init(textStyle: .headline)
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.text = step.title
        title.font = .appFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        let heading = UIStackView(arrangedSubviews: [title, icon])
        heading.spacing = Spacing.xs
        heading.alignment = .center
        let detail = UILabel()
        detail.text = step.detail
        detail.font = .appFont(forTextStyle: .subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [heading, detail])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [badge, text])
        row.spacing = Spacing.md
        row.alignment = .top
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
        ])
        row.isAccessibilityElement = true
        row.accessibilityLabel = "Step \(number): \(step.title). \(step.detail)"
        return row
    }
}

// MARK: - How it is left (#1144)

extension WalletHowItWorksViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
