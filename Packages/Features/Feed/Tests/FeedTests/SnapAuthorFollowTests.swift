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
/// a tap follows them in place. Once followed the pill does not forget it: the
/// "+" becomes the followed mark, or the FRIENDS mark when the author follows
/// back. Every change of glyph is drawn IN PLACE, through the pill's own blur:
/// the item and its identifier never change.
@MainActor
struct SnapAuthorFollowTests {
    private static func feed(
        graph: FollowGraphStub? = FollowGraphStub(), readable: Bool = true,
        events: FollowGraphEvents? = nil
    ) -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph,
            followRelations: readable ? graph : nil,
            followEvents: events
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

    /// The author pill's item — the toolbar's leading one since #671/#680.
    private static func authorItem(_ feed: SnapFeedViewController) throws -> UIBarButtonItem {
        try #require(feed.toolbarItems?.first { $0.customView is SnapAuthorIdentityView })
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
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier)
    }

    @Test(arguments: [FollowRelation.following, .mutual, .viewer, .blocked])
    func anAuthorTheViewerCannotFollowOffersNoFollow(_ relation: FollowRelation) throws {
        let feed = Self.feed()
        feed.setFollowRelation(relation, for: ProfileID("prof-1"))
        feed.showAuthor(Self.model(authorID: "prof-1"))

        #expect(try Self.pill(feed).offersFollow == false)
    }

    @Test func anAuthorTheViewerDoesNotFollowOffersFollowInTheSameItem() throws {
        let feed = Self.feed()
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).offersFollow)
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier)
    }

    /// The answer arriving for the author ON the pill re-draws its badge — in
    /// the same item, so the glass does not morph.
    @Test func theGraphsAnswerDrawsTheFollowInPlace() async throws {
        let graph = FollowGraphStub(relations: [ProfileID("prof-2"): .notFollowing])
        let feed = Self.feed(graph: graph)
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let before = try Self.authorItem(feed)
        #expect(try Self.pill(feed).offersFollow == false, "precondition: not known yet")

        feed.resolveFollowRelation(for: ProfileID("prof-2"))
        for _ in 0..<200 where (try? Self.pill(feed).offersFollow) == false {
            try await Task.sleep(for: .milliseconds(5))
        }

        let after = try Self.authorItem(feed)
        #expect(after === before, "a new item for a badge: iOS 26 morphs the glass between them")
        #expect(after.identifier == SnapFeedViewController.authorItemIdentifier)
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
    /// once, in the same item, and the graph hears the follow.
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
        #expect(followed === offered)
        #expect(followed.identifier == SnapFeedViewController.authorItemIdentifier)
        #expect(try Self.pill(feed).offersFollow == false)
        #expect(try Self.pill(feed).followBadge == .following, "a follow is drawn, not forgotten")
        for _ in 0..<200 where graph.follows.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(graph.follows == [ProfileID("prof-2")])
        #expect(feed.followRelationsByAuthor[ProfileID("prof-2")] == .following)
    }

    /// Each relation draws its own badge — so a friend reads apart from a
    /// one-way follow — under the slot's one identifier.
    @Test(arguments: [
        (FollowRelation.notFollowing, SnapAuthorIdentityView.FollowBadge.follow),
        (.followedBy, .follow),
        (.following, .following),
        (.mutual, .friends),
        (.viewer, .none),
        (.blocked, .none),
    ])
    func eachRelationDrawsItsOwnBadge(
        _ relation: FollowRelation, _ badge: SnapAuthorIdentityView.FollowBadge
    ) throws {
        let feed = Self.feed()
        feed.setFollowRelation(relation, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).followBadge == badge)
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier)
    }

    /// The three drawn badges are three glyphs — the difference the blur
    /// carries now that the identifier no longer does.
    @Test func theThreeDrawnBadgesAreThreeGlyphs() {
        let badges: [SnapAuthorIdentityView.FollowBadge] = [.follow, .following, .friends]
        #expect(Set(badges.compactMap(\.symbolName)).count == badges.count)
        #expect(SnapAuthorIdentityView.FollowBadge.none.symbolName == nil)
    }

    /// Following someone who already follows the viewer makes a FRIEND, and
    /// the optimistic draw says so at once.
    @Test func followingBackDrawsTheFriendsMark() async throws {
        let graph = FollowGraphStub()
        let feed = Self.feed(graph: graph)
        feed.setFollowRelation(.followedBy, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow, "following back is a follow")

        feed.followAuthor(ProfileID("prof-2"))

        #expect(try Self.pill(feed).followBadge == .friends)
        #expect(feed.followRelationsByAuthor[ProfileID("prof-2")] == .mutual)
        for _ in 0..<200 where graph.follows.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(graph.follows == [ProfileID("prof-2")])
    }

    /// A state mark is not an action: it takes no touch, so a tap on it is a
    /// tap on the pill (the profile), and it never follows.
    @Test(arguments: [SnapAuthorIdentityView.FollowBadge.following, .friends])
    func aStateMarkTakesNoTap(_ badge: SnapAuthorIdentityView.FollowBadge) throws {
        let pill = SnapAuthorIdentityView()
        pill.setFollowBadge(badge)
        let glyph = try #require(Self.badgeButton(in: pill))

        #expect(glyph.isHidden == false)
        #expect(glyph.isUserInteractionEnabled == false)
        #expect(glyph.accessibilityLabel == badge.accessibilityLabel)

        pill.setFollowBadge(.follow)
        #expect(glyph.isUserInteractionEnabled, "the \"+\" is the one badge that acts")
        pill.setFollowBadge(.none)
        #expect(glyph.isHidden)
    }

    private static func badgeButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let button = sub as? UIButton { return button }
            if let found = badgeButton(in: sub) { return found }
        }
        return nil
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

    /// A follow accepted ELSEWHERE — on the author's own profile — takes the
    /// "+" away, and an unfollow elsewhere brings it back: the pill and the
    /// profile's button never disagree.
    @Test func aFollowOrUnfollowMadeElsewhereReachesThePill() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.setFollowRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        for _ in 0..<200 where (try? Self.pill(feed).offersFollow) == true {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try Self.pill(feed).offersFollow == false)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        for _ in 0..<200 where (try? Self.pill(feed).offersFollow) == false {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try Self.pill(feed).offersFollow)
    }

    /// A friend unfollowed elsewhere still follows the viewer: the "+" comes
    /// back, and following again from anywhere makes a friend again.
    @Test func aFriendUnfollowedElsewhereStillFollowsTheViewer() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.setFollowRelation(.mutual, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .friends)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        for _ in 0..<200 where (try? Self.pill(feed).followBadge) == .friends {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try Self.pill(feed).followBadge == .follow)
        #expect(feed.followRelationsByAuthor[ProfileID("prof-2")] == .followedBy)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        for _ in 0..<200 where (try? Self.pill(feed).followBadge) == .follow {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try Self.pill(feed).followBadge == .friends)
    }

    /// An unfollow does not make the viewer themself, or someone they block,
    /// followable.
    @Test func anUnfollowElsewhereLeavesTheViewerAndTheBlockedAlone() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.setFollowRelation(.viewer, for: ProfileID("me"))
        feed.setFollowRelation(.blocked, for: ProfileID("prof-3"))

        events.publish(FollowChange(profileID: ProfileID("me"), isFollowing: false))
        events.publish(FollowChange(profileID: ProfileID("prof-3"), isFollowing: false))
        // One main-queue turn delivers both (publication order).
        try await Task.sleep(for: .milliseconds(50))

        #expect(feed.followRelationsByAuthor[ProfileID("me")] == .viewer)
        #expect(feed.followRelationsByAuthor[ProfileID("prof-3")] == .blocked)
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

/// THE ATTRIBUTION IS ONE ITEM FOR THE SLOT — the author pill's contract, in
/// the toolbar.
///
/// It was a fresh item per thing it drew (#295), under a per-content
/// identifier, so iOS 26 morphed the capsule's glass on every page. Now the
/// item, its identifier and its view stay, and the content blurs across.
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

    private static func labels(in view: UIView) -> [String] {
        view.subviews.flatMap { subview -> [String] in
            var found = labels(in: subview)
            if let label = subview as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
            return found
        }
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
