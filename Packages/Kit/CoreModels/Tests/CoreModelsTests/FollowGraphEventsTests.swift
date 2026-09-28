import Foundation
import Testing
@testable import CoreModels

/// The channel's whole contract: every live subscriber hears a change, a
/// released one hears nothing, and two channels never hear each other.
struct FollowGraphEventsTests {
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [FollowChange] = []
        func append(_ change: FollowChange) { lock.withLock { changes.append(change) } }
        var all: [FollowChange] { lock.withLock { changes } }
    }

    @Test func everySubscriberHearsAPublishedChange() {
        let events = FollowGraphEvents()
        let first = Heard(), second = Heard()
        let a = events.subscribe { first.append($0) }
        let b = events.subscribe { second.append($0) }

        let change = FollowChange(profileID: ProfileID("prof-2"), isFollowing: true)
        events.publish(change)

        #expect(first.all == [change])
        #expect(second.all == [change])
        withExtendedLifetime((a, b)) {}
    }

    @Test func aReleasedSubscriptionHearsNothing() {
        let events = FollowGraphEvents()
        let heard = Heard()
        var subscription: FollowGraphSubscription? = events.subscribe { heard.append($0) }
        withExtendedLifetime(subscription) {}
        subscription = nil

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))

        #expect(heard.all.isEmpty)
    }

    @Test func twoChannelsAreIndependent() {
        let one = FollowGraphEvents(), other = FollowGraphEvents()
        let heard = Heard()
        let subscription = other.subscribe { heard.append($0) }

        one.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))

        #expect(heard.all.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    @Test func theMainActorSubscriberHearsInOrder() async {
        let events = FollowGraphEvents()
        let heard = Heard()
        let subscription = events.subscribeOnMain { heard.append($0) }

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        for _ in 0..<100 where heard.all.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(heard.all.map(\.isFollowing) == [true, false])
        withExtendedLifetime(subscription) {}
    }
}
