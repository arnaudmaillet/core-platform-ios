import CoreModels
import EntityStore
import Foundation
import MediaCore
import MediaUI
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

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

    /// An unknown relation draws the skeleton's badge (#2098) and is asked
    /// for once; its answer redraws the pill — one not in any window
    /// included.
    @Test func anUnknownRelationDrawsTheSkeletonIsAskedOnceAndItsAnswerLands() async {
        let graph = AnsweringGraph(answers: [ava: .following])
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, viewer: { nil })
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let pill = Pill()
        let twin = Pill()

        binding.bind(pill, to: ava)
        binding.bind(twin, to: ava)
        #expect(pill.drawn == [.loading], "an unknown relation is the skeleton's badge (#2098)")
        await Self.settle { pill.drawn.last == .following }
        #expect(graph.lookups == [ava], "asked more than once")
        #expect(pill.drawn.last == .following, "the answer did not reach a pill out of every window")
        #expect(twin.drawn.last == .following, "a second pill by the same author missed it")
        #expect(pill.animated.last == false, "a pill nobody sees was animated")
    }

    /// A pill rebound to another author stops hearing the first.
    @Test func aRebindStopsTheOldAuthorsUpdates() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]),
        viewer: { nil })
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let pill = Pill()
        binding.bind(pill, to: ava)
        binding.bind(pill, to: bo)
        store.setRelation(.following, for: ava)
        #expect(pill.drawn.last == .loading, "a rebound pill drew the old author's answer")
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
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities, viewer: { nil })
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        store.onEveryRelationChange = { binding.viewerDidChange() }
        let pill = Pill()
        binding.bind(pill, to: ava)
        await Self.settle { pill.drawn.last == .following }
        #expect(pill.drawn.last == .following)

        graph.answers[ava] = .mutual
        entities.viewerDidChange()
        await Self.settle { pill.drawn.last == .friends }
        #expect(graph.lookups == [ava, ava], "the viewer change did not ask again")
        #expect(pill.drawn.last == .friends, "the new viewer's answer did not land")
    }

    /// The belt: a pill scrolling in is drawn with what is known now.
    @Test func reapplyDrawsWhatIsKnownNow() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]),
        viewer: { nil })
        let binding = AuthorBadgeBinding(store: store)
        let pill = Pill()
        binding.bind(pill, to: ava)
        store.setRelation(.following, for: ava)
        binding.reapply(pill)
        #expect(pill.drawn.last == .following)
        #expect(pill.animated.last == false)
    }

    /// THE FOLLOW BESIDE THE BADGE (#2419): a band bound with a Follow is
    /// drawn its offer from the same answer as its badge — Follow for
    /// someone not followed, and it never disagrees with the badge; one
    /// bound without (a shelf's card) is told none.
    @Test func aBandBoundWithAFollowDrawsItsOffer() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]),
        viewer: { nil })
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        let row = FollowPill()
        let card = FollowPill()
        binding.bind(row, to: ava, offersFollow: true)
        binding.bind(card, to: ava)
        #expect(row.offers == [.none], "a relation not known yet offered a Follow")
        store.setRelation(.notFollowing, for: ava)
        #expect(row.offers.last == .follow)
        #expect(row.drawn.last == PersonPill.Badge.none, "not followed wore a badge")
        #expect(card.offers.allSatisfy { $0 == .none }, "a card was offered a Follow")
        row.onScreen = true
        store.setRelation(.following, for: ava)
        #expect(row.offers.last == .following)
        #expect(row.drawn.last == .following)
        #expect(row.followAnimated.last == true, "a follow seen on screen was not animated")
        store.setRelation(.requested, for: ava)
        #expect(row.offers.last == .requested)
        #expect(row.drawn.last == PersonPill.Badge.none, "a request wore a badge")
        binding.bind(row, to: nil, offersFollow: true)
        #expect(row.offers.last == AuthorFollowOffer.none)
    }

    /// The viewer's own posts offer nothing, from the first frame.
    @Test func theViewersOwnPostsOfferNothing() {
        let store = SnapAuthorFollowStore(writer: AnsweringGraph(answers: [:]), reader: AnsweringGraph(answers: [:]),
        viewer: { ProfileID("ava") })
        #expect(store.followOffer(for: ava) == .none)
        #expect(store.badge(for: ava) == .none)
        let noWriter = SnapAuthorFollowStore(writer: nil, reader: AnsweringGraph(answers: [:]), viewer: { nil })
        noWriter.setRelation(.notFollowing, for: ava)
        #expect(noWriter.followOffer(for: ava) == .none, "a Follow with no graph to follow through")
    }
}

/// A band that records its badge and its Follow.
@MainActor
private final class FollowPill: AuthorFollowDrawing {
    var drawn: [PersonPill.Badge] = []
    var offers: [AuthorFollowOffer] = []
    var followAnimated: [Bool] = []
    var onScreen = false

    func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool) { drawn.append(badge) }

    func drawAuthorFollow(_ offer: AuthorFollowOffer, animated: Bool) {
        offers.append(offer)
        followAnimated.append(animated)
    }

    var drawsAuthorBadgeOnScreen: Bool { onScreen }
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
