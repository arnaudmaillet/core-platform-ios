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

    // MARK: - One viewer's changes (#978)

    /// The viewer the app is used as, switchable from a test.
    private final class Viewer: @unchecked Sendable {
        private let lock = NSLock()
        private var current: ProfileID?
        init(_ current: ProfileID?) { self.current = current }
        var id: ProfileID? {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    /// Up to 6 000 looks 10 ms apart: a look budget, not a deadline, so a
    /// starved runner gets more time, never a false failure.
    @MainActor
    private func settle(_ done: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    @Test func aChangeCarriesTheViewerItWasMadeAs() {
        let change = FollowChange(profileID: ProfileID("prof-2"), isFollowing: true, viewerID: ProfileID("me"))
        #expect(change.viewerID == ProfileID("me"))
        #expect(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true).viewerID == nil)
    }

    /// A follow sent as A and accepted after the switch to B reaches nobody;
    /// B's own changes, and changes made as nobody in particular, go through.
    @Test func aChangeMadeAsAnotherViewerIsNotDelivered() {
        let viewer = Viewer(ProfileID("viewer-b"))
        let events = FollowGraphEvents(currentViewer: { viewer.id })
        let heard = Heard()
        let subscription = events.subscribe { heard.append($0) }

        let late = FollowChange(profileID: ProfileID("x"), isFollowing: true, viewerID: ProfileID("viewer-a"))
        let own = FollowChange(profileID: ProfileID("y"), isFollowing: true, viewerID: ProfileID("viewer-b"))
        let unattributed = FollowChange(profileID: ProfileID("z"), isFollowing: false)
        events.publish(late)
        events.publish(own)
        events.publish(unattributed)

        #expect(heard.all == [own, unattributed], "heard \(heard.all)")
        #expect(!events.isForCurrentViewer(late))
        withExtendedLifetime(subscription) {}
    }

    /// A channel told of no viewer (or a viewer not known yet) delivers
    /// everything: nothing to tell the changes apart by.
    @Test func withNoViewerKnownEveryChangeIsDelivered() {
        let viewer = Viewer(nil)
        let events = FollowGraphEvents(currentViewer: { viewer.id })
        let heard = Heard()
        let subscription = events.subscribe { heard.append($0) }

        let change = FollowChange(profileID: ProfileID("x"), isFollowing: true, viewerID: ProfileID("viewer-a"))
        events.publish(change)

        #expect(heard.all == [change])
        withExtendedLifetime(subscription) {}
    }

    /// The main-actor hop is a turn later: a switch that lands in between
    /// drops the change there too.
    @MainActor
    @Test func aSwitchDuringTheMainActorHopDropsTheChange() async {
        let viewer = Viewer(ProfileID("viewer-a"))
        let events = FollowGraphEvents(currentViewer: { viewer.id })
        let heard = Heard()
        let subscription = events.subscribeOnMain { heard.append($0) }

        events.publish(FollowChange(profileID: ProfileID("x"), isFollowing: true, viewerID: ProfileID("viewer-a")))
        // On the main actor still: the hop has not run yet.
        viewer.id = ProfileID("viewer-b")
        let marker = FollowChange(profileID: ProfileID("marker"), isFollowing: true, viewerID: ProfileID("viewer-b"))
        events.publish(marker)

        #expect(await settle { !heard.all.isEmpty }, "the marker never arrived")
        #expect(heard.all == [marker], "a change made as the previous viewer was delivered: \(heard.all)")
        withExtendedLifetime(subscription) {}
    }
}
