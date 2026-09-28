import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE PILL'S "+" FOLLOWS, AND IS ONLY THERE FOR SOMEONE TO FOLLOW.
///
/// It used to route to the author's profile, and it was drawn for everybody —
/// the people the viewer follows and the viewer themself included. Now it is
/// offered only when the graph says the viewer does not follow the author, and
/// a tap follows them in place. The "+" is part of the item's identifier, so
/// its coming and going is a new item to the bar: the native morph.
@MainActor
struct SnapAuthorFollowTests {
    private static func feed(
        graph: FollowGraphStub? = FollowGraphStub(), readable: Bool = true
    ) -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph,
            followRelations: readable ? graph : nil
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()
        return feed
    }

    private static func model(id: String = "p1", authorID: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID(authorID),
            authorName: "Name \(authorID)", metaText: "@\(authorID) · 2h", avatarURL: nil,
            caption: "c", mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    private static func authorItem(_ feed: SnapFeedViewController) throws -> UIBarButtonItem {
        try #require(feed.navigationItem.rightBarButtonItems?.first { $0.customView is SnapAuthorIdentityView })
    }

    private static func pill(_ feed: SnapFeedViewController) throws -> SnapAuthorIdentityView {
        try #require(try authorItem(feed).customView as? SnapAuthorIdentityView)
    }

    /// Unknown is no "+": on the Following feed every author is followed, and a
    /// "+" drawn and then withdrawn is the worse of the two errors.
    @Test func anAuthorWhoseRelationIsUnknownOffersNoFollow() throws {
        let feed = Self.feed()
        feed.showAuthor(Self.model(authorID: "prof-1"))

        #expect(try Self.pill(feed).offersFollow == false)
        #expect(try Self.authorItem(feed).identifier
                == SnapFeedViewController.authorItemIdentifier(for: ProfileID("prof-1"), offersFollow: false))
    }

    @Test(arguments: [FollowRelation.following, .viewer, .blocked])
    func anAuthorTheViewerCannotFollowOffersNoFollow(_ relation: FollowRelation) throws {
        let feed = Self.feed()
        feed.setFollowRelation(relation, for: ProfileID("prof-1"))
        feed.showAuthor(Self.model(authorID: "prof-1"))

        #expect(try Self.pill(feed).offersFollow == false)
    }

    @Test func anAuthorTheViewerDoesNotFollowOffersFollowUnderItsOwnIdentifier() throws {
        let feed = Self.feed()
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).offersFollow)
        #expect(try Self.authorItem(feed).identifier
                == SnapFeedViewController.authorItemIdentifier(for: ProfileID("prof-2"), offersFollow: true))
    }

    /// The answer arriving for the author ON the pill re-draws it: a fresh item,
    /// under the identifier that says "+", so the bar morphs it in.
    @Test func theGraphsAnswerInstallsAFreshItemWithTheFollow() async throws {
        let graph = FollowGraphStub(relations: [ProfileID("prof-2"): .notFollowing])
        let feed = Self.feed(graph: graph)
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let before = try Self.authorItem(feed)
        #expect(try Self.pill(feed).offersFollow == false, "precondition: not known yet")

        feed.resolveFollowRelation(for: ProfileID("prof-2"))
        for _ in 0..<200 where (try? Self.authorItem(feed)) === before {
            try await Task.sleep(for: .milliseconds(5))
        }

        let after = try Self.authorItem(feed)
        #expect(after !== before)
        #expect(after.identifier != before.identifier, "one identifier is one item to iOS 26: no morph")
        #expect(try Self.pill(feed).offersFollow)
    }

    /// Paging re-evaluates: the "+" belongs to the author, not to the pill.
    @Test func pagingToAnotherAuthorReEvaluatesTheFollow() throws {
        let feed = Self.feed()
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.setFollowRelation(.following, for: ProfileID("prof-1"))

        feed.showAuthor(Self.model(id: "p1", authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow)
        feed.showAuthor(Self.model(id: "p2", authorID: "prof-1"))
        #expect(try Self.pill(feed).offersFollow == false)
        feed.showAuthor(Self.model(id: "p3", authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow)
    }

    /// The tap follows OPTIMISTICALLY (the profile's rule): the "+" goes at
    /// once, in a fresh item, and the graph hears the follow.
    @Test func tappingFollowFollowsAndTheFollowGoes() async throws {
        let graph = FollowGraphStub()
        let feed = Self.feed(graph: graph)
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let offered = try Self.authorItem(feed)
        let pill = try Self.pill(feed)

        // Through the pill's own callback, as the button fires it.
        pill.onFollowTapped?(ProfileID("prof-2"))

        let followed = try Self.authorItem(feed)
        #expect(followed !== offered)
        #expect(followed.identifier
                == SnapFeedViewController.authorItemIdentifier(for: ProfileID("prof-2"), offersFollow: false))
        #expect(try Self.pill(feed).offersFollow == false)
        for _ in 0..<200 where graph.follows.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(graph.follows == [ProfileID("prof-2")])
        #expect(feed.followRelationsByAuthor[ProfileID("prof-2")] == .following)
    }

    /// A refused follow puts the "+" back.
    @Test func aRefusedFollowBringsTheFollowBack() async throws {
        let graph = FollowGraphStub(failsFollow: true)
        let feed = Self.feed(graph: graph)
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        feed.followAuthor(ProfileID("prof-2"))
        #expect(try Self.pill(feed).offersFollow == false)
        for _ in 0..<200 where (try? Self.pill(feed).offersFollow) == false {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try Self.pill(feed).offersFollow)
    }

    /// Nothing to follow THROUGH, nothing offered — an action that cannot act
    /// is not drawn.
    @Test func withoutAFollowSeamThereIsNoFollow() throws {
        let feed = Self.feed(graph: nil)
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).offersFollow == false)
    }
}

