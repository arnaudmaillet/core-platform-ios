import DesignSystem
import UIKit
import CoreModels
import CoreNavigation

/// The offer a locked country makes when it is tapped on the map:
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │               🇪🇸                     │
///  │             Spain                    │
///  │             Europe                   │
///  │    #4          ♥ 12.4K       86      │
///  │   Rank          Likes       Posts    │
///  │  Unlock Spain to see its posts on    │
///  │  your map.                           │
///  │ [ ◆ Unlock · 50 ]                    │
///  │         You have 100 gems            │
///  └──────────────────────────────────────┘
/// ```
///
/// One detent, the content's own height; the map stays visible and the
/// country stays lifted above the sheet. Gems only — points (likes) never buy
/// a country. Short of gems, the button is disabled and the line under it
/// says how many are missing.
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
    private let unlockButton = UIButton(configuration: .prominentGlass())
    private let balanceLabel = UILabel()
    private var closeFlight = OfferCloseFlight()
    private static let detent = UISheetPresentationController.Detent.Identifier("country.unlock")
    /// The sheet's height above the bottom safe area — measured when the
    /// view loads; the map frames the country above it.
    private(set) var contentHeight: CGFloat = 380

    init(country: CountryAtlas.Country, access: any CountryAccess) {
        self.country = country
        self.access = access
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.detent) { [weak self] context in
                min(self?.contentHeight ?? 380, context.maximumDetentValue)
            }]
            sheet.prefersGrabberVisible = true
            // The map behind stays live: the lifted country is what is sold.
            sheet.largestUndimmedDetentIdentifier = Self.detent
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own glass is the surface.
        view.backgroundColor = .clear
        let standing = access.standing(of: country.code)

        let flag = UILabel()
        flag.text = country.flag
        flag.font = .systemFont(ofSize: 56) // a picture, not text (#482)
        let name = UILabel()
        name.text = country.name
        name.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize, weight: .bold)
        name.adjustsFontForContentSizeCategory = true
        let continent = UILabel()
        continent.text = country.continent
        continent.font = .preferredFont(forTextStyle: .subheadline)
        continent.textColor = .secondaryLabel

        let metrics = UIStackView(arrangedSubviews: [
            Self.metric(value: standing.map { "#\($0.rank)" } ?? "—", caption: "Rank"),
            Self.metric(value: standing.map { CountryStanding.compact($0.likes) } ?? "—",
                        caption: "Likes", heart: true),
            Self.metric(value: standing.map { "\($0.posts)" } ?? "—", caption: "Posts"),
        ])
        metrics.distribution = .fillEqually

        let pitch = UILabel()
        pitch.text = "Unlock \(country.name) to see its posts on your map."
        pitch.font = .preferredFont(forTextStyle: .subheadline)
        pitch.textColor = .secondaryLabel
        pitch.textAlignment = .center
        pitch.numberOfLines = 0

        let price = standing?.price ?? CountryStanding.price(forRank: .max)
        var configuration = unlockButton.configuration
        configuration?.image = UIImage(systemName: "diamond.fill")
        configuration?.imagePadding = Spacing.sm
        configuration?.title = "Unlock · \(price)"
        configuration?.cornerStyle = .capsule
        unlockButton.configuration = configuration
        unlockButton.tintColor = .systemBlue
        unlockButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            MemberGates.perform(.unlockCountry, from: self) { [weak self] in self?.unlock() }
        }, for: .primaryActionTriggered)
        unlockButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        balanceLabel.font = .preferredFont(forTextStyle: .footnote)
        balanceLabel.textColor = .secondaryLabel
        balanceLabel.textAlignment = .center
        refreshBalance(price: price)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        for view in [flag, name, continent] {
            (view as? UILabel)?.textAlignment = .center
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(Spacing.xl, after: continent)
        stack.addArrangedSubview(metrics)
        stack.setCustomSpacing(Spacing.lg, after: metrics)
        stack.addArrangedSubview(pitch)
        stack.setCustomSpacing(Spacing.lg, after: pitch)
        stack.addArrangedSubview(unlockButton)
        stack.setCustomSpacing(Spacing.sm, after: unlockButton)
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
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
        if isBeingDismissed { onDismissed?() }
    }

    /// The detent is the content: measured once, before the sheet rises.
    ///
    /// ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
    /// adds it back (the wallet sheet's rule).
    private func measure() {
        let width = presentingViewController?.view.window?.bounds.width ?? UIScreen.main.bounds.width
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width - 2 * Spacing.lg, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        contentHeight = (Spacing.xl + size.height + Spacing.lg).rounded()
    }

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

    private static func metric(value: String, caption: String, heart: Bool = false) -> UIView {
        let valueLabel = UILabel()
        valueLabel.font = .scaledMonospacedDigitSystemFont(
            ofSize: 20, weight: .bold, relativeTo: .title3, maximumPointSize: 28
        )
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .center
        valueLabel.text = value
        var valueView: UIView = valueLabel
        if heart {
            // ⚠️ AN IMAGE VIEW, NOT A TEXT ATTACHMENT: the sheet's glass draws
            // its labels vibrant, attachments included, and the red heart
            // came out black.
            let icon = UIImageView(image: UIImage(systemName: "heart.fill")?
                .applyingSymbolConfiguration(.init(pointSize: 15, weight: .bold)))
            icon.tintColor = .systemRed
            icon.contentMode = .center
            let row = UIStackView(arrangedSubviews: [icon, valueLabel])
            row.spacing = 4
            row.alignment = .center
            let centred = UIStackView(arrangedSubviews: [row])
            centred.axis = .vertical
            centred.alignment = .center
            valueView = centred
        }
        let captionLabel = UILabel()
        captionLabel.text = caption
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [valueView, captionLabel])
        column.axis = .vertical
        column.spacing = 2
        return column
    }
}
