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
/// - **R3 — UIKit animates, and only what changed (#2331).** An item that
///   stays keeps its INSTANCE (`BarItemStore`): a matched but new item gets
///   the bar's content transition — the blur out and back — even with the
///   same word or glyph. A state change updates its item in place; the group
///   is set (`setToolbarItems(_:animated:)` / `set…BarButtonItems(_:animated:)`,
///   `setOwnTrailingBarItems` for the trailing group) only when its list of
///   items changes, and the staying items are the same instances then too.
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
    /// place, and no tap. A host keeping the item (`BarItemStore`) turns it
    /// in place (`update(stretched:…)`, #2331).
    public static func stretched(
        id: String, title: String, image: UIImage? = nil, prominent: Bool = false,
        busy: Bool = false, height: CGFloat = bubbleHeight, action: @escaping () -> Void
    ) -> (item: UIBarButtonItem, label: StretchedBarLabel) {
        let label = StretchedBarLabel(
            title: title, image: image, ink: prominent ? .white : .label, busy: busy, action: action
        )
        label.stretches = true
        // 999, never required: the bar's first pass pins its item wrapper to
        // the raw intrinsic size.
        let tall = label.heightAnchor.constraint(equalToConstant: height)
        tall.priority = .init(999)
        tall.isActive = true
        let item = UIBarButtonItem(customView: label)
        item.identifier = id
        if prominent { item.style = .prominent }
        return (item, label)
    }

    /// A kept stretched item's new state, IN PLACE (#2331): its word, its
    /// glyph, its loader, and its prominence — the bar's `.prominent` tint on
    /// the item, the ink on the label, as `stretched(…)` makes them. No new
    /// item, so the bar redraws nothing else. A property already right is
    /// not written again.
    public static func update(
        stretched item: UIBarButtonItem, title: String, image: UIImage? = nil, prominent: Bool = false,
        busy: Bool = false
    ) {
        if let label = item.customView as? StretchedBarLabel {
            label.title = title
            label.image = image
            label.ink = prominent ? .white : .label
            label.isBusy = busy
        }
        let style: UIBarButtonItem.Style = prominent ? .prominent : .plain
        if item.style != style { item.style = style }
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

/// THE BAR KEEPS WHAT STAYS (#2331, the owner 2026-11-11) — one group's
/// items (a toolbar, a leading or a trailing run), kept by identifier.
///
/// Filmed on the profile card: Requested turning back into Follow made
/// Message and the QR blur out and back for three frames. Every item was a
/// new instance under its old identifier, and UIKit runs its content
/// transition on a matched NEW item even when its word and glyph are the
/// same. So:
///
/// - **an item that stays keeps its instance**: `item(_:make:update:)` makes
///   it once, then hands back the same one;
/// - **a state change is made in place** by `update`, which runs on every
///   pass (on a new item too, so `make` builds and `update` dresses);
/// - **the group is set only when its list changes** (`apply(…)`): an item
///   comes or goes, or the order changes — and the staying items are still
///   the same instances. A list unchanged is not handed to the bar again,
///   which would restart a transition already running (#756).
///
/// An item that leaves the list is dropped, and comes back new. `variant`
/// re-mints an item that cannot change in place — a title item whose word
/// changes its width, which a bar measures on a NEW item only — under the
/// same identifier, so the bar morphs it (R3).
@MainActor
public final class BarItemStore {
    private struct Kept {
        let item: UIBarButtonItem
        let variant: AnyHashable?
    }

    private var kept: [String: Kept] = [:]
    private var separators: [String: UIBarButtonItem] = [:]

    public init() {}

    /// The item for `id`: `make`'s, made once and identified as `id`, then
    /// the same instance on every pass while it stays in the group (and its
    /// `variant` with it); `update` dresses it for the state on every pass.
    public func item(
        _ id: String, variant: AnyHashable? = nil, make: () -> UIBarButtonItem,
        update: (UIBarButtonItem) -> Void = { _ in }
    ) -> UIBarButtonItem {
        if let entry = kept[id], entry.variant == variant {
            update(entry.item)
            return entry.item
        }
        let item = make()
        item.identifier = id
        kept[id] = Kept(item: item, variant: variant)
        update(item)
        return item
    }

    /// The zero-width space before the item `id` (`BarItems.separator`),
    /// kept as the item is: a fresh one would make an unchanged list look
    /// changed.
    public func separator(before id: String) -> UIBarButtonItem {
        if let kept = separators[id] { return kept }
        let made = BarItems.separator()
        separators[id] = made
        return made
    }

    /// The toolbar's items, set only when they changed.
    /// Returns whether the bar was told.
    @discardableResult
    public func apply(toolbar items: [UIBarButtonItem], to controller: UIViewController, animated: Bool) -> Bool {
        commit(items, over: controller.toolbarItems) { controller.setToolbarItems(items, animated: animated) }
    }

    /// The leading run, set only when it changed.
    @discardableResult
    public func apply(leading items: [UIBarButtonItem], to navigationItem: UINavigationItem, animated: Bool) -> Bool {
        commit(items, over: navigationItem.leftBarButtonItems) {
            navigationItem.setLeftBarButtonItems(items, animated: animated)
        }
    }

    /// The trailing run (`setOwnTrailingBarItems`), set only when it changed.
    @discardableResult
    public func apply(trailing items: [UIBarButtonItem], to controller: UIViewController, animated: Bool) -> Bool {
        commit(items, over: controller.ownTrailingBarItems) {
            controller.setOwnTrailingBarItems(items.isEmpty ? nil : items, animated: animated)
        }
    }

    /// Drops what left `items`, then writes them if the bar holds others.
    private func commit(_ items: [UIBarButtonItem], over shown: [UIBarButtonItem]?, write: () -> Void) -> Bool {
        let present = Set(items.map(ObjectIdentifier.init))
        kept = kept.filter { present.contains(ObjectIdentifier($0.value.item)) }
        separators = separators.filter { present.contains(ObjectIdentifier($0.value)) }
        guard !(shown ?? []).elementsEqual(items, by: ===) else { return false }
        #if DEBUG
        debugWrites += 1
        #endif
        write()
        return true
    }

    #if DEBUG
    /// How many times the bar was handed the group. Tests.
    public private(set) var debugWrites = 0
    /// The identifiers kept now. Tests.
    public var debugKeptIdentifiers: Set<String> { Set(kept.keys) }
    #endif
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
/// ⚠️ ITS STATE CHANGES IN PLACE (#2331, the owner 2026-11-11): a kept item
/// (`BarItemStore`) takes a new word, glyph, ink, loader or stretch here
/// (`BarItems.update(stretched:…)`), and the bar redraws that item alone. A
/// new item under the same identifier — what #1679 did — made every other
/// item of the bar blur out and back with it.
public final class StretchedBarLabel: UIView {
    private let label = UILabel()
    private let glyph = UIImageView()
    private let content = UIStackView()
    private let action: () -> Void
    private var loader: AppLoaderView?

    /// At work (`BarItems.stretched(busy:)`): the loader in the glyph's
    /// place; a tap does nothing.
    public var isBusy: Bool {
        didSet {
            guard isBusy != oldValue else { return }
            applyBusy()
        }
    }

    /// Its word, which VoiceOver reads too (a host saying more sets
    /// `accessibilityLabel` after it).
    public var title: String {
        get { label.text ?? "" }
        set {
            guard newValue != label.text else { return }
            label.text = newValue
            accessibilityLabel = newValue
            invalidateIntrinsicContentSize()
        }
    }

    /// The leading glyph, nil without one.
    public var image: UIImage? {
        get { glyph.image }
        set {
            guard newValue !== glyph.image else { return }
            glyph.image = newValue
            glyph.isHidden = newValue == nil || isBusy
            invalidateIntrinsicContentSize()
        }
    }

    /// The word's and the glyph's colour: white on a `.prominent` bubble.
    public var ink: UIColor {
        get { label.textColor }
        set {
            guard newValue != label.textColor else { return }
            label.textColor = newValue
            glyph.tintColor = newValue
        }
    }

    /// Whether it takes the bar's free width (`BarItems.stretched`) or is as
    /// wide as its content (`BarItems.labeled`): it hugs nothing and asks, at
    /// the lowest priority, for more room than any bar has — or hugs its
    /// content. Turned in place when the slot that stretches moves (the
    /// profile card's Message, #2331).
    public var stretches = false {
        didSet {
            guard stretches != oldValue else { return }
            setContentHuggingPriority(stretches ? .init(1) : .required, for: .horizontal)
            fill.isActive = stretches
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
        }
    }

    private lazy var fill: NSLayoutConstraint = {
        let fill = widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(2)
        return fill
    }()

    /// Off: dimmed, and a tap does nothing — as a disabled control.
    public var isEnabled = true {
        didSet {
            content.alpha = isEnabled ? 1 : Self.disabledAlpha
            applyTraits()
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
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        applyBusy()
    }

    /// The loader in the glyph's place while busy, the glyph back after.
    private func applyBusy() {
        if isBusy, loader == nil {
            let loader = AppLoaderView(size: .medium)
            loader.hidesWhenStopped = false
            loader.isAccessibilityElement = false
            loader.setContentHuggingPriority(.required, for: .horizontal)
            content.insertArrangedSubview(loader, at: 1)
            self.loader = loader
            if window != nil { loader.startAnimating() }
        } else if !isBusy, let loader {
            loader.stopAnimating()
            loader.removeFromSuperview()
            self.loader = nil
        }
        glyph.isHidden = glyph.image == nil || isBusy
        applyTraits()
        invalidateIntrinsicContentSize()
    }

    private func applyTraits() {
        var traits: UIAccessibilityTraits = .button
        if !isEnabled || isBusy { traits.insert(.notEnabled) }
        if isBusy { traits.insert(.updatesFrequently) }
        accessibilityTraits = traits
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
