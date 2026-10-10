import CoreModels
import Foundation
import Testing
@testable import Feed

/// THE PILL'S FOLLOW STATE, WITHOUT THE PILL.
///
/// `SnapAuthorFollowStore` keeps where the viewer stands with each author:
/// the graph's answers, asked once per author; the "+" follow, drawn at once
/// and rolled back when the graph refuses; one follow per author in flight;
/// and graph events from other surfaces overlaid on it.
///
/// The graph is GATED: every lookup and follow waits until the test answers
/// it, so "in flight" is a state the test holds, not a race it hopes to win.
@MainActor
struct SnapAuthorFollowStoreTests {
    private let ava = ProfileID("ava")
    private let bo = ProfileID("bo")

    private static func store(_ graph: GatedGraph?) -> SnapAuthorFollowStore {
        SnapAuthorFollowStore(writer: graph, reader: graph)
    }

    /// Lets the store's tasks and the graph's gates move — bounded, and
    /// never on the clock.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Badges

    @Test(arguments: [
        (FollowRelation.notFollowing, SnapAuthorIdentityView.FollowBadge.follow),
        (.followedBy, .follow),
        (.following, .following),
        (.mutual, .friends),
        (.viewer, .none),
        (.blocked, .none),
    ])
    func eachRelationDrawsItsBadge(_ relation: FollowRelation, _ badge: SnapAuthorIdentityView.FollowBadge) {
        let store = Self.store(GatedGraph())
        store.setRelation(relation, for: ava)
        #expect(store.badge(for: ava) == badge)
        #expect(store.offersFollow(to: ava) == (badge == .follow))
    }

    @Test func anUnknownAuthorDrawsNoBadge() {
        let store = Self.store(GatedGraph())
        #expect(store.badge(for: ava) == .none)
        #expect(store.badge(for: nil) == .none)
    }

    @Test func withoutAFollowSeamNothingIsOfferedOrAsked() {
        let store = SnapAuthorFollowStore(writer: nil, reader: GatedGraph())
        store.setRelation(.notFollowing, for: ava)
        #expect(store.badge(for: ava) == .none)
        let sent = store.follow(ava, onRefused: {})
        #expect(sent == false)
        store.resolve(for: bo)
        #expect(store.relationsByAuthor[bo] == nil)
    }

    // MARK: - Lookups

    @Test func pagingBackAndForthAsksOncePerAuthor() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.resolve(for: ava)
        store.resolve(for: ava)
        await Self.settle { graph.pendingLookups == 1 }
        #expect(graph.lookups == [ava])

        graph.answerLookup(.notFollowing)
        await Self.settle { store.relationsByAuthor[ava] != nil }
        #expect(store.badge(for: ava) == .follow)

