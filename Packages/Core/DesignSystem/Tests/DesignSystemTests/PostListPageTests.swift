import Testing
import UIKit
@testable import DesignSystem

/// What the post lists lie on (#2243, the cards style removed in #2290): the
/// plain page, white in the light and black in the dark, and a card's tone on
/// it — in every build, with no flag.
@MainActor
struct PostListPageTests {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// The plain page is the system background: white, unlike the grouped
    /// grey the other screens keep — and the two are one black in the dark.
    @Test func thePostListsLieOnThePlainPage() {
        #expect(Surface.plainPage.resolvedColor(with: light) == UIColor.systemBackground.resolvedColor(with: light))
        #expect(Surface.plainPage.resolvedColor(with: light) != Surface.page.resolvedColor(with: light))
        #expect(Surface.plainPage.resolvedColor(with: dark) == Surface.page.resolvedColor(with: dark))
    }

    /// A card on the plain page stays distinct from it: a white card on white
    /// would have no edge in the light. In the dark it is the card.
    @Test func aCardStaysDistinctOnThePlainPage() {
        #expect(Surface.cardOnPlainPage.resolvedColor(with: light) != Surface.plainPage.resolvedColor(with: light))
        #expect(Surface.cardOnPlainPage.resolvedColor(with: dark) == Surface.card.resolvedColor(with: dark))
    }
}
