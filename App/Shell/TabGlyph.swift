import DesignSystem
import UIKit

extension TabGlyph {
    /// The image the tab wears. Unbadged, a template the bar inks as it
    /// inks every tab; badged, the glyph in the label's ink and its badge in
    /// the accent.
    ///
    /// ⚠️ THE BADGED ONE IS BAKED, per appearance, as the top bar's bell is
    /// (`NotificationsBell.image`): the bar re-renders a symbol image in its
    /// own mode, and the badge layer came out in the system red whatever the
    /// palette said. Baked at the bar's symbol size, or the bitmap would stand
    /// smaller than its unbadged neighbours.
    @MainActor
    func image(selected: Bool, badged: Bool) -> UIImage? {
        let symbol = symbol(selected: selected, badged: badged)
        guard badged else { return symbol.image() }
        let config = NotificationsBell.barSymbolConfiguration
            .applying(UIImage.SymbolConfiguration(paletteColors: [.label, TabGlyph.badgeTint]))
        guard let image = symbol.image(config) else { return nil }
        return NotificationsBell.baked(image)
    }
}

/// A tab coordinator whose bar item wears a `TabGlyph`.
@MainActor
protocol GlyphTab: AnyObject {
    var tab: UITab { get }
    var glyph: TabGlyph { get }
    /// Whether the tab has something unread — its badge variant, no count.
    var hasUnread: Bool { get }
    /// Called when `hasUnread` changes, for the shell to repaint.
    var onUnreadChange: (() -> Void)? { get set }
}

extension ExploreTabCoordinator: GlyphTab {
    var glyph: TabGlyph { .explore }
    /// Explore counts nothing.
    var hasUnread: Bool { false }
    var onUnreadChange: (() -> Void)? {
        get { nil }
        set {}
    }
}
