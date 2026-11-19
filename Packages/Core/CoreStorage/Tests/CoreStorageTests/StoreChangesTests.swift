import CoreStorage
import Foundation
import Testing

/// A store's changes, observed on the instance (#2376): delivered as the
/// `NotificationCenter.default` posts they replace were — on the sender's
/// thread, or on main with the sender waiting — to that instance's observers
/// only, for as long as each keeps its observation.
struct StoreChangesTests {
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int] = []
        private var _threads: [Bool] = []
        var values: [Int] { lock.withLock { _values } }
        var onMain: [Bool] { lock.withLock { _threads } }
        func append(_ value: Int) {
            lock.withLock {
                _values.append(value)
                _threads.append(Thread.isMainThread)
            }
        }
    }

    @Test func everyObserverHearsThePayloadInOrder() {
        let changes = StoreChanges<Int>()
        let heard = Heard()
        let first = changes.observe { heard.append($0) }
        let second = changes.observe { heard.append($0 * 10) }
        changes.send(1)
        changes.send(2)
        #expect(heard.values == [1, 10, 2, 20])
        withExtendedLifetime((first, second)) {}
    }

    /// No queue: on the sender's thread, before `send` returns.
    @Test func withoutAQueueTheHandlerRunsOnTheSendersThread() async {
        let changes = StoreChanges<Int>()
        let heard = Heard()
        let observation = changes.observe { heard.append($0) }
        await Task.detached {
            changes.send(7)
            #expect(heard.values == [7], "send returned before the handler ran")
        }.value
        #expect(heard.onMain == [false])
        withExtendedLifetime(observation) {}
    }

    /// On main: the sender waits for the handler, from any thread.
    @Test func onMainTheSenderWaitsForTheHandler() async {
        let changes = StoreChanges<Int>()
        let heard = Heard()
        let observation = changes.observeOnMain { heard.append($0) }
        await Task.detached {
            changes.send(3)
            #expect(heard.values == [3], "send returned before the handler ran")
        }.value
        #expect(heard.onMain == [true])
        withExtendedLifetime(observation) {}
    }

    /// Another instance's changes are not this one's.
    @Test func anObserverHearsItsInstanceOnly() {
        let mine = StoreChanges<Void>()
        let other = StoreChanges<Void>()
        let heard = Heard()
        let observation = mine.observe { heard.append(1) }
        other.send()
        #expect(heard.values.isEmpty)
        mine.send()
        #expect(heard.values == [1])
        withExtendedLifetime(observation) {}
    }

    /// ⚠️ THE OBSERVATION IS THE LIFETIME: cancelled or freed, it hears
    /// nothing more — which is why every observer keeps it.
    @Test func aCancelledOrFreedObservationHearsNothing() {
        let changes = StoreChanges<Int>()
        let heard = Heard()
        let cancelled = changes.observe { heard.append($0) }
        var freed: StoreObservation? = changes.observe { heard.append($0 * 10) }
        #expect(changes.debugObservationCount == 2)
        cancelled.cancel()
        cancelled.cancel()
        freed = nil
        changes.send(1)
        #expect(heard.values.isEmpty)
        #expect(changes.debugObservationCount == 0)
        #expect(freed == nil)
    }
}
