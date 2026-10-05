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
/// The header is the profile's identity row (`ProfileHeaderView`): the
/// country's ROUND flag where the avatar stands — the map's own artwork,
/// drawn large (`FlagPalette.largeRoundFlag`) — and beside it the name over
/// the counters, centred on the flag. The continent follows the name on
/// its line, or takes the next one when the two do not fit
/// (`CountryTitleLabel`); the counters are the profile's columns, the figure
/// over its word ("Likes", "Posts"). The RANK is not a counter: it rides the
/// flag as a bubble on its bottom-trailing edge.
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

    /// The flag's side: the profile avatar's, so the two identity rows of
    /// the app read as one.
    static let flagSide: CGFloat = 96
    /// The flag's Dynamic-Type ceiling — the avatar's.
    static let flagMaxSide: CGFloat = 110
    /// The equal parts the counters' row is cut into; the counters fill the
    /// first ones, in order.
    static let counterParts = 4
    /// The air between the title and the counters: on two lines, the block
    /// is then as tall as the flag.
    static let titleToCounters: CGFloat = Spacing.sm

    /// The profile's identity row (`ProfileHeaderView`): the flag where the
    /// avatar stands, with the rank in a bubble over its bottom-trailing edge,
    /// and beside it the title over the counters, centred on the flag.
    static func header(country: CountryAtlas.Country, standing: CountryStanding?) -> UIView {
        // The round flag the map wears, at its LARGE size (an emoji drawn and
        // trimmed for a code the catalog lacks — never an atlas country).
        let flag = UIImageView(image: FlagPalette.largeRoundFlag(for: country.code)
            ?? FlagPalette.image(for: country.code))
        flag.contentMode = .scaleAspectFit
        flag.accessibilityIdentifier = "country.unlock.flag"
        // No intrinsic size: the bitmap's would be an unopposed preference
        // for the flag's side (the profile avatar's trap).
        flag.setContentHuggingPriority(.init(1), for: .vertical)
        flag.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let rank = RankBubble(text: standing.map { "#\($0.rank)" } ?? "#—")
        rank.accessibilityIdentifier = "country.unlock.rank"
        let flagBox = UIView()
        for view in [flag, rank] {
            view.translatesAutoresizingMaskIntoConstraints = false
            flagBox.addSubview(view)
        }

        let title = CountryTitleLabel(name: country.name, continent: country.continent)

        // FOUR EQUAL PARTS across the column, each counter centred in its
        // own: Likes in the first, Posts in the second, the last two kept
        // free — so the columns stand where four would, whatever their
        // figures' widths.
        let stats = [
            CountryStatView(value: standing.map { CountryStanding.compact($0.likes) } ?? "—", caption: "Likes"),
            CountryStatView(value: standing.map { "\($0.posts)" } ?? "—",
                            caption: standing?.posts == 1 ? "Post" : "Posts"),
        ]
        let parts = (0..<Self.counterParts).map { index in
            let part = UIView()
            part.accessibilityIdentifier = "country.unlock.counterPart"
            guard index < stats.count else { return part }
            let stat = stats[index]
            stat.translatesAutoresizingMaskIntoConstraints = false
            part.addSubview(stat)
            NSLayoutConstraint.activate([
                stat.topAnchor.constraint(equalTo: part.topAnchor),
                stat.bottomAnchor.constraint(equalTo: part.bottomAnchor),
                stat.centerXAnchor.constraint(equalTo: part.centerXAnchor),
                stat.leadingAnchor.constraint(greaterThanOrEqualTo: part.leadingAnchor),
            ])
            return part
        }
        let counters = UIStackView(arrangedSubviews: parts)
        counters.alignment = .fill
        counters.distribution = .fillEqually

        // The title over the counters at a fixed gap, the block CENTRED on
        // the flag. No case for the title's length, and two follow from the
        // centring alone: the title's middle stands at the same height
        // whether it takes one line or two (a line less takes half a line off
        // each side), and the counters come up by half a line when it takes
        // one. On two lines the block is the flag's height — the profile's
        // name level with the disc's top, counters level with its foot.
        let column = UIStackView(arrangedSubviews: [title, counters])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Self.titleToCounters

        let row = UIStackView(arrangedSubviews: [flagBox, column])
        row.alignment = .center
        row.spacing = Spacing.md
        // The side is high and the flag at least the column's height at 999:
        // a Dynamic-Type title that outgrows the disc grows the flag with it
        // up to its cap, and past the cap the column outgrows it rather than
        // clipping a label — the profile's avatar rule.
        let side = flag.heightAnchor.constraint(equalToConstant: flagSide)
        side.priority = .defaultHigh
        let spans = flag.heightAnchor.constraint(greaterThanOrEqualTo: column.heightAnchor)
        spans.priority = .init(999)
        NSLayoutConstraint.activate([
            flag.topAnchor.constraint(equalTo: flagBox.topAnchor),
            flag.leadingAnchor.constraint(equalTo: flagBox.leadingAnchor),
            flag.trailingAnchor.constraint(equalTo: flagBox.trailingAnchor),
            flag.bottomAnchor.constraint(equalTo: flagBox.bottomAnchor),
            flag.widthAnchor.constraint(equalTo: flag.heightAnchor),
            side,
            flag.heightAnchor.constraint(lessThanOrEqualToConstant: flagMaxSide),
            spans,
            // The bubble straddles the disc's rim at its bottom-trailing
            // corner, as a badge does: it may overhang into the gap beside it,
            // never into the column.
            rank.bottomAnchor.constraint(equalTo: flag.bottomAnchor, constant: -2),
            rank.trailingAnchor.constraint(lessThanOrEqualTo: flag.trailingAnchor, constant: Spacing.md - 4),
        ])
        // A wide rank ("#126") slides LEFT over the disc rather than being
        // truncated against the cap above.
        let anchor = rank.centerXAnchor.constraint(equalTo: flag.trailingAnchor, constant: -14)
        anchor.priority = .defaultHigh
        anchor.isActive = true
        return row
    }
}

