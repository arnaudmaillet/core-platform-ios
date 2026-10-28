import UIKit

/// THE BAR CONTRACT (#1679, the owner 2026-10-24) — the one way a toolbar or
/// navigation bar item is made. `dev/BAR_CONTRACT.md` states the rules; this
/// is what makes them the easy path:
///
/// - **R1 — icons are native.** `icon(id:…)` is a `UIBarButtonItem(image:)`
///   with an action or a menu: the bar draws its glass, its press, its menu.
///   Never a `UIButton` in a custom view.
/// - **R2 — every item has an identifier**, by function, so UIKit matches
///   items across rebuilds and pushes and animates them itself. Every maker
///   here takes one; there is no way to make an anonymous item through them.
/// - **R3 — UIKit animates.** A change rebuilds the group and sets it with
///   `setToolbarItems(_:animated:)` / `set…BarButtonItems(_:animated:)`
///   (`setOwnTrailingBarItems` for the trailing group, which toasts share).
/// - **R5 — wide items** are `stretched(…)`: a plain view whose bubble the
///   BAR draws (glass, press, `.prominent` tint), stretched to the free width
///   — never a `UIButton` with a glass of its own (`hidesSharedBackground`).
/// - **R6 — complex containers** (a person pill, the wallet badge, a
///   selector strip, a search field) are `container(id:view:)`, and only
///   those: a view a stock item cannot draw.
@MainActor
public enum BarItems {
    /// Identifiers an item keeps on every screen it appears on, so a push
    /// carries it across instead of fading one out and another in.
    public enum SharedID {
        public static let walletBalance = "shell.wallet-balance"
        public static let search = "foryou.search"
        public static let notificationsBell = "shell.notifications-bell"
    }

    /// An icon-only control (R1): a stock image item running `action`.
    /// `label` is what VoiceOver says. The action carries no image — a
    /// `UIAction`'s image is re-applied to its item when it fires, which
    /// would undo a toggled glyph set on the item.
    public static func icon(
        id: String, image: UIImage?, label: String, action: @escaping () -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: image, primaryAction: UIAction { _ in action() })
        item.identifier = id
        item.accessibilityLabel = label
        return item
    }

    /// An icon-only control opening `menu` (R1).
    public static func icon(id: String, image: UIImage?, label: String, menu: UIMenu) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: image, menu: menu)
        item.identifier = id
        item.accessibilityLabel = label
        return item
    }

    /// A titled control — `prominent` for the screen's one primary action.
    /// It is as wide as its word: a title item's `width` is ignored on
    /// iOS 27 (prominent and plain alike, measured 2026-10-24); for the free
    /// width, `stretched(…)`.
    public static func title(
        id: String, title: String, prominent: Bool = false, action: @escaping () -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, primaryAction: UIAction { _ in action() })
        item.identifier = id
        if prominent { item.style = .prominent }
        return item
    }

    /// A control that takes the bar's free width (R5): `StretchedBarLabel` in
    /// an item whose bubble the bar draws — `prominent` tints it as the
    /// bar's own `.prominent` style does. It hugs nothing and asks, at the
    /// lowest priority, for more room than any bar has, so the bar gives it
    /// exactly what the other items leave (#304, #1678).
    ///
    /// An `image` leads the word (a glyph that says what the tap does, e.g.
    /// the notifications' bell).
    ///
    /// `busy` (#1775): the control at work — the kit's loader in the glyph's
    /// place, and no tap — minted as its own item under the same identifier,
    /// so the bar morphs to it and back (R3).
    public static func stretched(
        id: String, title: String, image: UIImage? = nil, prominent: Bool = false,
        busy: Bool = false, height: CGFloat = bubbleHeight, action: @escaping () -> Void
    ) -> (item: UIBarButtonItem, label: StretchedBarLabel) {
        let label = StretchedBarLabel(
            title: title, image: image, ink: prominent ? .white : .label, busy: busy, action: action
        )
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        let fill = label.widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(2)
        // 999, never required: the bar's first pass pins its item wrapper to
        // the raw intrinsic size.
        let tall = label.heightAnchor.constraint(equalToConstant: height)
        tall.priority = .init(999)
        NSLayoutConstraint.activate([fill, tall])
        let item = UIBarButtonItem(customView: label)
        item.identifier = id
        if prominent { item.style = .prominent }
        return (item, label)
    }

    /// A word with its glyph, as wide as they are — what a stock item cannot
    /// draw (given an image and a title it shows only the image): the same
    /// plain view as `stretched`, not stretched, in an item whose bubble the
    /// BAR draws. Never a `UIButton` in a custom view (R1).
    public static func labeled(
        id: String, title: String, image: UIImage?, ink: UIColor = .label,
        textStyle: UIFont.TextStyle = .body, height: CGFloat = bubbleHeight, action: @escaping () -> Void
    ) -> (item: UIBarButtonItem, label: StretchedBarLabel) {
        let label = StretchedBarLabel(
            title: title, image: image, ink: ink, textStyle: textStyle, weight: .regular, action: action
        )
        // As wide as its content and margins (`intrinsicContentSize`): a
        // view with no width of its own is stretched by the bar.
        label.setContentHuggingPriority(.required, for: .horizontal)
        let tall = label.heightAnchor.constraint(equalToConstant: height)
        tall.priority = .init(999)
        tall.isActive = true
        let item = UIBarButtonItem(customView: label)
        item.identifier = id
        return (item, label)
    }

    /// A complex container (R6): a view a stock item cannot draw, under its
    /// identifier. Not for an icon (`icon`) nor a wide word (`stretched`).
    ///
    /// `ownBackground`: the view is a control that draws its own capsule (a
    /// `UISegmentedControl`), so the bar draws none around it — no bubble in
    /// a bubble. Only for such a control: a word or a glyph takes the bar's
    /// bubble (`stretched`, `labeled`, `icon`).
    public static func container(id: String, view: UIView, ownBackground: Bool = false) -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: view)
        item.identifier = id
        if ownBackground { item.hidesSharedBackground = true }
        return item
    }

    /// A control at work (#1775, the owner 2026-10-28): the word of a Save,
    /// a Confirm or a Link becomes the kit's loader under the SAME
    /// identifier, so the bar morphs one into the other (R3) — and back to
    /// the word, a new item again, when the work fails. Not tappable.
    /// `label` is what VoiceOver says ("Saving").
    ///
    /// The loader turns at once, without the loader's grace: the word giving
    /// way is the tap's answer, and an empty bubble for the grace would read
    /// as a glitch.
    public static func busy(id: String, label: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: BarBusyView(label: label))
        item.identifier = id
        return item
    }

    /// Two items' own bubbles: a zero-width space keeps UIKit from joining
    /// adjacent items in one shared platter.
    public static func separator() -> UIBarButtonItem {
        .fixedSpace()
    }

    /// The bar's glass bubbles' height on iOS 27 (iPhone 18 Pro), which a
    /// stretched item matches.
    public static let bubbleHeight: CGFloat = 48
}

