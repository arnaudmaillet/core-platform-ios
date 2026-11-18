import CacheKit
import CoreModels
import EntityStore
import Foundation
import Synchronization
import Testing
@testable import Feed
@testable import PostSurfaces

/// `SnapAuthorFollowStore` over a fake store (#2377): it sees the app's
/// `EntityStore` only through `ProfileEntityReading` and
/// `ProfileEntityWriting`, so these tests hand it a dictionary and check what
/// it writes there and how it answers the store's changes.
/// `SnapAuthorFollowStoreTests` keeps the real store, for the follow channel.
@MainActor
@Suite(.serialized)
struct SnapAuthorFollowStoreSeamTests {
    private actor Graph: SocialGraphReading, SocialGraphWriting {
        var relations: [ProfileID: FollowRelation]

        init(_ relations: [ProfileID: FollowRelation]) { self.relations = relations }

        func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
            guard let relation = relations[profileID] else { throw URLError(.badServerResponse) }
            return relation
        }

        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

        func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
    }

    private static let ava = ProfileID("ava")
    private static let bo = ProfileID("bo")

    private static func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        return condition()
    }

    /// What the graph answered goes to the store, and the badge reads it
    /// back from there.
    @Test func theGraphsAnswerIsWrittenToTheStore() async throws {
        let entities = SeamProfileEntities()
        let graph = Graph([Self.ava: .mutual])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities, viewer: { nil })
        #expect(store.badge(for: Self.ava) == .loading)

        store.resolve(for: Self.ava)
        try #require(await Self.settle { entities.relationWrites[Self.ava] == .mutual }, "not written to the store")
        #expect(store.badge(for: Self.ava) == .friends)
    }

    /// Another surface's write reaches a drawn author: the screen re-draws
    /// it. An author this screen never drew reports nothing.
    @Test func anotherSurfacesWriteRedrawsOnlyADrawnAuthor() async throws {
        let entities = SeamProfileEntities()
        let graph = Graph([:])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities, viewer: { nil })
        var redrawn: [ProfileID] = []
        store.onRelationChange = { redrawn.append($0) }
        _ = store.badge(for: Self.ava)

        entities.land(.following, for: Self.ava)
        entities.land(.following, for: Self.bo)
        entities.emit(.some([Self.ava, Self.bo]))

        #expect(redrawn == [Self.ava])
        #expect(store.badge(for: Self.ava) == .following)
    }

    /// A viewer change (`.everything`) forgets every relation at once.
    @Test func aViewerChangeReachesEveryAuthor() {
        let entities = SeamProfileEntities()
        let graph = Graph([:])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities, viewer: { nil })
        var everyRelationChanged = 0
        store.onEveryRelationChange = { everyRelationChanged += 1 }

        entities.emit(.everything)
        #expect(everyRelationChanged == 1)
    }

    /// The store's observation ends with the screen's follow store.
    @Test func theObservationEndsWithTheFollowStore() {
        let entities = SeamProfileEntities()
        let graph = Graph([:])
        var store: SnapAuthorFollowStore? = SnapAuthorFollowStore(
            writer: graph, reader: graph, entities: entities, viewer: { nil }
        )
        #expect(entities.observerCount == 1)
        withExtendedLifetime(store) {}
        store = nil
        #expect(entities.observerCount == 0)
    }
}

/// A profile store with nothing but a dictionary behind it. It keeps the
/// store's contract (`ProfileEntityReading`): reads are synchronous, a write
/// calls the observers with the id after it lands, and `emit` stands for the
/// real store's change, a viewer change included.
private final class SeamProfileEntities: ProfileEntityReading, ProfileEntityWriting, @unchecked Sendable {
    private let lock = Mutex(State())

    private struct State {
        var relations: [ProfileID: FollowRelation] = [:]
        var relationWrites: [ProfileID: FollowRelation] = [:]
        var observers: [UInt64: @MainActor @Sendable (EntityChange<ProfileID>) -> Void] = [:]
        var nextToken: UInt64 = 0
    }

    var relationWrites: [ProfileID: FollowRelation] { lock.withLock { $0.relationWrites } }
    var observerCount: Int { lock.withLock { $0.observers.count } }

    /// Puts an answer in the store without telling anyone, as another
    /// surface's write does before its change is emitted.
    func land(_ relation: FollowRelation, for id: ProfileID) {
        lock.withLock { $0.relations[id] = relation }
    }

    /// Calls every observer, as the real store does after a write.
    @MainActor
    func emit(_ change: EntityChange<ProfileID>) {
        for handler in lock.withLock({ Array($0.observers.values) }) { handler(change) }
    }

    func profile(_ id: ProfileID) -> ProfileEntity? { nil }

    func relation(to id: ProfileID) -> FollowRelation? { lock.withLock { $0.relations[id] } }

    func knownIdentity(of id: ProfileID, stub: ProfileIdentityStub?) -> ProfileIdentityStub? { stub }

    func observeProfile(
        _ id: ProfileID, _ handler: @escaping @MainActor @Sendable (ProfileID) -> Void
    ) -> EntityObservation {
        observeProfiles { change in if change.contains(id) { handler(id) } }
    }

    func observeProfiles(
        _ handler: @escaping @MainActor @Sendable (EntityChange<ProfileID>) -> Void
    ) -> EntityObservation {
        let token = lock.withLock { state -> UInt64 in
            state.nextToken += 1
            state.observers[state.nextToken] = handler
            return state.nextToken
        }
        return EntityObservation { [weak self] in
            _ = self?.lock.withLock { $0.observers.removeValue(forKey: token) }
        }
    }

    func upsert(_ summary: AuthorSummary, tier: CacheTier, freshness: CountFreshness) {}

    @discardableResult
    func setRelation(_ relation: FollowRelation?, for id: ProfileID) -> FollowRelation? {
        let previous = lock.withLock { state -> FollowRelation? in
            let previous = state.relations[id]
            state.relations[id] = relation
            if let relation { state.relationWrites[id] = relation }
            return previous
        }
        Task { @MainActor in self.emit(.some([id])) }
        return previous
    }

    func applyFollowChange(_ change: FollowChange) {}

    func applyFollowRequestChange(_ change: FollowRequestChange) {}
}
