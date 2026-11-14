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

    /// The owner's glyphs, by tab: Explore's is their map (#2413), in all
    /// four states.
    @Test func eachTabWearsTheOwnersGlyph() {
        #expect(TabGlyph.explore.symbol(selected: false, badged: false) == .map)
        #expect(TabGlyph.explore.symbol(selected: true, badged: false) == .mapFill)
        #expect(TabGlyph.explore.symbol(selected: false, badged: true) == .mapBadge)
        #expect(TabGlyph.explore.symbol(selected: true, badged: true) == .mapBadgeFill)
        #expect(TabGlyph.messages.symbol(selected: false, badged: false) == .chats)
    }

    /// The owner's map (#2413) stands as tall as the glyph beside it in the
    /// bar, Messages', outlined and filled. Sized by ink alone (1.36 units a
    /// drawing pixel) it stood 3 pt shorter in the bar, and the guest's gear
    /// outgrew it (`TabFacesTests`). The badged states are left out: the
    /// owner's "clear" placement pushes the badge past the map's box, so
    /// their image is taller by the badge, not the map.
    @Test(arguments: [(false, false), (true, false)])
    func theMapIsAsTallAsTheMessagesGlyph(_ state: (Bool, Bool)) throws {
        let configuration = TabGlyph.symbolConfiguration
        let map = try #require(TabGlyph.explore.symbol(selected: state.0, badged: state.1).image(configuration))
        let chats = try #require(TabGlyph.messages.symbol(selected: state.0, badged: state.1).image(configuration))
        print("[tab-glyph-size] \(state) map \(map.size) chats \(chats.size)")
        #expect(abs(map.size.height - chats.size.height) <= chats.size.height * 0.08,
                "the map is \(map.size.height) tall, Messages' glyph \(chats.size.height)")
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
