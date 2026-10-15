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
    ///
    /// ⚠️ ONE BOX FOR BOTH STATES (the owner, 2026-10-15): the badge variant
    /// is a larger symbol — its badge stands out at the top-right — and the
    /// bar fits each image into the same box, so the glyph shrank as its
    /// badge came and grew as it went. The unbadged image is the SAME badge
    /// symbol with its badge layer clear, drawn at the same size and handed
    /// back as a template the bar inks: the glyph stays put, only the badge
    /// comes and goes.
    @MainActor
    func image(selected: Bool, badged: Bool) -> UIImage? {
        let symbol = symbol(selected: selected, badged: true)
        let badge: UIColor = badged ? TabGlyph.badgeTint : .clear
        let config = NotificationsBell.barSymbolConfiguration
            .applying(UIImage.SymbolConfiguration(paletteColors: [.label, badge]))
        guard let image = symbol.image(config) else { return nil }
        guard badged else { return Self.template(image) }
        return NotificationsBell.baked(image)
    }

    /// `symbol` drawn into a bitmap of its own size, as a template: the bar
    /// inks every opaque pixel — the glyph — and the clear badge stays clear.
    @MainActor
    static func template(_ symbol: UIImage) -> UIImage {
        let image = UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) }
        return image
            .withBaselineOffset(fromBottom: symbol.baselineOffsetFromBottom ?? 0)
            .withRenderingMode(.alwaysTemplate)
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
