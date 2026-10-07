import DesignSystem
import UIKit
import CoreModels
import CoreNavigation

/// The offer a locked country makes when it is tapped on the map:
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │ ╭────╮ Spain  Europe                │
///  │ │ 🇪🇸 │  12K    86                   │
///  │ ╰──#4╯ Likes  Posts   ·      ·      │
///  │  Unlock Spain to see its posts on    │
///  │  your map.                           │
///  │  You have 100 gems                   │
///  │(        ◆ Unlock · 50               )│  ← the native toolbar
///  └──────────────────────────────────────┘
/// ```
///
/// The header is the place identity row (`PlaceIdentityView`, DesignSystem),
/// the place page's too: the country's ROUND flag where a profile's avatar
/// stands — the map's own artwork, drawn large (`FlagPalette.largeRoundFlag`)
/// — and beside it the name and its continent over Likes and Posts. The RANK
/// rides the flag as a bubble.
///
/// One detent, the content's own height and the toolbar's; the map stays
/// visible and the country stays lifted above the sheet. Gems only — points
/// (likes) never buy a country. Short of gems, the button is disabled and the
/// line above it says how many are missing.
///
/// **THE UNLOCK IS THE SHEET'S NATIVE TOOLBAR**, as "Use this sound" is the
/// sound sheet's: the screen is presented as the root of a navigation
/// controller that hides its bar and shows its toolbar (`wrappedInSheet`),
/// and the prominent capsule fills the toolbar.
final class CountryUnlockSheetViewController: UIViewController {
    /// The country was unlocked; the sheet is on its way out.
    var onUnlocked: ((String) -> Void)?
    /// The sheet is committed to leaving — as it STARTS going down, unlocked
    /// or not (`OfferCloseFlight`). At most once per close.
    var onClosing: (() -> Void)?
    /// A dismissal that had already reported `onClosing` was cancelled: the
    /// sheet is back up.
    var onCloseCancelled: (() -> Void)?
    /// The sheet is gone, unlocked or not.
    var onDismissed: (() -> Void)?

    private let country: CountryAtlas.Country
    private let access: any CountryAccess
    private let stack = UIStackView()
    /// The unlock — the toolbar's one item.
    let unlockButton = UIButton(configuration: .prominentGlass())
    private let balanceLabel = UILabel()
    private var closeFlight = OfferCloseFlight()
    private static let detent = UISheetPresentationController.Detent.Identifier("country.unlock")
    /// The content's height — measured when the view loads.
    private(set) var contentHeight: CGFloat = 330
    /// The toolbar's band above the home indicator: the bar's own estimate
    /// until the sheet is on screen, then what its safe area says.
    private(set) var toolbarBand: CGFloat = 52
    /// The sheet's height above the bottom safe area: the content and the
    /// toolbar. The map frames the country above it.
    ///
    /// ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
    /// adds it back (the wallet sheet's rule).
    var sheetHeight: CGFloat { contentHeight + toolbarBand }

