import CoreModels
import Foundation
import Testing

/// The app's viewer channel (#2376): synchronous, ordered, on the main actor,
/// and nothing heard once a subscription goes.
@MainActor
struct ViewerEventsTests {
    /// What the handlers saw, in the order they ran.
    @MainActor
    private final class Log {
        var entries: [String] = []
    }

    @Test func aViewerChangeIsDeliveredBeforePublishReturns() {
        let events = ViewerEvents()
        let log = Log()
        let subscription = events.onViewerChange { log.entries.append("heard") }

        events.publishViewerChange()

        #expect(log.entries == ["heard"], "delivered later, or not at all")
        withExtendedLifetime(subscription) {}
    }

    @Test func observersRunInTheOrderTheySubscribed() {
        let events = ViewerEvents()
        let log = Log()
        let subscriptions = (1...5).map { index in
            events.onViewerChange { log.entries.append("\(index)") }
        }

        events.publishViewerChange()
        events.publishViewerChange()

        #expect(log.entries == ["1", "2", "3", "4", "5", "1", "2", "3", "4", "5"])
        withExtendedLifetime(subscriptions) {}
    }

    /// The cache wipe's phase: before every observer, even one that
    /// subscribed before it.
    @Test func theCachesPhaseRunsBeforeEveryObserver() {
        let events = ViewerEvents()
        let log = Log()
        let first = events.onViewerChange { log.entries.append("observer 1") }
        let cache = events.onViewerChange(.caches) { log.entries.append("cache") }
        let second = events.onViewerChange { log.entries.append("observer 2") }
        let laterCache = events.onViewerChange(.caches) { log.entries.append("cache 2") }

        events.publishViewerChange()

        #expect(log.entries == ["cache", "cache 2", "observer 1", "observer 2"])
        withExtendedLifetime((first, cache, second, laterCache)) {}
    }

    @Test func anActiveProfileChangeCarriesTheProfileOnTheSameTurn() {
        let events = ViewerEvents()
        let log = Log()
        let switches = events.onActiveProfileChange { log.entries.append("switch \($0.rawValue)") }
        let changes = events.onViewerChange { log.entries.append("viewer") }

        events.publishActiveProfileChange(ProfileID("prof-b"))

        #expect(log.entries == ["switch prof-b"], "a switch is not a viewer change, and arrives at once")
        withExtendedLifetime((switches, changes)) {}
    }

    @Test func aCancelledSubscriptionHearsNothing() {
        let events = ViewerEvents()
        let log = Log()
        let subscription = events.onViewerChange { log.entries.append("heard") }
        #expect(events.debugObservationCount == 1)

        subscription.cancel()
        subscription.cancel()
        events.publishViewerChange()

        #expect(log.entries.isEmpty)
        #expect(events.debugObservationCount == 0)
    }

    /// ⚠️ The subscription is the observation: dropped, it ends at once.
    @Test func aSubscriptionEndsWhenItGoes() {
        let events = ViewerEvents()
        let log = Log()
        do {
            let subscription = events.onActiveProfileChange { _ in log.entries.append("heard") }
            #expect(events.debugObservationCount == 1)
            withExtendedLifetime(subscription) {}
        }

        events.publishActiveProfileChange(ProfileID("prof-b"))

        #expect(log.entries.isEmpty, "a freed subscription still heard")
        #expect(events.debugObservationCount == 0)
    }

    /// A handler's captures go with the channel: nothing outlives it.
    @Test func theHandlersGoWithTheChannel() {
        final class Witness: Sendable {}
        weak var witness: Witness?
        var subscription: ViewerEventSubscription?
        do {
            let events = ViewerEvents()
            let captured = Witness()
            witness = captured
            subscription = events.onViewerChange { withExtendedLifetime(captured) {} }
        }
        #expect(witness == nil, "the channel's handler outlived it")
        // Cancelling against a channel that is gone does nothing.
        subscription?.cancel()
    }

    /// A subscription freed off the main actor — a nonisolated `deinit`,
    /// usually — ends too.
    @Test func aSubscriptionCancelledOffTheMainActorEnds() async {
        let events = ViewerEvents()
        let log = Log()
        let subscription = events.onViewerChange { log.entries.append("heard") }

        await Task.detached { subscription.cancel() }.value
        events.publishViewerChange()

        #expect(log.entries.isEmpty)
        #expect(events.debugObservationCount == 0)
    }

    /// A handler that subscribes during a delivery is heard from the next
    /// one; one cancelled before its turn is skipped.
    @Test func subscribingOrCancellingDuringADeliveryTakesEffectNextTurn() {
        let events = ViewerEvents()
        let log = Log()
        let held = Held()
        let first = events.onViewerChange {
            log.entries.append("first")
            held.second?.cancel()
            held.added.append(events.onViewerChange { log.entries.append("added") })
        }
        held.second = events.onViewerChange { log.entries.append("second") }

        events.publishViewerChange()
        #expect(log.entries == ["first"], "the cancelled one ran, or the new one heard this delivery")

        log.entries = []
        events.publishViewerChange()
        #expect(log.entries == ["first", "added"])
        withExtendedLifetime(first) {}
    }

    /// The subscriptions a handler makes and cancels.
    @MainActor
    private final class Held {
        var second: ViewerEventSubscription?
        var added: [ViewerEventSubscription] = []
    }

    /// The transport `UnavailablePosts` uses: the payload rides along.
    @Test func orderedHandlersDeliverTheirPayloadInOrder() {
        let handlers = OrderedHandlers<Set<PostID>>()
        let log = Log()
        let a = handlers.subscribe { log.entries.append("a \($0.map(\.rawValue).sorted())") }
        let b = handlers.subscribe { log.entries.append("b \($0.count)") }

        handlers.send([PostID("p1"), PostID("p2")])

        #expect(log.entries == ["a [\"p1\", \"p2\"]", "b 2"])
        #expect(handlers.debugObservationCount == 2)
        withExtendedLifetime((a, b)) {}
    }
}
