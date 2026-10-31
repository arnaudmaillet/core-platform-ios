import CoreModels
import EntityStore
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// One relation binding for every author pill (#1972): the page's author on
/// Shots wore no badge on its first pass — a page configured ahead of time
/// never heard its author's answer, and a viewer change asked nobody again.
@MainActor
struct AuthorBadgeBindingTests {
    private let ava = ProfileID("ava")
    private let bo = ProfileID("bo")

    /// Lets the store's lookups land — bounded, and never on the clock.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    /// An unknown relation draws nothing and is asked for once; its answer
    /// redraws the pill — one not in any window included.
    @Test func anUnknownRelationDrawsNothingIsAskedOnceAndItsAnswerLands() async {
        let graph = AnsweringGraph(answers: [ava: .notFollowing])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph)
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let pill = Pill()
        let twin = Pill()

        binding.bind(pill, to: ava)
        binding.bind(twin, to: ava)
        #expect(pill.drawn == [.none], "an unknown relation drew a badge")
        await Self.settle { pill.drawn.last == .follow }
        #expect(graph.lookups == [ava], "asked more than once")
        #expect(pill.drawn.last == .follow, "the answer did not reach a pill out of every window")
        #expect(twin.drawn.last == .follow, "a second pill by the same author missed it")
        #expect(pill.animated.last == false, "a pill nobody sees was animated")
    }

    /// A pill rebound to another author stops hearing the first.
    @Test func aRebindStopsTheOldAuthorsUpdates() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]))
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let pill = Pill()
        binding.bind(pill, to: ava)
        binding.bind(pill, to: bo)
        store.setRelation(.following, for: ava)
        #expect(pill.drawn.last == PersonPill.Badge.none, "a rebound pill drew the old author's answer")
        store.setRelation(.mutual, for: bo)
        #expect(pill.drawn.last == .friends)
        binding.bind(pill, to: nil)
        store.setRelation(.following, for: bo)
        #expect(pill.drawn.last == PersonPill.Badge.none, "an unbound pill still heard its author")
    }

    /// A viewer change clears every relation: every pill is redrawn, and an
    /// author still unknown is asked again — it reported nothing, since its
    /// answer was unknown before and after.
    @Test func aViewerChangeClearsAndAsksAgain() async {
        let entities = EntityStore()
        let graph = AnsweringGraph(answers: [ava: .following])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities)
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        store.onEveryRelationChange = { binding.viewerDidChange() }
        let pill = Pill()
        binding.bind(pill, to: ava)
        await Self.settle { pill.drawn.last == .following }
        #expect(pill.drawn.last == .following)

        graph.answers[ava] = .notFollowing
        entities.viewerDidChange()
        await Self.settle { pill.drawn.last == .follow }
        #expect(graph.lookups == [ava, ava], "the viewer change did not ask again")
        #expect(pill.drawn.last == .follow, "the new viewer's answer did not land")
    }

    /// The belt: a pill scrolling in is drawn with what is known now.
    @Test func reapplyDrawsWhatIsKnownNow() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]))
        let binding = AuthorBadgeBinding(store: store)
        let pill = Pill()
        binding.bind(pill, to: ava)
        store.setRelation(.following, for: ava)
        binding.reapply(pill)
        #expect(pill.drawn.last == .following)
        #expect(pill.animated.last == false)
    }

    /// The For You root's page: a cell configured before its author's
    /// answer lands wears the badge once it lands, without a reconfigure —
    /// though it is in no window.
    @Test func aPreparedCellWearsTheBadgeOnceTheAnswerLands() async {
        let graph = AnsweringGraph(answers: [ava: .notFollowing])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph)
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        binding.bind(cell, to: ava)
        #expect(cell.authorRowBadgeSymbol == nil, "an unknown relation drew a badge")
        await Self.settle { cell.authorRowBadgeSymbol != nil }
        #expect(cell.authorRowBadgeSymbol != nil, "the prepared cell never wore its author's badge")
        #expect(cell.window == nil)
    }
}

/// A pill that records what it was told to draw.
@MainActor
private final class Pill: AuthorBadgeDrawing {
    var drawn: [PersonPill.Badge] = []
    var animated: [Bool] = []
    var onScreen = false

    func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool) {
        drawn.append(badge)
        self.animated.append(animated)
    }

    var drawsAuthorBadgeOnScreen: Bool { onScreen }
}

/// A follow graph that answers at once from `answers`, recording each ask.
@MainActor
private final class AnsweringGraph: SocialGraphReading, SocialGraphWriting {
    var answers: [ProfileID: FollowRelation]
    private(set) var lookups: [ProfileID] = []

    init(answers: [ProfileID: FollowRelation]) {
        self.answers = answers
    }

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        lookups.append(profileID)
        guard let answer = answers[profileID] else { throw URLError(.resourceUnavailable) }
        return answer
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

    func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
}