/// `BarItems.busy`'s content: the kit's loader, centred in the bubble the
/// bar draws, turning while on screen.
final class BarBusyView: UIView {
    private let loader = AppLoaderView(size: .medium)

    init(label: String) {
        super.init(frame: .zero)
        loader.hidesWhenStopped = false
        loader.isAccessibilityElement = false
        loader.constrain(in: self) { parent in
            loader.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            loader.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        let tall = heightAnchor.constraint(equalToConstant: BarItems.bubbleHeight)
        tall.priority = .init(999)
        tall.isActive = true
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = [.updatesFrequently, .notEnabled]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Square, as an icon item's bubble.
    override var intrinsicContentSize: CGSize {
        CGSize(width: BarItems.bubbleHeight, height: UIView.noIntrinsicMetric)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window != nil ? loader.startAnimating() : loader.stopAnimating()
    }

    /// Takes no taps — `UIBarButtonItem(customView:)` turns interaction back
    /// on, so the view says so itself.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    #if DEBUG
    /// Internal for tests: whether the loader turns.
    var debugIsLoading: Bool { loader.isAnimating }
    #endif
}

/// The stretched toolbar item's content (#1678, `BarItems.stretched`): its
/// word, centred — after its glyph, when it has one — and a tap; nothing
/// drawn behind it, the bar's bubble is its background. Read by VoiceOver as
/// the button it stands for.
///
/// ⚠️ ITS WORD AND GLYPH ARE FIXED (R3): a new word — a price, Mute turned
/// Unmute — is a new item under the same identifier, which the bar animates
/// (`set…Items(animated:)`). Only `isEnabled` changes in place, as a stock
/// item's does.
public final class StretchedBarLabel: UIView {
    private let label = UILabel()
    private let glyph = UIImageView()
    private let content = UIStackView()
    private let action: () -> Void
    /// At work (`BarItems.stretched(busy:)`): the loader in the glyph's
    /// place; a tap does nothing.
    public let isBusy: Bool
    private var loader: AppLoaderView?

    public var title: String { label.text ?? "" }

    /// Off: dimmed, and a tap does nothing — as a disabled control.
    public var isEnabled = true {
        didSet {
            content.alpha = isEnabled ? 1 : Self.disabledAlpha
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    static let disabledAlpha: CGFloat = 0.4

    public init(
        title: String, image: UIImage? = nil, ink: UIColor,
        textStyle: UIFont.TextStyle = .body, weight: UIFont.Weight = .semibold, busy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.action = action
        self.isBusy = busy
        super.init(frame: .zero)
        label.text = title
        label.textColor = ink
        label.font = UIFont.scaledFont(forTextStyle: textStyle, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        glyph.image = image
        glyph.isHidden = image == nil
        glyph.tintColor = ink
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: textStyle, scale: .medium)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Spacing.sm
        content.isUserInteractionEnabled = false
        content.addArrangedSubview(glyph)
        if busy {
            let loader = AppLoaderView(size: .medium)
            loader.hidesWhenStopped = false
            loader.isAccessibilityElement = false
            loader.setContentHuggingPriority(.required, for: .horizontal)
            glyph.isHidden = true
            content.addArrangedSubview(loader)
            self.loader = loader
        }
        content.addArrangedSubview(label)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.md),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = busy ? [.button, .notEnabled, .updatesFrequently] : .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard let loader else { return }
        window != nil ? loader.startAnimating() : loader.stopAnimating()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Its content and the margins either side: what a `labeled` item is
    /// (a `stretched` one asks, at a higher priority than it hugs, for more).
    override public var intrinsicContentSize: CGSize {
        let fitted = content.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: ceil(fitted.width) + 2 * Spacing.md, height: UIView.noIntrinsicMetric)
    }

    override public func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            invalidateIntrinsicContentSize()
        }
    }

    /// The leading glyph, nil without one.
    public var image: UIImage? { glyph.image }

    @objc private func tapped() {
        guard isEnabled, !isBusy else { return }
        action()
    }

    override public func accessibilityActivate() -> Bool {
        guard isEnabled, !isBusy else { return false }
        action()
        return true
    }

    #if DEBUG
    /// The tap's own path, for tests.
    public func debugTap() { tapped() }
    /// Whether the loader turns, for tests.
    public var debugIsLoading: Bool { loader?.isAnimating ?? false }
    #endif
}
