import CoreModels
import Testing
@testable import CoreNavigation

/// A bottom toolbar's author pill opens the profile CARD — the viewer's own
/// pill, the profile itself (#1524).
struct ProfileCardRouteTests {
    @Test func someoneElsesPillOpensTheCard() {
        let stub = ProfileIdentityStub(handle: "ava", displayName: "Ava")
        let route = AppRoute.profileCard(ProfileID("ava"), stub: stub)
        #expect(route.profileCardResolution == .presentCard(ProfileID("ava"), stub: stub))
    }

    @Test func onesOwnPillPushesOnesProfile() {
        let stub = ProfileIdentityStub(handle: "me", displayName: "Me", isSelf: true)
        let route = AppRoute.profileCard(ProfileID("me"), stub: stub)
        #expect(route.profileCardResolution == .pushProfile(.profile(ProfileID("me"), stub: stub)))
    }

    @Test func otherRoutesAreNotCards() {
        #expect(AppRoute.profile(ProfileID("ava"), stub: nil).profileCardResolution == nil)
        #expect(AppRoute.profileCard(ProfileID("ava"), stub: nil).profileRouteKey == nil, "a card is not a pushed profile to repeat")
    }
}
