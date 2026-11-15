import CacheKit
import CoreModels
import DesignSystem
import EntityStore
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import Chat

/// `InboxRelations` over a fake store (#2377): it sees the app's `EntityStore`
/// only through `ProfileEntityReading` and `ProfileEntityWriting`, so these
/// tests hand it `FakeProfileEntities` and check what it writes and how it
/// answers the store's changes. `InboxRelationMarkTests` keeps the real store,
/// for the one-copy-per-person behaviour across surfaces.
@MainActor
@Suite(.serialized)
struct InboxRelationsSeamTests {
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

    private static let peer = ProfileID("peer-1")

    private func model() -> ConversationDisplayModel {
        ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("c1"),
                title: "Ava Moreau",
                lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: [Self.peer],
                lastMessageIsMine: false,
                lastMessageID: "c1-latest",
                isUnread: false,
                unreadCount: 0
            ),
            now: Date(timeIntervalSince1970: 60),
            isPinned: false,
            isMuted: false,
            isUnread: false,
            unreadCount: 0
        )
    }

    /// What the graph answered goes to the store, and the mark reads it back
    /// from there.
    @Test func theGraphsAnswerIsWrittenToTheStore() async throws {
        let store = FakeProfileEntities()
        let relations = InboxRelations(entities: store, reader: Graph([Self.peer: .mutual]), writer: Graph([:]))
        #expect(relations.mark(for: Self.peer) == .loading)
        relations.resolve([Self.peer])
        try #require(await settle { store.relationWrites == [Self.peer: .mutual] }, "not written to the store")
        #expect(relations.mark(for: Self.peer) == .friends)
    }

    /// A row's peer is written as a projection (`.ifUnknown`): it fills what
    /// the store lacks and never replaces a full profile.
    @Test func aRowsPeerIsWrittenAsAProjection() {
        let store = FakeProfileEntities()
        let relations = InboxRelations(entities: store, reader: Graph([:]), writer: Graph([:]))
        relations.saw(model())
        let write = store.summaryWrites.first
        #expect(store.summaryWrites.count == 1)
        #expect(write?.summary.id == Self.peer)
        #expect(write?.summary.displayName == "Ava Moreau")
        #expect(write?.freshness == .ifUnknown)
        #expect(write?.tier == .recent)
    }

    /// The store's changes reach the rows: the people who changed, or every
    /// row (nil) on a viewer change.
    @Test func theStoresChangesReachTheRows() {
        let store = FakeProfileEntities()
        let relations = InboxRelations(entities: store, reader: Graph([:]), writer: Graph([:]))
        var told: [Set<ProfileID>?] = []
        relations.observe(by: store) { told.append($0) }
        store.emit(.some([Self.peer]))
        store.emit(.everything)
        #expect(told == [[Self.peer], nil])
    }

    /// Released with the inbox: the store keeps no observer for it.
    @Test func releasingTheInboxStopsObserving() {
        let store = FakeProfileEntities()
        var relations: InboxRelations? = InboxRelations(entities: store, reader: Graph([:]), writer: Graph([:]))
        #expect(store.observerCount == 1)
        _ = relations
        relations = nil
        #expect(store.observerCount == 0)
    }
}

/// A profile store with nothing but a dictionary behind it. It keeps the
/// store's contract (`ProfileEntityReading`): reads are synchronous, a write
/// calls the observers with the id after it lands, and `emit` stands for the
/// real store's change, a viewer change included.
final class FakeProfileEntities: ProfileEntityReading, ProfileEntityWriting, @unchecked Sendable {
    struct SummaryWrite {
        let summary: AuthorSummary
        let tier: CacheTier
        let freshness: CountFreshness
    }

    private let lock = Mutex(State())

    private struct State {
        var relations: [ProfileID: FollowRelation] = [:]
        var relationWrites: [ProfileID: FollowRelation] = [:]
        var summaryWrites: [SummaryWrite] = []
        var observers: [UInt64: @MainActor @Sendable (EntityChange<ProfileID>) -> Void] = [:]
        var nextToken: UInt64 = 0
    }

    var relationWrites: [ProfileID: FollowRelation] { lock.withLock { $0.relationWrites } }
    var summaryWrites: [SummaryWrite] { lock.withLock { $0.summaryWrites } }
    var observerCount: Int { lock.withLock { $0.observers.count } }

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

    func upsert(_ summary: AuthorSummary, tier: CacheTier, freshness: CountFreshness) {
        lock.withLock { $0.summaryWrites.append(SummaryWrite(summary: summary, tier: tier, freshness: freshness)) }
    }

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
