import DesignSystem
import UIKit
import CoreModels
import CoreNavigation

/// The offer a locked country makes when it is tapped on the map:
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │ ╭───╮ Spain  Europe                  │
///  │ ╰─#4╯ ♥ 12K  86 posts                │
///  │  Unlock Spain to see its posts on    │
///  │  your map.                           │
///  │ [ ◆ Unlock · 50 ]                    │
///  │         You have 100 gems            │
///  └──────────────────────────────────────┘
/// ```
///
/// The header is two lines beside the country's ROUND flag (the map's own
/// picture, `FlagPalette`), which stands as tall as both: the name and its
/// continent on the first, the likes and posts on the second. The RANK is not
/// a counter: it rides the flag as a bubble on its bottom-trailing edge.
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

        let header = Self.header(country: country, standing: standing)

        let pitch = UILabel()
        pitch.text = "Unlock \(country.name) to see its posts on your map."
        pitch.font = .appFont(forTextStyle: .subheadline)
        pitch.textColor = .secondaryLabel
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

        balanceLabel.font = .appFont(forTextStyle: .footnote)
        balanceLabel.textColor = .secondaryLabel
        balanceLabel.textAlignment = .center
        refreshBalance(price: price)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.xs
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(Spacing.lg, after: header)
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

    // MARK: - Header

    /// The flag, standing as tall as the two lines beside it — the name and
    /// its continent, then the counters — with the rank in a bubble over its
    /// bottom-trailing edge.
    static func header(country: CountryAtlas.Country, standing: CountryStanding?) -> UIView {
        // The round flag the map wears (an emoji drawn and trimmed for a code
        // the catalog lacks — never an atlas country).
        let flag = UIImageView(image: FlagPalette.image(for: country.code))
        flag.contentMode = .scaleAspectFit
        flag.accessibilityIdentifier = "country.unlock.flag"
        let rank = RankBubble(text: standing.map { "#\($0.rank)" } ?? "#—")
        rank.accessibilityIdentifier = "country.unlock.rank"
        let flagBox = UIView()
        for view in [flag, rank] {
            view.translatesAutoresizingMaskIntoConstraints = false
            flagBox.addSubview(view)
        }

        let name = UILabel()
        name.text = country.name
        name.font = UIFont.scaledFont(forTextStyle: .title2, weight: .bold)
        name.adjustsFontForContentSizeCategory = true
        // The longest names ("South Georgia and the South Sandwich Islands")
        // shrink, then truncate — but only once the continent has given way:
        // the name is what the sheet is about.
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.75
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let continent = UILabel()
        continent.text = country.continent
        continent.font = .appFont(forTextStyle: .body)
        continent.adjustsFontForContentSizeCategory = true
        continent.textColor = .secondaryLabel
        continent.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        continent.setContentHuggingPriority(.required, for: .horizontal)
        let title = UIStackView(arrangedSubviews: [name, continent, Self.spacer()])
        title.alignment = .firstBaseline
        title.spacing = Spacing.sm

        let counters = UIStackView(arrangedSubviews: [
            Self.counter(value: standing.map { CountryStanding.compact($0.likes) } ?? "—",
                         caption: nil, heart: true),
            Self.counter(value: standing.map { "\($0.posts)" } ?? "—",
                         caption: standing?.posts == 1 ? "post" : "posts"),
            Self.spacer(),
        ])
        counters.alignment = .center
        counters.spacing = Spacing.lg

        let lines = UIStackView(arrangedSubviews: [title, counters])
        lines.axis = .vertical
        lines.spacing = 2

        let row = UIStackView(arrangedSubviews: [flagBox, lines])
        row.alignment = .center
        row.spacing = Spacing.lg
        NSLayoutConstraint.activate([
            flag.topAnchor.constraint(equalTo: flagBox.topAnchor),
            flag.leadingAnchor.constraint(equalTo: flagBox.leadingAnchor),
            flag.trailingAnchor.constraint(equalTo: flagBox.trailingAnchor),
            flag.bottomAnchor.constraint(equalTo: flagBox.bottomAnchor),
            // "On two lines": the disc is exactly as tall as the text column.
            flag.heightAnchor.constraint(equalTo: lines.heightAnchor),
            flag.widthAnchor.constraint(equalTo: flag.heightAnchor),
            // The bubble straddles the disc's rim at its bottom-trailing
            // corner, as a badge does: it may overhang into the gap beside it,
            // never into the name.
            rank.bottomAnchor.constraint(equalTo: flag.bottomAnchor, constant: 2),
            rank.trailingAnchor.constraint(lessThanOrEqualTo: flag.trailingAnchor, constant: Spacing.lg - 4),
        ])
        // A wide rank ("#126") slides LEFT over the disc rather than being
        // truncated against the cap above.
        let anchor = rank.centerXAnchor.constraint(equalTo: flag.trailingAnchor, constant: -8)
        anchor.priority = .defaultHigh
        anchor.isActive = true
        return row
    }

    /// One counter: its figure, and the word that says what it counts.
    private static func counter(value: String, caption: String?, heart: Bool = false) -> UIView {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        let figure = NSMutableAttributedString(string: value, attributes: [
            .font: UIFont.scaledMonospacedDigitSystemFont(
                ofSize: 20, weight: .bold, relativeTo: .title3, maximumPointSize: 28
            ),
            .foregroundColor: UIColor.label,
        ])
        if let caption {
            figure.append(NSAttributedString(string: " \(caption)", attributes: [
                .font: UIFont.appFont(forTextStyle: .body),
                .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        label.attributedText = figure
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        guard heart else { return label }
        // ⚠️ AN IMAGE VIEW, NOT A TEXT ATTACHMENT: the sheet's glass draws
        // its labels vibrant, attachments included, and the red heart
        // came out black.
        // Its red baked in (`.alwaysOriginal`), as the shop row's: a tinted
        // template came out pink over the dark glass.
        let icon = UIImageView(image: UIImage(systemName: "heart.fill")?
            .applyingSymbolConfiguration(.init(pointSize: 16, weight: .bold))?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 4
        row.alignment = .center
        return row
    }

    /// Takes the line's slack, so what it sits beside hugs its own edge.
    private static func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
}

/// The country's rank, worn over its flag: "#4", white on a near-black
/// capsule, ringed in the page's ground so it lifts off the disc.
///
/// ⚠️ FIXED INK, NOT `.label` INVERTED. The sheet's glass draws its labels
/// vibrant: in dark mode a black-on-white bubble came out white on white —
/// the figure vanished. White on a dark capsule survives both appearances.
final class RankBubble: UIView {
    let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.1, alpha: 1)
        layer.borderColor = UIColor.systemBackground.cgColor
        layer.borderWidth = 2
        layer.cornerCurve = .continuous
        label.text = text
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 12, weight: .heavy, relativeTo: .caption1, maximumPointSize: 18
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Rank \(text.dropFirst())"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // A CGColor does not follow the appearance on its own.
        layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }
}
