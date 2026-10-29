import DesignSystem
import UIKit
import CoreModels
import CoreNavigation

/// The offer a locked country makes when it is tapped on the map:
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │            Spain  Europe        (✕) │  ← the bar's close item
///  │ ╭────╮      #4      12K              │
///  │ │ 🇪🇸 │   Ranking  Likes             │
///  │ ╰────╯                               │
///  │  Unlock Spain to see its posts on    │
///  │  your map.                           │
///  │  You have 100 gems                   │
///  │(        ◆ Unlock · 50               )│  ← the native toolbar
///  └──────────────────────────────────────┘
/// ```
///
/// The header is the place identity row (`PlaceIdentityView`, DesignSystem)
/// in the PLACE PAGE's arrangement (`.page`, #1597, #1600): the country's
/// ROUND flag where a profile's avatar stands — the map's own artwork, drawn
/// large (`FlagPalette.largeRoundFlag`) — and beside it the rank and the
/// likes at one size, centred on it, under the name and its continent.
///
/// One detent, the content's own height and the toolbar's; the map stays
/// visible and the country stays lifted above the sheet. Gems only — points
/// (likes) never buy a country. Short of gems, the button is disabled and the
/// line above it says how many are missing.
///
/// **THE UNLOCK IS THE SHEET'S NATIVE TOOLBAR**, as "Use this sound" is the
/// sound sheet's: the screen is presented as the root of a navigation
/// controller that shows its toolbar (`wrappedInSheet`), and the prominent
/// capsule fills the toolbar. Its BAR shows too, for the close item
/// top-RIGHT (the owner, 2026-10-22: the sound sheet's side), with the
/// content starting behind it (#1600).
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

    private(set) var country: CountryAtlas.Country
    private let access: any CountryAccess
    private let stack = UIStackView()
    /// The unlock's view — the toolbar's one item, its bubble the bar's
    /// (#1679, `BarItems.stretched`). What a test reads.
    private(set) var unlockControl: StretchedBarLabel?
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
        // ⚠️ THE BAR SHOWS, FOR ITS CLOSE ITEM (#1600, the owner 2026-10-22),
        // and the content does NOT move for it: it starts behind the bar, the
        // sound sheet's arrangement (`SoundSheetViewController`).
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
        // ✕ top-RIGHT, the sound sheet's side (the owner, 2026-10-22: it was
        // left in #1600, "la croix … doit être à droite").
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            (self?.navigationController ?? self)?.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "countryUnlock.close"
        close.identifier = "countryUnlock.close"
        navigationItem.rightBarButtonItem = close

        balanceLabel.font = .appFont(forTextStyle: .footnote)
        balanceLabel.textColor = .secondaryLabel

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        fillContent()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
        ])
        measure()
    }

    /// The country's header, pitch, price and balance, in the stack.
    private func fillContent() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let standing = access.standing(of: country.code)
        let header = Self.header(country: country, standing: standing)
        let pitch = UILabel()
        pitch.text = "Unlock \(country.name) to see its posts on your map."
        pitch.font = .appFont(forTextStyle: .subheadline)
        pitch.textColor = .secondaryLabel
        pitch.numberOfLines = 0
        let price = standing?.price ?? CountryStanding.price(forRank: .max)
        installUnlock(price: price)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(Spacing.lg, after: header)
        stack.addArrangedSubview(pitch)
        stack.setCustomSpacing(Spacing.sm, after: pitch)
        stack.addArrangedSubview(balanceLabel)
    }

    /// Offers another country in place (#760): from one locked country
    /// straight to the next, the sheet staying up — no close, no neutral
    /// state between. The content cross-fades, and the detent follows its
    /// new height.
    func show(_ country: CountryAtlas.Country) {
        guard country.code != self.country.code else { return }
        self.country = country
        guard isViewLoaded else { return }
        UIView.transition(with: stack, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.fillContent()
        }
        measure()
        let presentation = navigationController?.sheetPresentationController
        presentation?.animateChanges { presentation?.invalidateDetents() }
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

    /// The unlock at `price`: a new item under the same identifier whenever
    /// the price changes (another country, a new price from the server) —
    /// the bar animates the swap (R3) — and the balance under it.
    private func installUnlock(price: Int, busy: Bool = false) {
        let title = "Unlock · \(price)"
        if unlockControl?.title != title || unlockControl?.isBusy != busy {
            // At work (#1775): the busy twin — the loader in the gem's place,
            // no tap — under the same identifier, so the bar morphs to it.
            let made = BarItems.stretched(
                id: "countryUnlock.unlock", title: title, image: UIImage.symbol(named: GemSymbol.glyph), prominent: true,
                busy: busy
            ) { [weak self] in self?.unlockTapped() }
            made.label.accessibilityIdentifier = "country.unlock.button"
            unlockControl = made.label
            setToolbarItems([made.item], animated: viewIfLoaded?.window != nil)
        }
        unlockPrice = price
        refreshBalance(price: price)
    }

    /// The price the unlock control asks.
    private var unlockPrice: Int?

    /// A purchase-restricted device is told why; anyone else is asked to
    /// be a member, then the server is.
    private func unlockTapped() {
        guard !access.purchasesRestricted else {
            let alert = UIAlertController(title: nil, message: PurchaseRestriction.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        MemberGates.perform(.unlockCountry, from: self) { [weak self] in
            Task { [weak self] in await self?.unlock() }
        }
    }

    private func refreshBalance(price: Int) {
        let gems = access.gems
        if gems >= price {
            balanceLabel.text = "You have \(gems) gems"
            balanceLabel.textColor = .secondaryLabel
            unlockControl?.isEnabled = true
        } else {
            balanceLabel.text = "You need \(price - gems) more gems"
            balanceLabel.textColor = .systemRed
            unlockControl?.isEnabled = false
        }
    }

    private func unlock() async {
        // One unlock at a time: the server is being asked, and the control
        // says so (#1775).
        guard unlockControl?.isBusy != true else { return }
        let asked = unlockPrice
        if let asked { installUnlock(price: asked, busy: true) }
        let outcome = await access.unlock(country.code)
        // Back to the word, unless the sheet leaves on the answer.
        switch outcome {
        case .unlocked, .alreadyUnlocked, .unknownCountry, .priceChanged: break
        case .insufficientGems, .failed: if let asked { installUnlock(price: asked) }
        }
        switch outcome {
        case .unlocked, .alreadyUnlocked:
            Haptics.play(.success)
            let code = country.code
            let unlocked = onUnlocked
            dismiss(animated: true) { unlocked?(code) }
        case .insufficientGems(let needed, _):
            Haptics.play(.error)
            refreshBalance(price: needed)
        case .priceChanged(let price):
            // The new price, to confirm again (#1475): nothing was charged.
            Feedback.failure("The price changed: now \(price) gems. Nothing was charged.", from: self)
            installUnlock(price: price)
        case .failed:
            Feedback.failure(ShopPurchaseFeedback.unreachable, from: self)
        case .unknownCountry:
            dismiss(animated: true)
        }
    }

    // MARK: - Header

    /// The place identity row (`PlaceIdentityView`, shared with the place
    /// page): ⚠️ THE PLACE PAGE'S OWN ARRANGEMENT since #1600 (`.page`, #1597)
    /// — the round flag where the avatar stands, the rank and the likes at
    /// one size centred on it, the name and its continent right above them —
    /// so the sheet and the page it sells cannot drift apart.
    static func header(country: CountryAtlas.Country, standing: CountryStanding?) -> PlaceIdentityView {
        PlaceIdentityView(
            // The round flag the map wears (an emoji drawn and trimmed for a
            // code the catalog lacks — never an atlas country).
            flag: FlagPalette.largeRoundFlag(for: country.code) ?? FlagPalette.image(for: country.code),
            name: country.name,
            subtitle: country.continent,
            counters: [
                .init(value: standing.map { CountryStanding.compact($0.likes) } ?? "—", caption: "Likes"),
            ],
            rank: standing.map { "#\($0.rank)" } ?? "#—",
            layout: .page
        )
    }
}

#if DEBUG
extension CountryUnlockSheetViewController {
    /// Internal for tests: the unlock, past the member gate.
    func debugUnlock() async { await unlock() }
}
#endif