    init(country: CountryAtlas.Country, access: any CountryAccess) {
        self.country = country
        self.access = access
        super.init(nibName: nil, bundle: nil)
    }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that hides its bar and shows its TOOLBAR (the unlock), set
    /// up as a page sheet of one detent.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.setToolbarHidden(false, animated: false)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.detent) { [weak self] context in
                min(self?.sheetHeight ?? 380, context.maximumDetentValue)
            }]
            sheet.prefersGrabberVisible = true
            // The map behind stays live: the lifted country is what is sold.
            sheet.largestUndimmedDetentIdentifier = Self.detent
        }
        return navigation
    }

    /// Whether the sheet is on its way out — the navigation controller is
    /// what is presented, and so what is dismissed.
    var isLeaving: Bool { (navigationController ?? self).isBeingDismissed }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own glass is the surface.
        view.backgroundColor = .clear
        let standing = access.standing(of: country.code)

        let header = Self.header(country: country, standing: standing)

        let pitch = UILabel()
        pitch.text = "Unlock \(country.name) to see its posts on your map."
        pitch.font = .appFont(forTextStyle: .subheadline)
        pitch.textColor = .secondaryLabel
        pitch.numberOfLines = 0

        let price = standing?.price ?? CountryStanding.price(forRank: .max)
        configureUnlockButton(price: price)
        let unlockItem = UIBarButtonItem(customView: unlockButton)
        // Its own prominent capsule is its background: no bubble in a bubble.
        unlockItem.hidesSharedBackground = true
        toolbarItems = [unlockItem]

        balanceLabel.font = .appFont(forTextStyle: .footnote)
        balanceLabel.textColor = .secondaryLabel
        refreshBalance(price: price)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(Spacing.lg, after: header)
        stack.addArrangedSubview(pitch)
        stack.setCustomSpacing(Spacing.sm, after: pitch)
        stack.addArrangedSubview(balanceLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
        ])
        measure()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // On screen: the toolbar's real band, read off the safe area — the
        // bar's own estimate answered 48 where the sheet gave 52 (the sound
        // sheet's measure). Re-ask the detent only when it moved.
        guard let window = view.window else { return }
        let band = max(0, view.safeAreaInsets.bottom - window.safeAreaInsets.bottom)
        guard band > 0, band < 120, abs(band - toolbarBand) > 0.5 else { return }
        toolbarBand = band
        navigationController?.sheetPresentationController?.animateChanges {
            navigationController?.sheetPresentationController?.invalidateDetents()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isLeaving else { return }
        // ⚠️ Not `viewDidDisappear`: the map's flight back waits for nothing
        // the sheet does on its way down — see `OfferCloseFlight`.
        let coordinator = transitionCoordinator
        let interactive = coordinator?.isInteractive ?? false
        #if DEBUG
        OfferLog.note("dismissal began interactive=\(interactive)")
        #endif
        dismissalBegan(interactive: interactive)
        coordinator?.notifyWhenInteractionChanges { [weak self] context in
            #if DEBUG
            OfferLog.note("released cancelled=\(context.isCancelled)")
            #endif
            self?.dismissalReleased(cancelled: context.isCancelled)
        }
        coordinator?.animate(alongsideTransition: nil) { [weak self] context in
            #if DEBUG
            OfferLog.note("dismissal ended cancelled=\(context.isCancelled)")
            #endif
            self?.dismissalEnded(cancelled: context.isCancelled)
        }
    }

    // The dismissal's three moments, as the transition coordinator reports
    // them (internal: a package test host never completes a modal, so the
    // tests drive these directly).

    func dismissalBegan(interactive: Bool) {
        perform(closeFlight.dismissalBegan(interactive: interactive))
    }

    func dismissalReleased(cancelled: Bool) {
        perform(closeFlight.interactionEnded(cancelled: cancelled))
    }

    func dismissalEnded(cancelled: Bool) {
        perform(closeFlight.dismissalEnded(cancelled: cancelled))
    }

    private func perform(_ action: OfferCloseFlight.Action) {
        switch action {
        case .none: break
        case .close: onClosing?()
        case .restore: onCloseCancelled?()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeaving { onDismissed?() }
    }

    /// The detent is the content and the toolbar: measured once, before the
    /// sheet rises — the toolbar's band as the bar estimates it.
    private func measure() {
        if let toolbar = navigationController?.toolbar {
            let estimate = toolbar.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
            if estimate > 0 { toolbarBand = estimate }
        }
        let width = presentingViewController?.view.window?.bounds.width ?? UIScreen.main.bounds.width
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width - 2 * Spacing.lg, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        contentHeight = (Spacing.xl + size.height + Spacing.lg).rounded()
    }

    /// The prominent blue capsule, as tall as a bar's bubbles, filling the
    /// toolbar.
    ///
    /// **IT FILLS THE BAR BY AUTO LAYOUT, NOT BY ARITHMETIC** — the sound
    /// sheet's "Use this sound": there is no flexible-width bar item, and a
    /// `.prominent` title item's `width` is ignored on iOS 27. A custom view
    /// that hugs nothing and asks, at the lowest priority, for more room than
    /// any bar has is stretched by the bar to exactly what it leaves.
    private func configureUnlockButton(price: Int) {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.image = UIImage(systemName: "diamond.fill")
        configuration.imagePadding = Spacing.sm
        configuration.title = "Unlock · \(price)"
        configuration.cornerStyle = .capsule
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaledFont(forTextStyle: .body, weight: .semibold)
            return attributes
        }
        unlockButton.configuration = configuration
        unlockButton.tintColor = .systemBlue
        unlockButton.accessibilityIdentifier = "country.unlock.button"
        unlockButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            guard !access.purchasesRestricted else {
                let alert = UIAlertController(title: nil, message: PurchaseRestriction.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            MemberGates.perform(.unlockCountry, from: self) { [weak self] in self?.unlock() }
        }, for: .primaryActionTriggered)
        unlockButton.setContentHuggingPriority(.init(1), for: .horizontal)
        let fill = unlockButton.widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(2)
        // 999, never required: the bar's first pass pins its item wrapper to
        // the raw intrinsic size.
        let height = unlockButton.heightAnchor.constraint(equalToConstant: Self.barBubbleHeight)
        height.priority = .init(999)
        NSLayoutConstraint.activate([fill, height])
    }

    /// A bar's glass bubbles' height: 48 on iOS 27 (the sound sheet's
    /// measure) — at 44 a capsule stood visibly shorter.
    static let barBubbleHeight: CGFloat = 48

    private func refreshBalance(price: Int) {
        let gems = access.gems
        if gems >= price {
            balanceLabel.text = "You have \(gems) gems"
            balanceLabel.textColor = .secondaryLabel
            unlockButton.isEnabled = true
        } else {
            balanceLabel.text = "You need \(price - gems) more gems"
            balanceLabel.textColor = .systemRed
            unlockButton.isEnabled = false
        }
    }

    private func unlock() {
        switch access.unlock(country.code) {
        case .unlocked, .alreadyUnlocked:
            HapticNotification().notificationOccurred(.success)
            let code = country.code
            let unlocked = onUnlocked
            dismiss(animated: true) { unlocked?(code) }
        case .insufficientGems(let needed, _):
            HapticNotification().notificationOccurred(.error)
            refreshBalance(price: needed)
        case .unknownCountry:
            dismiss(animated: true)
        }
    }

    // MARK: - Header

    /// The place identity row (`PlaceIdentityView`, shared with the place
    /// page): the country's round flag at its LARGE size, the rank in a
    /// bubble over it, the name and its continent, Likes and Posts.
    static func header(country: CountryAtlas.Country, standing: CountryStanding?) -> PlaceIdentityView {
        PlaceIdentityView(
            // The round flag the map wears (an emoji drawn and trimmed for a
            // code the catalog lacks — never an atlas country).
            flag: FlagPalette.largeRoundFlag(for: country.code) ?? FlagPalette.image(for: country.code),
            name: country.name,
            subtitle: country.continent,
            counters: [
                .init(value: standing.map { CountryStanding.compact($0.likes) } ?? "—", caption: "Likes"),
                .init(value: standing.map { "\($0.posts)" } ?? "—", caption: standing?.posts == 1 ? "Post" : "Posts"),
            ],
            rank: standing.map { "#\($0.rank)" } ?? "#—"
        )
    }
}
