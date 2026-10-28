import DesignSystem
import UIKit

extension TabGlyph {
    /// The image the tab wears. Unbadged, a template the bar inks as it
    /// inks every tab; badged, the glyph in the label's ink and its badge in
    /// the accent.
    ///
    /// ⚠️ THE BADGED ONE IS BAKED, for `traits` — the window's, the app's own
    /// appearance included (#1501) — as the top bar's bell is
    /// (`NotificationsBell.image`): the bar re-renders a symbol image in its
    /// own mode, and the badge layer came out in the system red whatever the
    /// palette said. Baked at the bar's symbol size, or the bitmap would stand
    /// smaller than its unbadged neighbours.
    ///
    /// ⚠️ ONE BOX FOR BOTH STATES (the owner, 2026-10-15): the badge variant
    /// is a larger symbol — its badge stands out at the top-right — and the
    /// bar fits each image into the same box, so the glyph shrank as its
    /// badge came and grew as it went. The unbadged image is the PLAIN glyph
    /// drawn into the badge variant's box, on the same baseline and leading
    /// edge (measured: the two coincide there), as a template the bar inks.
    ///
    /// ⚠️ NOT the badge symbol with its badge clear: its glyph is NOTCHED
    /// around the badge, and the paper plane showed its tip cut off with no
    /// badge in sight (the owner, on a device).
    @MainActor
    func image(selected: Bool, badged: Bool, traits: UITraitCollection = .current) -> UIImage? {
        let badge = symbol(selected: selected, badged: true)
        if badged {
            let config = TabGlyph.symbolConfiguration
                .applying(UIImage.SymbolConfiguration(paletteColors: [.label, TabGlyph.badgeTint]))
            guard let image = badge.image(config) else { return nil }
            return NotificationsBell.baked(image, traits: traits)
        }
        let config = TabGlyph.symbolConfiguration
        guard let box = badge.image(config),
              let glyph = symbol(selected: selected, badged: false).image(config) else { return nil }
        return Self.template(glyph, inBoxOf: box)
    }

    /// What VoiceOver hears while the tab has something unread (#1196): the
    /// bar draws no count since #1191, and the badge is an image — without
    /// this an unread tab sounded the same as a read one. Nil: never unread.
    var unreadAccessibilityValue: String? {
        switch self {
        case .explore: nil
        case .forYou: "New posts"
        case .messages: "New messages"
        }
    }

    /// `glyph` drawn into `box`'s size, its leading edge and baseline on the
    /// box's — the bottom-left corner — as a template.
    @MainActor
    static func template(_ glyph: UIImage, inBoxOf box: UIImage) -> UIImage {
        let image = UIGraphicsImageRenderer(size: box.size).image { _ in
            glyph.draw(at: CGPoint(x: 0, y: box.size.height - glyph.size.height))
        }
        return image
            .withBaselineOffset(fromBottom: box.baselineOffsetFromBottom ?? 0)
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
