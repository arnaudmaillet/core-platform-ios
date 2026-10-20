import CoreStorage
import DesignSystem
import FeedInterface
import Maps
import MapsInterface
import MediaCore
import UIKit

/// The Claim sheet (#1476, structure B, the owner 2026-10-18): the small
/// sheet every balance badge opens — the daily job in one glance.
///
/// ```
///   [🏪 Shop]                         [✕]
///                  (♥)
///                  282
///                 Likes
///   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
///              282 of 2,000
///   🔥 3-day streak · Kept for today   25 / 200 today
///   M  T  W  T  F  S  S          ( ×1.3 tomorrow )
///   ●  ●  ◉  ○  ○  ○  ○
///   ┌───────────────────────────────────┐
///   │         Claim 25 likes            │
///   └───────────────────────────────────┘
///   ┌───────────────────────────────────┐
///   │ 👛 Wallet                 💎 37 › │
///   │    Gems, stakes and activity      │
///   └───────────────────────────────────┘
/// ```
///
/// One row, **Wallet**, pushes the hub (`WalletHubViewController`) on this
/// sheet's own navigation stack and grows the sheet to its large detent;
/// back comes to this screen and its small detent again. While this screen
/// is on top the sheet has ONE detent, measured from what it shows — there
/// is nothing more to grow into.
///
/// Its ground is the system's: glass while small, so the view is clear.
final class WalletClaimSheetViewController: UIViewController {
    private let wallet: WalletStore
    private let claimer: WalletClaimer
    private let makeHub: (WalletClaimer) -> WalletHubViewController
    /// The account's countries — what the Shop sells. Nil hides the Shop item.
    private let countries: (any CountryAccess)?
    private let stakePacks: (any StakePackSelling)?
    private let profileItems: (any ProfileItemSelling)?
    private let shopMedia: ShopMedia?

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
    private let claimButton = UIButton(configuration: .prominentGlass())
    private let walletRow = WalletHubRowButton()
    private let column = UIStackView()

    private var snapshot: WalletSnapshot
    private var countdownTimer: Timer?
    private let observers = WalletObserverTokenBag()

    /// The detent's height, measured from the laid-out column — a stored
    /// number, because a detent resolver must read nothing that could load a
    /// view.
    private var detentHeight: CGFloat = 420
    static let smallDetent = UISheetPresentationController.Detent.Identifier("wallet.small")

    /// Stable identifiers for the bar items: a reused identifier is how
    /// iOS 26 matches an item across a reinstall.
    static let shopItemIdentifier = "wallet.shop"
    static let closeItemIdentifier = "wallet.close"
    static let walletRowIdentifier = "wallet.hub.open"