/// THE ATTRIBUTION IS AN ITEM PER THING IT DRAWS — the author pill's contract,
/// in the toolbar.
///
/// It was one view in one identifier-less item for the screen's life, rewritten
/// in place: the toolbar had nothing to transition between, so the capsule
/// never morphed the way the header's does.
@MainActor
struct SnapAttributionItemTests {
    private static func feed() -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        return feed
    }

    private static func model(id: String, author: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID(author),
            authorName: author, metaText: "@\(author) · 2h", avatarURL: nil,
            caption: "c", mediaURL: URL(string: "mock://media/1"),
            mediaKind: .video, thumbnailURL: nil, audioText: nil
        )
    }

    private static func attributionItems(_ feed: SnapFeedViewController) -> [UIBarButtonItem] {
        (feed.toolbarItems ?? []).filter { $0.customView is SnapMediaAttributionView }
    }

    @Test func aDifferentAttributionIsAFreshItemUnderItsOwnIdentifier() throws {
        let feed = Self.feed()
        let song = SnapMediaAttributionView.SoundCredit.sound("Haru Haru · BIGBANG")
        feed.showAttribution(Self.model(id: "p1", author: "Ada"), sound: song, cover: .note)
        let first = try #require(Self.attributionItems(feed).first)

        let other = SnapMediaAttributionView.SoundCredit.sound("Original sound · @grace")
        feed.showAttribution(Self.model(id: "p2", author: "Grace"), sound: other, cover: .note)
        let second = try #require(Self.attributionItems(feed).first)

        #expect(second !== first, "the same item was reused: the bar has nothing to transition between")
        #expect(second.customView !== first.customView, "one view mutated in place can never be transitioned")
        #expect(first.identifier != nil)
        #expect(second.identifier != first.identifier, "one identifier is one item to iOS 26: no transition")
        #expect(second.identifier == SnapFeedViewController.attributionItemIdentifier(
            forContent: SnapMediaAttributionView.contentKey(
                for: Self.model(id: "p2", author: "Grace"), sound: other, cover: .note
            )
        ))
        // Exactly one attribution in the bar, however many pages went by, and
        // still in the leading slot.
        #expect(Self.attributionItems(feed).count == 1)
        #expect(feed.toolbarItems?.first === second)
    }

    /// Two pages that DRAW the same pill are one item: nothing on the bar moves.
    @Test func theSameAttributionKeepsTheItem() throws {
        let feed = Self.feed()
        let song = SnapMediaAttributionView.SoundCredit.sound("Haru Haru · BIGBANG")
        feed.showAttribution(Self.model(id: "p1", author: "Ada"), sound: song, cover: .note)
        let first = try #require(Self.attributionItems(feed).first)

        feed.showAttribution(Self.model(id: "p2", author: "Ada"), sound: song, cover: .note)

        #expect(Self.attributionItems(feed).first === first)
    }

    /// The fresh pill is the host's pill: its tap still opens the sound.
    @Test func aFreshAttributionInheritsTheHostsWiring() throws {
        let feed = Self.feed()
        feed.showAttribution(Self.model(id: "p1", author: "Ada"), sound: .sound("A"), cover: .note)
        feed.showAttribution(Self.model(id: "p2", author: "Grace"), sound: .sound("B"), cover: .note)

        let pill = try #require(Self.attributionItems(feed).first?.customView as? SnapMediaAttributionView)
        #expect(pill.onTap != nil)
    }

    /// The key is what is DRAWN: the name, the line, whether it opens, the cover.
    @Test func theContentKeyFollowsWhatIsDrawn() {
        let ada = Self.model(id: "p1", author: "Ada")
        let key = SnapMediaAttributionView.contentKey(for: ada, sound: .sound("A"), cover: .note)

        #expect(key == SnapMediaAttributionView.contentKey(
            for: Self.model(id: "p9", author: "Ada"), sound: .sound("A"), cover: .note))
        #expect(key != SnapMediaAttributionView.contentKey(
            for: Self.model(id: "p1", author: "Grace"), sound: .sound("A"), cover: .note))
        #expect(key != SnapMediaAttributionView.contentKey(for: ada, sound: .sound("B"), cover: .note))
        #expect(key != SnapMediaAttributionView.contentKey(for: ada, sound: .none, cover: .note))
        #expect(key != SnapMediaAttributionView.contentKey(
            for: ada, sound: .sound("A"), cover: .artwork(URL(string: "mock://art/1")!)))
    }
}

/// A follow graph that answers from a table and records the follows it hears.
private final class FollowGraphStub: SocialGraphReading, SocialGraphWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let relations: [ProfileID: FollowRelation]
    private let failsFollow: Bool
    private var heard: [ProfileID] = []

    init(relations: [ProfileID: FollowRelation] = [:], failsFollow: Bool = false) {
        self.relations = relations
        self.failsFollow = failsFollow
    }

    var follows: [ProfileID] { lock.withLock { heard } }

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        relations[profileID] ?? .following
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        if failsFollow { throw URLError(.badServerResponse) }
        lock.withLock { heard.append(profileID) }
    }
}

/// No pages, ever: the tests drive the bars directly.
private final class FollowFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw URLError(.fileDoesNotExist)
    }
}
