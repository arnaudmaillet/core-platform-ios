import CoreStorage
import DesignSystem
import UIKit

/// How the wallet works (#1480), as a numbered list — claim, stake, settle,
/// gems, Shop — that ends on the action that starts the loop: the claim.
///
/// Pushed in the wallet sheet: once per account, the first time the hub
/// opens (`WalletHowItWorks.shouldShow`, CoreStorage), then only from the hub's **?**.
final class WalletHowItWorksViewController: UIViewController {
    private let wallet: WalletStore
    private let claimer: WalletClaimer
    private let claimButton = UIButton(configuration: .prominentGlass())
    private let observers = WalletObserverTokenBag()

    /// The steps, in the loop's order.
    static let steps: [(symbol: String, title: String, detail: String)] = [
        ("plus.circle.fill", "Claim likes", "Free likes every hour. Claim every day to grow your streak bonus, up to ×2."),
        (LikesSymbol.glyph, "Stake them", "A like is a stake: the likes you give a post are staked on it."),
        ("clock.fill", "It settles", "A day later the stake settles, rewarded if the post turned out to matter to people."),
        (GemSymbol.glyph, "Earn gems", "Rewarded stakes earn gems. Gems are only ever earned, never bought."),
        ("storefront.fill", "Spend them", "In the Shop: themes, countries, boosts and more."),
    ]

    init(wallet: WalletStore, claimer: WalletClaimer) {
        self.wallet = wallet
        self.claimer = claimer
        super.init(nibName: nil, bundle: nil)
        title = "How it works"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own ground is the surface (the hub's note).
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

        claimButton.configuration?.cornerStyle = .capsule
        claimButton.tintColor = Palette.prominentGlassTint
        claimButton.accessibilityIdentifier = "wallet.howItWorks.claim"
        claimButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            claimer.claim(presentingFrom: self)
            // Back to where the claim shows.
            navigationController?.popViewController(animated: true)
        }, for: .primaryActionTriggered)
        PressFeedback.attach(to: claimButton, sound: nil)
        column.addArrangedSubview(claimButton)
        column.setCustomSpacing(Spacing.xl, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])

        let margin = WalletSheetMetrics.sideMargin
        NSLayoutConstraint.activate([
            claimButton.heightAnchor.constraint(equalToConstant: WalletSheetMetrics.claimHeight),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: margin),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -margin),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * margin),
        ])

        observers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyClaim() }
            },
            NotificationCenter.default.addObserver(
                forName: WalletClaimer.didChangeNotification, object: claimer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyClaim() }
            },
        ]
        applyClaim()
    }

    /// The loop's first action: the claim, as the Claim sheet's button says
    /// it — "Next claim in 42:07" while there is none.
    private func applyClaim() {
        let snapshot = wallet.snapshot()
        claimButton.isEnabled = snapshot.claimAvailable && !claimer.isPending
        var title = AttributedString(WalletClaimer.title(for: snapshot, pending: claimer.isPending))
        title.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24
        )
        claimButton.configuration?.attributedTitle = title
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
