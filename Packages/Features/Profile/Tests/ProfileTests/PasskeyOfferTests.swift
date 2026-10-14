import Foundation
import Testing
@testable import Profile

/// When the shell offers a passkey (#840): always after a sign-up, after a
/// sign-in no more than once every 30 days.
@MainActor
struct PasskeyOfferTests {
    @Test func aSignUpAlwaysOffers() {
        let now = Date()
        #expect(PasskeyOffer.isDue(afterSignUp: true, lastOffered: now, now: now))
    }

    @Test func aSignInOffersAtMostMonthly() {
        let now = Date()
        #expect(PasskeyOffer.isDue(afterSignUp: false, lastOffered: nil, now: now))
        #expect(!PasskeyOffer.isDue(afterSignUp: false, lastOffered: now.addingTimeInterval(-86_400 * 29), now: now))
        #expect(PasskeyOffer.isDue(afterSignUp: false, lastOffered: now.addingTimeInterval(-PasskeyOffer.signInInterval), now: now))
    }
}