/// The country's name and its continent: on ONE line when the two fit the
/// width, the continent after the name, a step back; the continent on the
/// NEXT line when they do not. The name is always ONE line, truncated when
/// even alone it is too wide ("South Georgia and the South…"); so is the
/// continent.
///
/// One label, so the two lines share the text layout: the text is composed
/// for the width UIKit asks about (`textRect`) — a space between the two when
/// they fit, a line break when they do not, each line cut to the width by
/// hand (a label truncates only its LAST line).
final class CountryTitleLabel: UILabel {
    let name: String
    let continent: String

    init(name: String, continent: String) {
        self.name = name
        self.continent = continent
        super.init(frame: .zero)
        // Never more than the name's line and the continent's: each is cut
        // to the width before it gets here.
        numberOfLines = 2
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.required, for: .vertical)
        compose(fits: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the continent stands on the name's line at the width laid out.
    private(set) var continentFollowsName = true

    /// The profile's name: title3 semibold.
    private var nameFont: UIFont { .scaledFont(forTextStyle: .title3, weight: .semibold) }
    /// The profile's @handle: subheadline, secondary.
    private var continentFont: UIFont { .appFont(forTextStyle: .subheadline) }

    private func composed(fits: Bool, width: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let name = fits ? self.name : Self.cut(self.name, font: nameFont, to: width)
        let continent = fits ? self.continent : Self.cut(self.continent, font: continentFont, to: width)
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: nameFont, .foregroundColor: UIColor.label,
        ])
        text.append(NSAttributedString(string: fits ? "  " : "\n", attributes: [.font: continentFont]))
        text.append(NSAttributedString(string: continent, attributes: [
            .font: continentFont, .foregroundColor: UIColor.secondaryLabel,
        ]))
        return text
    }

    /// `text` as it fits `width` on one line in `font`: whole, or its longest
    /// prefix that fits with "…".
    static func cut(_ text: String, font: UIFont, to width: CGFloat) -> String {
        let measure = { (candidate: String) in
            (candidate as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        guard measure(text) > width else { return text }
        let characters = Array(text)
        var (low, high) = (0, characters.count)
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…"
            if measure(candidate) <= width { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The width the text was last cut for, when it does not fit one line.
    private var composedWidth: CGFloat = .greatestFiniteMagnitude

    private func compose(fits: Bool, width: CGFloat = .greatestFiniteMagnitude) {
        continentFollowsName = fits
        composedWidth = width
        attributedText = composed(fits: fits, width: width)
        accessibilityLabel = "\(name), \(continent)"
    }

    /// Whether the name and the continent fit one line `width` wide.
    func fitsOneLine(_ width: CGFloat) -> Bool {
        let line = composed(fits: true).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        return line.width.rounded(.up) <= width
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        // Asked for a width (a layout pass, a fitting size): compose for it.
        // Stable: the same width always asks for the same text.
        if bounds.width > 0, bounds.width < CGFloat.greatestFiniteMagnitude / 2 {
            let fits = fitsOneLine(bounds.width)
            if fits != continentFollowsName || (!fits && bounds.width != composedWidth) {
                compose(fits: fits, width: fits ? .greatestFiniteMagnitude : bounds.width)
            }
        }
        return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Attributed fonts do not follow Dynamic Type on their own.
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            compose(fits: continentFollowsName, width: composedWidth)
        }
    }
}

/// One counter as the profile draws its own (`ProfileStatView`): the figure
/// over the word that says what it counts, centred on each other, the column
/// as wide as the wider of the two.
final class CountryStatView: UIView {
    let valueLabel = UILabel()
    let captionLabel = UILabel()

    init(value: String, caption: String) {
        super.init(frame: .zero)
        // The profile's type, capped (#482).
        valueLabel.font = .scaledSystemFont(ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center
        valueLabel.text = value
        captionLabel.font = .scaledSystemFont(ofSize: 12, relativeTo: .caption1, maximumPointSize: 16)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        captionLabel.text = caption
        for label in [valueLabel, captionLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = caption
        accessibilityValue = value
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
            ofSize: 13, weight: .heavy, relativeTo: .caption1, maximumPointSize: 19
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
