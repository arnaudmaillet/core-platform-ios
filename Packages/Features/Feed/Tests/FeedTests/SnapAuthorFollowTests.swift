import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import MediaCoreFixtures
import MediaUI
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// THE PILL'S BADGE IS INFORMATION, NEVER A CONTROL (#2419, the owner
/// 2026-11-13): it keeps only Following and Friends. Someone the viewer
/// doesn't follow, or asked, wears no badge, and the pill offers no follow:
/// until #2409's Follow, the full-screen page follows from the profile. Every
/// change of badge is drawn IN PLACE, as the badge's symbol replace and
/// nothing else (#925): the item and its identifier never change, and the
/// pill is never blurred for it.
///
/// The graph is GATED (`SnapAuthorFollowStoreTests`' shape): every lookup and
/// follow waits until the test answers it, and every wait is a bounded run of
/// yields on the main actor — never the clock.
@MainActor
struct SnapAuthorFollowTests {
    /// Lets the store's tasks, the graph's gates and the main-queue delivery
    /// of graph events move — bounded, and never on the clock. Everything
    /// involved runs on the main actor, so a yield always lets it through.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    private static func feed(
        graph: GatedFollowGraph? = GatedFollowGraph(), readable: Bool = true,
        events: FollowGraphEvents? = nil
    ) -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider(), unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph,
            followRelations: readable ? graph : nil,
            followEvents: events,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
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

    /// An unknown relation is the skeleton's badge (#2098), under the slot's
    /// one identifier.
    @Test func anAuthorWhoseRelationIsUnknownWearsTheSkeleton() throws {
        let feed = Self.feed()
        feed.authorBar.showAuthor(Self.model(authorID: "prof-1"))

        #expect(try Self.pill(feed).followBadge == .loading)
        #expect(try Self.authorItem(feed).identifier == SnapToolbarComposer.authorItemIdentifier(for: nil))
    }

    /// Each relation draws its badge: Following and Friends only.
    @Test(arguments: [
        (FollowRelation.notFollowing, SnapAuthorIdentityView.FollowBadge.none),
        (.followedBy, .none),
        (.following, .following),
        (.mutual, .friends),
        (.viewer, .none),
        (.blocked, .none),
        (.requested, .none),
    ])
    func eachRelationDrawsItsOwnBadge(
        _ relation: FollowRelation, _ badge: SnapAuthorIdentityView.FollowBadge
    ) throws {
        let feed = Self.feed()
        feed.followStore.setRelation(relation, for: ProfileID("prof-2"))
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).followBadge == badge)
        #expect(try Self.pill(feed).drawnBadgeSymbol == badge.symbolName, "the avatar wears another symbol")
        #expect(try Self.authorItem(feed).identifier == SnapToolbarComposer.authorItemIdentifier(for: nil))
    }

    /// The badge's symbols are the owner's (#925): a check once followed, two
    /// people for friends, and nothing otherwise.
    @Test func eachBadgeWearsItsSymbol() {
        typealias Badge = SnapAuthorIdentityView.FollowBadge
        #expect(Badge.following.symbolName == "checkmark.circle.fill")
        #expect(Badge.friends.symbolName == "person.2.fill")
        #expect(Badge.none.symbolName == nil)
        #expect(Badge.loading.symbolName == nil)
        for name in [Badge.following, .friends].compactMap(\.symbolName) {
            #expect(UIImage(systemName: name) != nil, "\(name) is not a system symbol")
        }
    }

    /// The answer arriving for the author ON the pill re-draws its badge — in
    /// the same item, so the glass does not morph.
    @Test func theGraphsAnswerDrawsTheBadgeInPlace() async throws {
        let graph = GatedFollowGraph()
        let feed = Self.feed(graph: graph)
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))
        let before = try Self.authorItem(feed)

        feed.followStore.resolve(for: ProfileID("prof-2"))
        await Self.settle { graph.pendingLookups == 1 }
        #expect(graph.lookups == [ProfileID("prof-2")])
        graph.answerLookup(.following)
        await Self.settle { (try? Self.pill(feed).followBadge) == .following }

        let after = try Self.authorItem(feed)
        #expect(after === before, "a new item for a badge: iOS 26 morphs the glass between them")
        #expect(after.identifier == SnapToolbarComposer.authorItemIdentifier(for: nil))
        #expect(try Self.pill(feed).followBadge == .following)
    }

    /// Paging re-evaluates: the badge belongs to the author, not to the pill.
    @Test func pagingToAnotherAuthorReEvaluatesTheBadge() throws {
        let feed = Self.feed()
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.followStore.setRelation(.following, for: ProfileID("prof-1"))

        feed.authorBar.showAuthor(Self.model(id: "p1", authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .none)
        feed.authorBar.showAuthor(Self.model(id: "p2", authorID: "prof-1"))
        #expect(try Self.pill(feed).followBadge == .following)
        feed.authorBar.showAuthor(Self.model(id: "p3", authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .none)
    }

    /// A feed on screen in a window, wearing `relation`'s badge for "prof-2"
    /// once the first author's own swap has landed.
    private static func onScreenFeed(
        graph: GatedFollowGraph, relation: FollowRelation
    ) async throws -> (SnapFeedViewController, SnapAuthorIdentityView, UIWindow) {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider(), unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph, followRelations: graph,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()
        feed.followStore.setRelation(relation, for: ProfileID("prof-2"))
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))
        let pill = try Self.pill(feed)
        // The landing install re-mints the item under the author's identifier
        // (#1791): what a test then holds is the item the screen keeps.
        let landed = SnapToolbarComposer.authorItemIdentifier(for: ProfileID("prof-2"))
        for _ in 0..<300 where pill.isRedrawingWholePill || (try? Self.authorItem(feed))?.identifier != landed {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (feed, pill, window)
    }

    /// ⚠️ NO BADGE → A BADGE IS ONE SYMBOL REPLACE (#925, #2419): a relation
    /// that turns into a friendship on screen grows the badge in by the
    /// symbol's replace, in the same item, the pill never blurred; and the
    /// reverse shrinks it out by one more.
    @Test func aBadgeArrivingOrLeavingIsOneReplace() async throws {
        let graph = GatedFollowGraph()
        let (feed, pill, window) = try await Self.onScreenFeed(graph: graph, relation: .followedBy)
        defer { window.isHidden = true }
        #expect(pill.window != nil, "the pill is not on screen: nothing to prove")
        #expect(pill.drawnBadgeSymbol == nil)
        let item = try Self.authorItem(feed)
        let replaces = pill.badgeReplaceCount

        feed.followStore.resolve(for: ProfileID("prof-2"), refresh: true)
        await Self.settle { graph.pendingLookups == 1 }
        graph.answerLookup(.mutual)
        await Self.settle { pill.followBadge == .friends }
        #expect(pill.drawnBadgeSymbol == "person.2.fill")
        #expect(pill.badgeReplaceCount == replaces + 1, "the badge arrived without its symbol replace")
        #expect(!pill.isRedrawingWholePill, "the badge's arrival blurred the whole pill")
        #expect(try Self.authorItem(feed) === item)

        feed.followStore.setRelation(.followedBy, for: ProfileID("prof-2"))
        #expect(pill.followBadge == .none)
        #expect(pill.badgeReplaceCount == replaces + 2, "the badge left without its symbol replace")
        #expect(!pill.isRedrawingWholePill)
    }

    /// PASSIVE (#2419): the badge takes no touch and no Follow is offered to
    /// VoiceOver; the pill is ONE element (#1277) saying "Name, @handle,
    /// Following".
    @Test(arguments: [SnapAuthorIdentityView.FollowBadge.none, .following, .friends])
    func theBadgeIsPassive(_ badge: SnapAuthorIdentityView.FollowBadge) throws {
        let host = SnapAuthorIdentityView()
        host.setPerson(id: ProfileID("prof-2"), name: "Ava Moreau", meta: "@ava", avatarURL: nil,
                       pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), animated: true)
        host.setFollowBadge(badge)
        let glyph = try #require(Self.badgeView(in: host))
        let pill = try #require(Self.personPill(in: host))

        #expect(glyph.isAccessibilityElement == false, "the badge is read with the pill")
        #expect(glyph.isUserInteractionEnabled == false)
        #expect(pill.isAccessibilityElement)
        let words = ["Ava Moreau", "@ava", badge.accessibilityLabel].compactMap { $0 }.joined(separator: ", ")
        #expect(pill.accessibilityLabel == words)
        #expect(pill.accessibilityCustomActions?.isEmpty ?? true, "the badge offers an action")
    }

    private static func personPill(in view: UIView) -> PersonPill? {
        for sub in view.subviews {
            if let pill = sub as? PersonPill { return pill }
            if let found = personPill(in: sub) { return found }
        }
        return nil
    }

    private static func badgeView(in view: UIView) -> RelationBadgeView? {
        for sub in view.subviews {
            if let badge = sub as? RelationBadgeView { return badge }
            if let found = badgeView(in: sub) { return found }
        }
        return nil
    }

    /// A follow accepted ELSEWHERE — on the author's own profile — draws the
    /// check, and an unfollow elsewhere takes it away: the pill and the
    /// profile's button never disagree.
    @Test func aFollowOrUnfollowMadeElsewhereReachesThePill() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .none)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        await Self.settle { (try? Self.pill(feed).followBadge) == .following }
        #expect(try Self.pill(feed).followBadge == .following)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        await Self.settle { (try? Self.pill(feed).followBadge) == SnapAuthorIdentityView.FollowBadge.none }
        #expect(try Self.pill(feed).followBadge == .none)
    }

    /// A friend unfollowed elsewhere still follows the viewer: the badge
    /// goes, and following again from anywhere makes a friend again.
    @Test func aFriendUnfollowedElsewhereStillFollowsTheViewer() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.followStore.setRelation(.mutual, for: ProfileID("prof-2"))
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .friends)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        await Self.settle { (try? Self.pill(feed).followBadge) == SnapAuthorIdentityView.FollowBadge.none }
        #expect(try Self.pill(feed).followBadge == .none)
        #expect(feed.followStore.relation(for: ProfileID("prof-2")) == .followedBy)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        await Self.settle { (try? Self.pill(feed).followBadge) == .friends }
        #expect(try Self.pill(feed).followBadge == .friends)
    }

    /// An unfollow does not make the viewer themself, or someone they block,
    /// followable.
    @Test func anUnfollowElsewhereLeavesTheViewerAndTheBlockedAlone() async {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.followStore.setRelation(.viewer, for: ProfileID("me"))
        feed.followStore.setRelation(.blocked, for: ProfileID("prof-3"))

        events.publish(FollowChange(profileID: ProfileID("me"), isFollowing: false))
        events.publish(FollowChange(profileID: ProfileID("prof-3"), isFollowing: false))
        // Delivery keeps publication order: once a later change has landed,
        // both of these have been heard — no clock to outwait.
        events.publish(FollowChange(profileID: ProfileID("prof-4"), isFollowing: true))
        await Self.settle { feed.followStore.relation(for: ProfileID("prof-4")) != nil }
        #expect(feed.followStore.relation(for: ProfileID("prof-4")) == .following, "the events were never heard")

        #expect(feed.followStore.relation(for: ProfileID("me")) == .viewer)
        #expect(feed.followStore.relation(for: ProfileID("prof-3")) == .blocked)
    }

    /// Nothing to follow THROUGH, no relation drawn.
    @Test func withoutAFollowSeamThereIsNoBadge() throws {
        let feed = Self.feed(graph: nil)
        feed.followStore.setRelation(.following, for: ProfileID("prof-2"))
        feed.authorBar.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).followBadge == .none)
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
            viewModel: FeedViewModel(repository: FollowFeedProvider(), unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
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

/// A follow graph whose every lookup and follow waits for the test's answer,
/// recording what it is asked.
///
/// On the main actor, like the screen, its store and the tests: a gate is
/// reached and answered on one serial executor, so a few yields always let it
/// move — nothing waits on the shared cooperative pool.
@MainActor
private final class GatedFollowGraph: SocialGraphReading, SocialGraphWriting {
    private var lookupGates: [CheckedContinuation<FollowRelation, any Error>] = []
    private var followGates: [CheckedContinuation<Void, any Error>] = []
    private(set) var lookups: [ProfileID] = []
    private(set) var follows: [ProfileID] = []
    /// What an accepted follow did: `.requested` is a private account (#968).
    var outcome: FollowOutcome = .following

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

    func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
        try await setFollowing(true, for: profileID)
        return outcome
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
