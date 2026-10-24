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
    public static func stretched(
        id: String, title: String, image: UIImage? = nil, prominent: Bool = false,
        height: CGFloat = bubbleHeight, action: @escaping () -> Void
    ) -> (item: UIBarButtonItem, label: StretchedBarLabel) {
        let label = StretchedBarLabel(title: title, image: image, ink: prominent ? .white : .label, action: action)
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

    /// Two items' own bubbles: a zero-width space keeps UIKit from joining
    /// adjacent items in one shared platter.
    public static func separator() -> UIBarButtonItem {
        .fixedSpace()
    }

    /// The bar's glass bubbles' height on iOS 27 (iPhone 18 Pro), which a
    /// stretched item matches.
    public static let bubbleHeight: CGFloat = 48
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
        textStyle: UIFont.TextStyle = .body, weight: UIFont.Weight = .semibold, action: @escaping () -> Void
    ) {
        self.action = action
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
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
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
        guard isEnabled else { return }
        action()
    }

    override public func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }

    #if DEBUG
    /// The tap's own path, for tests.
    public func debugTap() { tapped() }
    #endif
}
