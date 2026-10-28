import UIKit

/// A tab's own glyph (#1191): the owner's custom symbols — an outline, a FILL
/// for the selected tab, and both with a badge layer for unread — in place of
/// the system symbols and of a count.
///
/// ⚠️ NO NUMBER ON THE BAR. A tab with something unread wears its `.badge`
/// variant — the glyph's layer 0 in the bar's ink, its badge (layer 1) in the
/// accent (`badgeTint`) — instead of a `badgeValue`. The app bakes the badged
/// image for the bar (`TabGlyph.barImage` in the shell).
public enum TabGlyph: CaseIterable, Sendable {
    case explore, forYou, messages

    /// The badge's colour: the accent pink.
    @MainActor public static var badgeTint: UIColor { Palette.tint }

    /// The glyph's size in the tab bar: the body style's at the DEFAULT text
    /// size, fixed.
    ///
    /// ⚠️ NOT THE BODY STYLE (#1692). A stock tab item keeps its glyph's size
    /// at every text size — the system shows the Large Content Viewer instead
    /// — but these glyphs are made (and baked) by the app, and sized by the
    /// body text style they grew with Dynamic Type: at XXXL they drew
    /// oversized over their labels.
    public static let symbolConfiguration = AppSymbol.fixed(17)
        .applying(UIImage.SymbolConfiguration(scale: .large))

    /// The symbol for a tab's state.
    public func symbol(selected: Bool, badged: Bool) -> AppSymbol {
        switch (self, selected, badged) {
        case (.explore, false, false): .paperplane
        case (.explore, true, false): .paperplaneFill
        case (.explore, false, true): .paperplaneBadge
        case (.explore, true, true): .paperplaneBadgeFill
        case (.forYou, false, false): .squarePlay
        case (.forYou, true, false): .squarePlayFill
        case (.forYou, false, true): .squarePlayBadge
        case (.forYou, true, true): .squarePlayBadgeFill
        case (.messages, false, false): .chats
        case (.messages, true, false): .chatsFill
        case (.messages, false, true): .chatsBadge
        case (.messages, true, true): .chatsBadgeFill
        }
    }
}
