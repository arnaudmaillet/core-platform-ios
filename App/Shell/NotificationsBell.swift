import DesignSystem
import UIKit

/// The notifications bell, as every root header wears it.
///
/// It stood in one header for a long time — the map's — and was built as ONE
/// `UIBarButtonItem` the shell handed to that one coordinator. It leads four
/// headers now (Maps, For You, Messages and the Profile root), and a bar item
/// cannot be shared: an item belongs to one `UINavigationItem` at a time, and
/// handing the same object to a second bar moves it rather than copying it —
/// the first header goes quietly bare.
///
/// So what is shared is the STATE, not the item. This object owns the unread
/// flag and the tap, and mints a FRESH item for every host that asks. Each item
/// it has minted is remembered weakly, so one unread change repaints every bell
/// still on screen and a bell whose screen has gone costs nothing.
///
/// The bell is a plain image item, not a custom view, so the wrapper drift that
/// makes the wallet badge re-mint its item on every width change does not apply:
/// a host keeps the item it was given for its whole life. The badge is a clean
/// image swap — `bell` ↔ `bell.badge`.
@MainActor
final class NotificationsBell {
    /// Every host's bell carries the same identifier: iOS 26 treats two items
    /// with one identifier as ONE item across a transition, so a push from one
    /// root to a screen that also wears a bell morphs it in place instead of
    /// cross-fading two copies.
    static let itemIdentifier = "shell.notifications-bell"

    /// What a tap on ANY bell does. The shell decides where Notifications goes;
    /// the bell only says it was pressed.
    private let onTap: () -> Void
    /// The last unread state, so a bell minted later starts correct.
    private(set) var isUnread = false
    /// Every bell handed out and still alive, for the repaint.
    private let items = NSHashTable<UIBarButtonItem>.weakObjects()

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    /// A new bell for one header, already showing the current unread state.
    ///
    /// `sharesBackground = false`: iOS 26 draws ONE glass platter behind
    /// adjacent bar items, and the bell's neighbour in a leading group (the
    /// profile's source filter) is a different control, not a second half of
    /// this one — each stands in its own bubble.
    func makeItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: Self.image(unread: isUnread),
            primaryAction: UIAction { [weak self] _ in self?.onTap() }
        )
        // `.label` so it renders dark in its glass bubble, not system blue.
        item.tintColor = .label
        item.accessibilityLabel = "Notifications"
        item.identifier = Self.itemIdentifier
        item.sharesBackground = false
        items.add(item)
        return item
    }

    /// Repaints every live bell. Idempotent: an unchanged state touches nothing.
    func setUnread(_ unread: Bool) {
        guard unread != isUnread else { return }
        isUnread = unread
        repaint()
    }

    /// Sets every live bell's image again — the badged one is baked per
    /// appearance and accent theme, so a switch of either asks for it anew.
    func repaint() {
        let image = Self.image(unread: isUnread)
        for item in items.allObjects { item.image = image }
    }

    /// The size a navigation bar draws a symbol item at.
    static let barSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)

    /// The bell glyph for an unread state. When unread, a palette `bell.badge`
    /// (badge in the accent pink, as the tab bar's badges — #1197 — bell in
    /// `.label`); otherwise a plain
    /// template `bell` that the tint draws dark.
    ///
    /// ⚠️ BAKED, per appearance (#1178). A bar item re-renders a SYMBOL image
    /// with its own configuration: the palette was dropped and the badge came
    /// out in the system red whatever `counter` said. So the badged bell is
    /// drawn into bitmaps — one per appearance, registered in an image asset
    /// so it still follows light and dark.
    static func image(unread: Bool) -> UIImage? {
        guard unread else { return UIImage(systemName: "bell") }
        // `bell.badge`'s first layer is the BADGE, its second the bell.
        // ⚠️ AT THE BAR'S SIZE (#1191): a bitmap is not re-sized as a symbol
        // is, so baked at the symbol's default size the badged bell stood
        // much smaller than the plain one. The bar draws its symbols at the
        // body style's large scale.
        let config = barSymbolConfiguration
            .applying(UIImage.SymbolConfiguration(paletteColors: [TabGlyph.badgeTint, .label]))
        guard let symbol = UIImage(systemName: "bell.badge", withConfiguration: config) else { return nil }
        return baked(symbol)
    }

    /// `symbol` drawn into bitmaps, one per appearance, registered in an image
    /// asset so it follows light and dark — for a bar that would re-render a
    /// symbol in its own mode (the bell, the tab bar's badged glyphs, #1191).
    static func baked(_ symbol: UIImage) -> UIImage {
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let format = UIGraphicsImageRendererFormat(for: traits)
            // Drawn in the applied accent theme (#1379): the badge is the
            // accent, and a bitmap re-resolves nothing — a theme change bakes
            // it anew (`MainTabCoordinator`).
            let drawing = traits.modifyingTraits { $0.accentTheme = AccentThemePreference.applied }
            let baked = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
                drawing.performAsCurrent { symbol.draw(at: .zero) }
            }
            asset.register(
                baked.withBaselineOffset(fromBottom: symbol.baselineOffsetFromBottom ?? 0),
                with: UITraitCollection(traitsFrom: [traits, UITraitCollection(displayScale: format.scale)])
            )
        }
        return asset.image(with: UITraitCollection.current).withRenderingMode(.alwaysOriginal)
    }
}
