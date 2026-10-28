import Testing
import UIKit
@testable import DesignSystem

/// The tab bar's own glyphs (#1191): a fill for the selected tab, a badge
/// variant for unread, every one in the catalog.
@MainActor
struct TabGlyphTests {
    @Test(arguments: TabGlyph.allCases)
    func everyStateHasItsGlyph(_ glyph: TabGlyph) {
        let states = [(false, false), (true, false), (false, true), (true, true)]
        let symbols = states.map { glyph.symbol(selected: $0.0, badged: $0.1) }
        #expect(Set(symbols.map(\.rawValue)).count == 4, "a state shares another's glyph")
        for symbol in symbols {
            #expect(symbol.image() != nil, "\(symbol.rawValue) is not in the catalog")
        }
        #expect(glyph.symbol(selected: true, badged: false).rawValue.hasSuffix(".fill"), "the selected tab is filled")
        #expect(glyph.symbol(selected: false, badged: true).rawValue.hasSuffix(".badge"))
        #expect(glyph.symbol(selected: true, badged: true).rawValue.hasSuffix(".badge.fill"))
    }

    /// The badge is the accent pink, not the system red (#1191).
    @Test func theBadgeIsThePink() {
        #expect(TabGlyph.badgeTint == Palette.tint)
    }

    /// The owner's glyphs, by tab.
    @Test func eachTabWearsTheOwnersGlyph() {
        #expect(TabGlyph.explore.symbol(selected: false, badged: false) == .paperplane)
        #expect(TabGlyph.forYou.symbol(selected: false, badged: false) == .squarePlay)
        #expect(TabGlyph.messages.symbol(selected: false, badged: false) == .chats)
    }

    /// ⚠️ #1692: a tab's glyph keeps the system's size at every text size, as
    /// a stock tab item does — at XXXL it drew oversized over its label.
    @Test(arguments: TabGlyph.allCases)
    func aGlyphKeepsItsSizeAtEveryTextSize(_ glyph: TabGlyph) throws {
        func size(_ category: UIContentSizeCategory, selected: Bool) throws -> CGSize {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let configuration = TabGlyph.symbolConfiguration.withTraitCollection(traits)
            return try #require(glyph.symbol(selected: selected, badged: false).image(configuration)).size
        }
        for selected in [false, true] {
            let standard = try size(.large, selected: selected)
            #expect(try size(.accessibilityExtraExtraExtraLarge, selected: selected) == standard,
                    "the glyph grew with the text size")
            #expect(try size(.extraSmall, selected: selected) == standard)
        }
    }
}