    init(
        wallet: WalletStore,
        countries: (any CountryAccess)?,
        stakePacks: (any StakePackSelling)?,
        profileItems: (any ProfileItemSelling)?,
        shopMedia: ShopMedia?,
        makeHub: @escaping (WalletClaimer) -> WalletHubViewController
    ) {
        self.wallet = wallet
        self.claimer = WalletClaimer(wallet: wallet)
        self.countries = countries
        self.stakePacks = stakePacks
        self.profileItems = profileItems
        self.shopMedia = shopMedia
        self.makeHub = makeHub
        self.snapshot = wallet.snapshot()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that shows its bar, as a page sheet at the measured detent.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [Self.measuredDetent { [weak self] in self?.detentHeight ?? 420 }]
            sheet.selectedDetentIdentifier = Self.smallDetent
            sheet.prefersGrabberVisible = true
            // ⚠️ NO `preferredCornerRadius`: UIKit's own (see the hub's note).
        }
        return navigation
    }

    private static func measuredDetent(_ height: @escaping () -> CGFloat) -> UISheetPresentationController.Detent {
        .custom(identifier: smallDetent) { _ in height() }
    }

    private var sheet: UISheetPresentationController? {
        navigationController?.sheetPresentationController
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildColumn()
        buildBar()
        let wallet = wallet
        Task {
            await wallet.refreshFromServer()
            // The hub's stakes, warm before it is opened (#903).
            await wallet.refreshStakesFromServer()
        }
        observers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(
                forName: WalletClaimer.didChangeNotification, object: claimer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(
                forName: WalletClaimer.didClaimNotification, object: claimer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.popBalance() }
            },
        ]
        refresh()
        // Measured NOW, before the sheet asks its first detent: a guess here
        // would present at the guess and then jump to the answer.
        view.layoutIfNeeded()
        updateDetent()

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let landed: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            return view.window != nil && transitionCoordinator == nil
        }
        // `-wallet-demo-claim`: fires the Claim button once the sheet is up —
        // the real claim path minus the finger. Pair with `-open-wallet
        // -wallet-claim-ready`.
        if arguments.contains("-wallet-demo-claim") {
            QAWait.until("-wallet-demo-claim", landed) { [weak self] in
                guard let self else { return }
                claimer.claim(presentingFrom: self)
            }
        }
        // `-wallet-open-shop`: the Shop item's own path, once the sheet is up.
        if arguments.contains("-wallet-open-shop") {
            QAWait.until("-wallet-open-shop", landed) { [weak self] in self?.openShop() }
        }
        // `-wallet-open-hub` (and the hub's own hooks, `-wallet-sheet-large`,
        // `-wallet-open-stake`, `-wallet-sheet-scroll`): the Wallet row's path.
        if ["-wallet-open-hub", "-wallet-sheet-large", "-wallet-open-stake", "-wallet-sheet-scroll", "-wallet-open-stakes"]
            .contains(where: arguments.contains) {
            QAWait.until("-wallet-open-hub", landed) { [weak self] in self?.openHub() }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
        // Back from the hub: one detent again, the measured one.
        guard let sheet, sheet.detents.count > 1 else { return }
        let height = detentHeight
        sheet.animateChanges {
            sheet.detents = [Self.measuredDetent { [weak self] in self?.detentHeight ?? height }]
            sheet.selectedDetentIdentifier = Self.smallDetent
        }
        // ⚠️ A BACK SWIPE GIVEN UP leaves the hub on top: it gets its large
        // detent back, or it would sit squeezed in this screen's.
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled, let self else { return }
            self.growForHub()
        }
    }

    /// The hub's detents: this screen's measured one and large, at large.
    private func growForHub() {
        guard let sheet else { return }
        let height = detentHeight
        sheet.animateChanges {
            sheet.detents = [Self.measuredDetent { [weak self] in self?.detentHeight ?? height }, .large()]
            sheet.selectedDetentIdentifier = .large
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDetent()
    }

    // MARK: - Layout

    private func buildColumn() {
        coin.contentMode = .scaleAspectFit
        coin.image = LikesSymbol.coinImage(traits: traitCollection)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (screen: Self, _: UITraitCollection) in
            screen.coin.image = LikesSymbol.coinImage(traits: screen.traitCollection)
        }
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

        claimButton.configuration?.cornerStyle = .capsule
        claimButton.tintColor = Palette.prominentGlassTint
        if Palette.rules.heroButton == .gradient {
            var gradient = UIButton.Configuration.filled()
            gradient.cornerStyle = .capsule
            gradient.background.customView = BrandGradientView()
            gradient.baseForegroundColor = .white
            claimButton.configuration = gradient
            claimButton.configurationUpdateHandler = { button in
                button.configuration?.background.customView?.alpha = button.isEnabled ? 1 : 0.4
            }
        }
        claimButton.accessibilityIdentifier = "wallet.claim"
        claimButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            claimer.claim(presentingFrom: self)
        }, for: .primaryActionTriggered)
        PressFeedback.attach(to: claimButton, sound: nil)

        walletRow.accessibilityIdentifier = Self.walletRowIdentifier
        walletRow.addAction(UIAction { [weak self] _ in self?.openHub() }, for: .touchUpInside)

        [coin, balance, unit, gauge, streak, week, claimButton, walletRow].forEach(column.addArrangedSubview)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xs
        column.setCustomSpacing(Spacing.md, after: unit)
        column.setCustomSpacing(Spacing.md, after: gauge)
        column.setCustomSpacing(Spacing.sm, after: streak)
        column.setCustomSpacing(Spacing.lg, after: week)
        column.setCustomSpacing(Spacing.md, after: claimButton)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        let margin = WalletSheetMetrics.sideMargin
        NSLayoutConstraint.activate([
            coin.heightAnchor.constraint(equalToConstant: 36),
            claimButton.heightAnchor.constraint(equalToConstant: WalletSheetMetrics.claimHeight),
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
        ])
    }

    /// The detent: the bar, the column and a margin under it. Measured from
    /// the laid-out column rather than typed, so Dynamic Type cannot cut it.
    private func updateDetent() {
        guard let sheet, sheet.detents.count == 1 else { return }
        let fitted = column.systemLayoutSizeFitting(
            CGSize(width: max(view.bounds.width - 2 * WalletSheetMetrics.sideMargin, 1), height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        // ⚠️ A custom detent's height EXCLUDES the bottom safe area — the
        // sheet adds it back. Read from the PRESENTER's window too: this is
        // measured in `viewDidLoad`, before the sheet has a window of its own.
        let window = view.window ?? presentingViewController?.view.window
        let bottomInset = window?.safeAreaInsets.bottom ?? 0
        let height = (barClearance() + Spacing.sm + fitted + WalletSheetMetrics.sideMargin
            + max(0, Spacing.lg - bottomInset)).rounded()
        guard abs(height - detentHeight) > 0.5 else { return }
        detentHeight = height
        sheet.invalidateDetents()
    }

    /// The band the navigation bar takes at the sheet's top: the top safe
    /// area once laid out; before that the bar's own fitted height.
    private func barClearance() -> CGFloat {
        if view.safeAreaInsets.top > 0 { return view.safeAreaInsets.top }
        guard let bar = navigationController?.navigationBar else { return 0 }
        return bar.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
    }

    // MARK: - Bar

    /// `[🏪 Shop] ······ [✕]` — no title: the balance under it says what the
    /// sheet is.
    private func buildBar() {
        navigationItem.largeTitleDisplayMode = .never
        // The hub's back button says where it goes.
        navigationItem.backButtonTitle = "Claim"
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.identifier = Self.closeItemIdentifier
        close.accessibilityIdentifier = Self.closeItemIdentifier
        navigationItem.rightBarButtonItem = close
        if countries != nil {
            navigationItem.leftBarButtonItem = makeShopItem()
        }
    }

    /// The Shop: the store's own glyph (`CountryShopEntry.symbolName`, the
    /// Explore header's door) AND its name. A stock bar item draws one or the
    /// other, never both, so it is a PLAIN button as the item's custom view —
    /// no material of its own, the bar's glass is the only capsule.
    private func makeShopItem() -> UIBarButtonItem {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: CountryShopEntry.symbolName)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 15, weight: .semibold
        )
        configuration.title = CountryShopEntry.title
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaledSystemFont(
                ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 22
            )
            return attributes
        }
        let button = UIButton(configuration: configuration)
        // The Explore header's door is also "Shop": the identifier tells
        // the two apart in the accessibility tree.
        button.accessibilityIdentifier = Self.shopItemIdentifier
        button.addAction(UIAction { [weak self] _ in self?.openShop() }, for: .primaryActionTriggered)
        button.sizeToFit()
        let item = UIBarButtonItem(customView: button)
        item.identifier = Self.shopItemIdentifier
        item.accessibilityLabel = CountryShopEntry.title
        return item
    }

    /// The Shop — where the gems go. A pushed screen since 2026-10-13: this
    /// sheet comes down and the Shop is pushed on the stack under it
    /// (`StakeShop.push`).
    func openShop() {
        guard let countries, presentedViewController == nil,
              let root = view.window?.rootViewController else { return }
        StakeShop.push(
            CountryShopViewController.storefront(
                access: countries, stakePacks: stakePacks, profileItems: profileItems, media: shopMedia
            ),
            over: root
        )
    }

    /// Wallet: the hub, pushed in this sheet, which grows to its large detent.
    func openHub() {
        guard let navigationController, navigationController.topViewController === self,
              transitionCoordinator == nil else { return }
        let hub = makeHub(claimer)
        navigationController.pushViewController(hub, animated: true)
        growForHub()
    }

    // MARK: - State

    private func refresh() {
        snapshot = wallet.snapshot()
        rollingBalance.show(snapshot.balance, animated: viewIfLoaded?.window != nil)
        balance.accessibilityLabel = "\(snapshot.balance.formatted()) likes"
        gauge.configure(with: snapshot)
        applyStreak()
        week.configure(with: snapshot)
        walletRow.configure(gems: snapshot.gems)
        applyClaimButton()
    }

    /// The streak's three faces — none yet, fed today, not yet fed — and
    /// today's claims against the day's cap.
    private func applyStreak() {
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

    private func applyClaimButton() {
        claimButton.isEnabled = snapshot.claimAvailable && !claimer.isPending
        var title = AttributedString(WalletClaimer.title(for: snapshot, pending: claimer.isPending))
        title.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24
        )
        claimButton.configuration?.attributedTitle = title
    }

    private func popBalance() {
        balance.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 2) {
            self.balance.transform = .identity
        }
    }

    // MARK: - Clock

    /// Once a second: the claim countdown.
    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshot = self.wallet.snapshot()
                self.applyClaimButton()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }
}

/// The Claim sheet's one way further: the Wallet row — what is inside (the
/// gems, the stakes, the activity) and the gems' count beside the chevron.
final class WalletHubRowButton: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let gems = UILabel()
    private let chevron = UIImageView()

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .quaternarySystemFill : WalletSheetMetrics.cardFill }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = WalletSheetMetrics.cardFill
        layer.cornerRadius = WalletSheetMetrics.rowCorner
        layer.cornerCurve = .continuous
        icon.image = UIImage(systemName: "wallet.bifold", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        icon.tintColor = .label
        icon.contentMode = .center
        title.text = "Wallet"
        title.font = .scaledSystemFont(ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 22)
        title.adjustsFontForContentSizeCategory = true
        detail.text = "Gems, stakes and activity"
        detail.font = .scaledSystemFont(ofSize: 12, relativeTo: .caption1, maximumPointSize: 16)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        gems.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text, gems, chevron])
        row.alignment = .center
        row.spacing = Spacing.sm
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Wallet"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(gems count: Int) {
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 20)
        gems.attributedText = walletAmount(count.formatted(), glyph: GemSymbol.glyphImage(), font: font, color: .label)
        accessibilityValue = "\(count.formatted()) gems"
    }
}
