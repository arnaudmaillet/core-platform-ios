import Testing
@testable import CoreNavigation

/// The one rule every dismissal driver asks (`DismissalArbiter`), as a table.
struct DismissalArbiterTests {
    @Test func theHeroCarriesOnlyAPictureOntoALandingThatTakesOneOnItsAxis() {
        #expect(DismissalArbiter.heroCarries(kind: .hero))
        #expect(DismissalArbiter.heroCarries(kind: .hero, landingAcceptsHero: true, heroClaimsAxis: true))
        #expect(!DismissalArbiter.heroCarries(kind: .card), "a post with no picture flew a hero")
        #expect(!DismissalArbiter.heroCarries(kind: nil), "a screen that is not a destination flew a hero")
        #expect(!DismissalArbiter.heroCarries(kind: .hero, landingAcceptsHero: false),
                "a picture flew onto a row made of words")
        #expect(!DismissalArbiter.heroCarries(kind: .hero, heroClaimsAxis: false),
                "the hero took an axis its host gave to the card close")
    }
}
