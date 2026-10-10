import CoreModels
import Testing
@testable import CoreNavigation

/// A second route to the profile just pushed pushes nothing (#778).
///
/// Profiles are pushed at once on their loading state, so a double tap on an
/// author reaches the router twice within the slide. The router's rule is
/// extracted here because the app target has no tests.
struct RepeatPushFilterTests {
    /// Stand-ins for the screens on a navigation stack.
    private final class Screen {}

    @Test func theSameProfileWhileItIsStillTheTopScreenIsARepeat() {
        var filter = RepeatPushFilter<String>()
        let profile = Screen()
        #expect(filter.willPush("ana", screen: profile, isTransitioning: false) == .now)
        filter.stoppedWaiting(profile)
        #expect(filter.isRepeat("ana", topScreen: profile))
    }

    @Test func theSameProfileAfterItWasPoppedPushesAgain() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        let profile = Screen()
        filter.willPush("ana", screen: profile, isTransitioning: false)
        filter.stoppedWaiting(profile)
        #expect(!filter.isRepeat("ana", topScreen: origin))
    }

    @Test func theSameProfileUnderAnotherScreenPushesAgain() {
        var filter = RepeatPushFilter<String>()
        let profile = Screen()
        let thread = Screen()
        filter.willPush("ana", screen: profile, isTransitioning: false)
        filter.stoppedWaiting(profile)
        // Ana's profile → a thread on top: her name in the thread is a new tap.
        #expect(!filter.isRepeat("ana", topScreen: thread))
    }

    @Test func aDifferentProfilePushes() {
        var filter = RepeatPushFilter<String>()
        let profile = Screen()
        filter.willPush("ana", screen: profile, isTransitioning: false)
        filter.stoppedWaiting(profile)
        #expect(!filter.isRepeat("ben", topScreen: profile))
    }

    @Test func nothingPushedYetIsNeverARepeat() {
        let filter = RepeatPushFilter<String>()
        #expect(!filter.isRepeat("ana", topScreen: Screen()))
        #expect(!filter.isRepeat("ana", topScreen: nil))
    }

    @Test func aPushMidTransitionWaitsForRestAndARepeatMeanwhileIsDropped() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        let profile = Screen()
        #expect(filter.willPush("ana", screen: profile, isTransitioning: true) == .atRest)
        // Not on the stack yet: the top is still the origin, and the second
        // tap is still the same request.
        #expect(filter.isRepeat("ana", topScreen: origin))
        #expect(!filter.isRepeat("ben", topScreen: origin))
    }

    @Test func aDeferredPushThatLandedIsAnsweredByTheStack() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        let profile = Screen()
        filter.willPush("ana", screen: profile, isTransitioning: true)
        filter.stoppedWaiting(profile)
        #expect(filter.isRepeat("ana", topScreen: profile))
        // …and once popped, a tap pushes her again.
        #expect(!filter.isRepeat("ana", topScreen: origin))
    }

    @Test func aDeferredPushThatWasDroppedDoesNotSwallowTheNextTap() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        var profile: Screen? = Screen()
        filter.willPush("ana", screen: profile!, isTransitioning: true)
        filter.stoppedWaiting(profile!)
        profile = nil
        #expect(!filter.isRepeat("ana", topScreen: origin))
    }

    @Test func anotherScreenStoppingWaitingLeavesTheDeferredProfileWaiting() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        let profile = Screen()
        let thread = Screen()
        filter.willPush("ana", screen: profile, isTransitioning: true)
        filter.stoppedWaiting(thread)
        #expect(filter.isRepeat("ana", topScreen: origin))
    }

    @Test func aNewerProfileSupersedesADeferredOne() {
        var filter = RepeatPushFilter<String>()
        let origin = Screen()
        let ana = Screen()
        let ben = Screen()
        filter.willPush("ana", screen: ana, isTransitioning: true)
        filter.willPush("ben", screen: ben, isTransitioning: false)
        filter.stoppedWaiting(ben)
        #expect(!filter.isRepeat("ana", topScreen: origin))
        #expect(filter.isRepeat("ben", topScreen: ben))
    }

    // MARK: - Handles and share tokens (#800)

    /// A handle route is pushed at once and resolved by the screen, so a
    /// second tap on the same `@handle` arrives while it is still asking.
    @Test func theSameHandleWhileItsProfileStillResolvesIsARepeat() throws {
        var filter = RepeatPushFilter<ProfileRouteKey>()
        let profile = Screen()
        let first = try #require(AppRoute.profileHandle("ada").profileRouteKey)
        filter.willPush(first, screen: profile, isTransitioning: false)
        filter.stoppedWaiting(profile)
        let second = try #require(AppRoute.profileHandle("ada").profileRouteKey)
        #expect(filter.isRepeat(second, topScreen: profile))
    }

    @Test func handlesThatDifferOnlyInCaseAreTheSameRequest() {
        #expect(AppRoute.profileHandle("Ada").profileRouteKey == AppRoute.profileHandle("ada").profileRouteKey)
    }

    @Test func aDifferentHandlePushes() throws {
        var filter = RepeatPushFilter<ProfileRouteKey>()
        let profile = Screen()
        filter.willPush(try #require(AppRoute.profileHandle("ada").profileRouteKey), screen: profile, isTransitioning: false)
        filter.stoppedWaiting(profile)
        #expect(!filter.isRepeat(try #require(AppRoute.profileHandle("ben").profileRouteKey), topScreen: profile))
    }

    @Test func theSameShareTokenWhileItsProfileStillResolvesIsARepeat() throws {
        var filter = RepeatPushFilter<ProfileRouteKey>()
        let profile = Screen()
        let key = try #require(AppRoute.profileShareToken("tok").profileRouteKey)
        filter.willPush(key, screen: profile, isTransitioning: true)
        // Mid-transition the push waits for rest: still the same request.
        #expect(filter.isRepeat(key, topScreen: Screen()))
        #expect(!filter.isRepeat(.handle("tok"), topScreen: Screen()))
    }

    @Test func aHandleAndAnIDAreKeptApart() {
        #expect(AppRoute.profile(ProfileID("ada"), stub: nil).profileRouteKey == .id(ProfileID("ada")))
        #expect(AppRoute.profileHandle("ada").profileRouteKey == .handle("ada"))
        #expect(AppRoute.profileShareToken("ada").profileRouteKey == .shareToken("ada"))
    }

    @Test func aRouteThatIsNotAProfileHasNoKey() {
        #expect(AppRoute.search.profileRouteKey == nil)
        #expect(AppRoute.hashtag("ada").profileRouteKey == nil)
    }
}