        store.resolve(for: ava)
        #expect(graph.lookups == [ava], "a known author is not asked again")
    }

    @Test func aRefreshAsksAgainAndKeepsTheOldAnswerUntilItLands() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.notFollowing, for: ava)

        store.resolve(for: ava, refresh: true)
        await Self.settle { graph.pendingLookups == 1 }
        #expect(store.badge(for: ava) == .follow, "the cached answer keeps drawing")

        graph.answerLookup(.following)
        await Self.settle { store.relationsByAuthor[ava] == .following }
        #expect(store.badge(for: ava) == .following)
    }

    @Test func aTapOutranksALookupStillOut() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.resolve(for: ava, refresh: true)
        await Self.settle { graph.pendingLookups == 1 }
        store.setRelation(.notFollowing, for: ava)
        store.follow(ava, onRefused: {})
        await Self.settle { graph.pendingFollows == 1 }

        graph.answerLookup(.notFollowing)
        await Self.settle { store.lookupsInFlight.isEmpty }
        #expect(store.relationsByAuthor[ava] == .following, "the late answer is dropped")

        graph.answerFollow(accepting: true)
        await Self.settle { store.followsInFlight.isEmpty }
    }

    // MARK: - The follow

    @Test func aFollowIsDrawnAtOnceAndTheGraphHearsIt() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.notFollowing, for: ava)
        var changed: [ProfileID] = []
        store.onRelationChange = { changed.append($0) }

        let sent = store.follow(ava, onRefused: { Issue.record("an accepted follow was refused") })
        #expect(sent)
        #expect(store.badge(for: ava) == .following, "optimistic: before the graph answers")
        #expect(changed == [ava])

        await Self.settle { graph.pendingFollows == 1 }
        #expect(graph.follows == [ava])
        graph.answerFollow(accepting: true)
        await Self.settle { store.followsInFlight.isEmpty }
        #expect(store.relationsByAuthor[ava] == .following)
        #expect(changed == [ava], "an accepted follow changes nothing more")
    }

    @Test func followingAFollowerMakesAFriend() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.followedBy, for: ava)
        store.follow(ava, onRefused: {})
        #expect(store.badge(for: ava) == .friends)
        await Self.settle { graph.pendingFollows == 1 }
        graph.answerFollow(accepting: true)
        await Self.settle { store.followsInFlight.isEmpty }
    }

    @Test func aRefusedFollowRollsBackAndSaysSo() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.notFollowing, for: ava)
        var refusals = 0

        store.follow(ava, onRefused: { refusals += 1 })
        await Self.settle { graph.pendingFollows == 1 }
        #expect(refusals == 0, "nothing is said before the graph answers")
        graph.answerFollow(accepting: false)
        await Self.settle { refusals > 0 }

        #expect(refusals == 1)
        #expect(store.relationsByAuthor[ava] == .notFollowing)
        #expect(store.offersFollow(to: ava), "the \"+\" comes back")
        #expect(store.followsInFlight.isEmpty)
    }

    @Test func aDoubleTapWhileInFlightSendsOneFollow() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.notFollowing, for: ava)

        let first = store.follow(ava, onRefused: {})
        let second = store.follow(ava, onRefused: {})
        #expect(first)
        #expect(second == false)
        await Self.settle { graph.pendingFollows == 1 }
        // An echo from elsewhere and a refresh both wait for the tap.
        store.graphDidChange(FollowChange(profileID: ava, isFollowing: false))
        store.resolve(for: ava, refresh: true)
        #expect(store.relationsByAuthor[ava] == .following)

        graph.answerFollow(accepting: true)
        await Self.settle { store.followsInFlight.isEmpty }
        #expect(graph.follows == [ava])
        #expect(graph.lookups.isEmpty)
    }

    /// The store is per author, not per page: paging away while a follow is
    /// out, and its refusal landing on another page, touches only its author.
    @Test func aPageChangeKeepsEachAuthorsState() async {
        let graph = GatedGraph()
        let store = Self.store(graph)
        store.setRelation(.notFollowing, for: ava)
        store.setRelation(.following, for: bo)
        var changed: [ProfileID] = []
        store.onRelationChange = { changed.append($0) }

        store.follow(ava, onRefused: {})
        await Self.settle { graph.pendingFollows == 1 }
        // The viewer pages to Bo, and back.
        #expect(store.badge(for: bo) == .following)
        #expect(store.badge(for: ava) == .following)

        graph.answerFollow(accepting: false)
        await Self.settle { store.followsInFlight.isEmpty }
        #expect(store.badge(for: ava) == .follow)
        #expect(store.badge(for: bo) == .following)
        #expect(changed == [ava, ava])
    }

    // MARK: - Graph events

    @Test func aFollowOrUnfollowElsewhereIsOverlaid() {
        let store = Self.store(GatedGraph())
        store.setRelation(.mutual, for: ava)
        store.graphDidChange(FollowChange(profileID: ava, isFollowing: false))
        #expect(store.relationsByAuthor[ava] == .followedBy, "a friend unfollowed still follows back")
        store.graphDidChange(FollowChange(profileID: bo, isFollowing: true))
        #expect(store.relationsByAuthor[bo] == .following, "an unknown author reads as not followed")
    }

    @Test func anUnfollowElsewhereLeavesTheViewerAndTheBlockedAlone() {
        let store = Self.store(GatedGraph())
        store.setRelation(.viewer, for: ava)
        store.setRelation(.blocked, for: bo)
        store.graphDidChange(FollowChange(profileID: ava, isFollowing: false))
        store.graphDidChange(FollowChange(profileID: bo, isFollowing: false))
        #expect(store.relationsByAuthor[ava] == .viewer)
        #expect(store.relationsByAuthor[bo] == .blocked)
    }

    @Test func anUnchangedAnswerIsNotReported() {
        let store = Self.store(GatedGraph())
        var changes = 0
        store.onRelationChange = { _ in changes += 1 }
        store.setRelation(.following, for: ava)
        store.setRelation(.following, for: ava)
        #expect(changes == 1)
    }
}

/// A follow graph whose every lookup and follow waits for the test's answer.
///
/// On the main actor, like the store and the tests: a gate is reached and
/// answered on one serial executor, so a few yields always let it move —
/// nothing waits on the shared cooperative pool.
@MainActor
private final class GatedGraph: SocialGraphReading, SocialGraphWriting {
    private var lookupGates: [CheckedContinuation<FollowRelation, any Error>] = []
    private var followGates: [CheckedContinuation<Void, any Error>] = []
    private(set) var lookups: [ProfileID] = []
    private(set) var follows: [ProfileID] = []

    var pendingLookups: Int { lookupGates.count }
    var pendingFollows: Int { followGates.count }

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        lookups.append(profileID)
        return try await withCheckedThrowingContinuation { lookupGates.append($0) }
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        follows.append(profileID)
        try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, any Error>) in
            followGates.append(gate)
        }
    }

    func answerLookup(_ relation: FollowRelation) {
        lookupGates.removeFirst().resume(returning: relation)
    }

    func answerFollow(accepting: Bool) {
        let gate = followGates.removeFirst()
        if accepting {
            gate.resume()
        } else {
            gate.resume(throwing: URLError(.badServerResponse))
        }
    }
}
