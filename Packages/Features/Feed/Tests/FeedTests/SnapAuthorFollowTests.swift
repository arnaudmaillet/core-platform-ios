import CoreModels
import DesignSystem
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
/// back. Every change of badge is drawn IN PLACE, as the badge's symbol
/// replace and nothing else (#925): the item and its identifier never change,
/// and the pill is never blurred for it.
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
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier(for: nil))
    }

    @Test(arguments: [FollowRelation.following, .mutual, .viewer, .blocked])
    func anAuthorTheViewerCannotFollowOffersNoFollow(_ relation: FollowRelation) throws {
        let feed = Self.feed()
        feed.followStore.setRelation(relation, for: ProfileID("prof-1"))
        feed.showAuthor(Self.model(authorID: "prof-1"))

        #expect(try Self.pill(feed).offersFollow == false)
    }

    @Test func anAuthorTheViewerDoesNotFollowOffersFollowInTheSameItem() throws {
        let feed = Self.feed()
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).offersFollow)
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier(for: nil))
    }

    /// The answer arriving for the author ON the pill re-draws its badge — in
    /// the same item, so the glass does not morph.
    @Test func theGraphsAnswerDrawsTheFollowInPlace() async throws {
        let graph = GatedFollowGraph()
        let feed = Self.feed(graph: graph)
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let before = try Self.authorItem(feed)
        #expect(try Self.pill(feed).offersFollow == false, "precondition: not known yet")

        feed.followStore.resolve(for: ProfileID("prof-2"))
        await Self.settle { graph.pendingLookups == 1 }
        #expect(graph.lookups == [ProfileID("prof-2")])
        #expect(try Self.pill(feed).offersFollow == false, "nothing is drawn before the graph answers")
        graph.answerLookup(.notFollowing)
        await Self.settle { (try? Self.pill(feed).offersFollow) == true }

        let after = try Self.authorItem(feed)
        #expect(after === before, "a new item for a badge: iOS 26 morphs the glass between them")
        #expect(after.identifier == SnapFeedViewController.authorItemIdentifier(for: nil))
        #expect(try Self.pill(feed).offersFollow)
    }

    /// Paging re-evaluates: the "+" belongs to the author, not to the pill.
    @Test func pagingToAnotherAuthorReEvaluatesTheFollow() throws {
        let feed = Self.feed()
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.followStore.setRelation(.following, for: ProfileID("prof-1"))

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
        let graph = GatedFollowGraph()
        let feed = Self.feed(graph: graph)
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let offered = try Self.authorItem(feed)
        let pill = try Self.pill(feed)

        // Through the pill's own callback, as the button fires it.
        pill.onFollowTapped?(ProfileID("prof-2"))

        let followed = try Self.authorItem(feed)
        #expect(followed === offered)
        #expect(followed.identifier == SnapFeedViewController.authorItemIdentifier(for: nil))
        #expect(try Self.pill(feed).offersFollow == false)
        #expect(try Self.pill(feed).followBadge == .following, "a follow is drawn, not forgotten")
        await Self.settle { graph.pendingFollows == 1 }
        #expect(graph.follows == [ProfileID("prof-2")])
        graph.answerFollow(accepting: true)
        await Self.settle { feed.followStore.followsInFlight.isEmpty }
        #expect(feed.followStore.followsInFlight.isEmpty)
        #expect(feed.followStore.relation(for: ProfileID("prof-2")) == .following)
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
        (.requested, .pending),
    ])
    func eachRelationDrawsItsOwnBadge(
        _ relation: FollowRelation, _ badge: SnapAuthorIdentityView.FollowBadge
    ) throws {
        let feed = Self.feed()
        feed.followStore.setRelation(relation, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        #expect(try Self.pill(feed).followBadge == badge)
        #expect(try Self.pill(feed).drawnBadgeSymbol == badge.symbolName, "the avatar wears another symbol")
        #expect(try Self.authorItem(feed).identifier == SnapFeedViewController.authorItemIdentifier(for: nil))
    }

    /// The badge's symbols are the owner's (#925): "+" to follow, a check
    /// once followed, two people for friends, a clock for a pending request
    /// (#968) — and nothing at all for the viewer or someone blocked.
    @Test func eachBadgeWearsItsSymbol() {
        typealias Badge = SnapAuthorIdentityView.FollowBadge
        #expect(Badge.follow.symbolName == "plus")
        #expect(Badge.following.symbolName == "checkmark.circle.fill")
        #expect(Badge.friends.symbolName == "person.2.fill")
        #expect(Badge.pending.symbolName == "clock.circle.fill")
        #expect(Badge.none.symbolName == nil)
        for name in [Badge.follow, .following, .friends, .pending].compactMap(\.symbolName) {
            #expect(UIImage(systemName: name) != nil, "\(name) is not a system symbol")
        }
    }

    /// ⚠️ A FOLLOW TAP IS A SYMBOL REPLACE, NOTHING ELSE (#925): the "+" on the
    /// avatar becomes the check through SF Symbols' replace, in the same item —
    /// the pill is not blurred out and back in for it (it used to be).
    @Test func aFollowTapReplacesTheBadgeAndNothingElse() async throws {
        let graph = GatedFollowGraph()
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph, followRelations: graph
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let pill = try Self.pill(feed)
        #expect(pill.window != nil, "the pill is not on screen: nothing to prove")
        // The first author's own swap, over the redaction bars, lands first.
        for _ in 0..<300 where pill.isRedrawingWholePill {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!pill.isRedrawingWholePill)
        #expect(pill.drawnBadgeSymbol == "plus")
        let item = try Self.authorItem(feed)
        let replaces = pill.badgeReplaceCount

        feed.followAuthor(ProfileID("prof-2"))

        #expect(pill.drawnBadgeSymbol == "checkmark.circle.fill")
        #expect(pill.badgeReplaceCount == replaces + 1, "the badge changed without its symbol replace")
        #expect(!pill.isRedrawingWholePill, "the follow tap blurred the whole pill")
        #expect(try Self.authorItem(feed) === item, "the follow tap re-minted the item")
        #expect(item.customView === pill)
        await Self.settle { graph.pendingFollows == 1 }
        graph.answerFollow(accepting: true)
        await Self.settle { feed.followStore.followsInFlight.isEmpty }
    }

    /// A feed on screen in a window, wearing `relation`'s badge for "prof-2"
    /// once the first author's own swap has landed.
    private static func onScreenFeed(
        graph: GatedFollowGraph, relation: FollowRelation
    ) async throws -> (SnapFeedViewController, SnapAuthorIdentityView, UIWindow) {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FollowFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph, followRelations: graph
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        window.layoutIfNeeded()
        feed.followStore.setRelation(relation, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        let pill = try Self.pill(feed)
        // The landing install re-mints the item under the author's identifier
        // (#1791): what a test then holds is the item the screen keeps.
        let landed = SnapFeedViewController.authorItemIdentifier(for: ProfileID("prof-2"))
        for _ in 0..<300 where pill.isRedrawingWholePill || (try? Self.authorItem(feed))?.identifier != landed {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (feed, pill, window)
    }

    /// The "+" turning on plays `toggleOn` at the optimistic flip (#1885);
    /// a follow already under way plays nothing.
    @Test func followingFromThePlusPlaysToggleOnOnce() async throws {
        let graph = GatedFollowGraph()
        let (feed, _, window) = try await Self.onScreenFeed(graph: graph, relation: .notFollowing)
        defer { window.isHidden = true }
        let first = HapticRecorder.recording { feed.followAuthor(ProfileID("prof-2")) }
        #expect(first == [.toggleOn])
        let again = HapticRecorder.recording { feed.followAuthor(ProfileID("prof-2")) }
        #expect(again.isEmpty, "a follow under way played \(again)")
        await Self.settle { graph.pendingFollows == 1 }
        graph.answerFollow(accepting: true)
        await Self.settle { feed.followStore.followsInFlight.isEmpty }
    }

    /// ⚠️ A FOLLOW ON A PRIVATE ACCOUNT ENDS ON THE PENDING MARK, BY SYMBOL
    /// REPLACES ONLY (#968). The pill cannot know the account is private
    /// before the graph answers, so the "+" is replaced by the optimistic
    /// check, and the check by the clock once the graph says it only asked —
    /// two replaces, the pill never blurred, the item never re-minted. It
    /// used to stay on the check: a request drawn as a follow.
    @Test func aFollowOnAPrivateAccountReplacesThePlusWithThePendingMark() async throws {
        let graph = GatedFollowGraph()
        graph.outcome = .requested
        let (feed, pill, window) = try await Self.onScreenFeed(graph: graph, relation: .notFollowing)
        defer { window.isHidden = true }
        #expect(pill.window != nil, "the pill is not on screen: nothing to prove")
        #expect(!pill.isRedrawingWholePill)
        #expect(pill.drawnBadgeSymbol == "plus")
        let item = try Self.authorItem(feed)
        let replaces = pill.badgeReplaceCount

        feed.followAuthor(ProfileID("prof-2"))
        #expect(pill.badgeReplaceCount == replaces + 1)
        #expect(!pill.isRedrawingWholePill, "the follow tap blurred the whole pill")
        await Self.settle { graph.pendingFollows == 1 }
        graph.answerFollow(accepting: true)
        await Self.settle { feed.followStore.followsInFlight.isEmpty && pill.followBadge == .pending }

        #expect(feed.followStore.relation(for: ProfileID("prof-2")) == .requested)
        #expect(pill.followBadge == .pending)
        #expect(pill.drawnBadgeSymbol == "clock.circle.fill")
        #expect(pill.badgeReplaceCount == replaces + 2, "plus → pending was not drawn by symbol replaces alone")
        #expect(!pill.isRedrawingWholePill, "the request blurred the whole pill")
        #expect(try Self.authorItem(feed) === item, "the request re-minted the item")
        #expect(!pill.offersFollow, "a pending request offered the + again")
    }

    /// ⚠️ A REQUEST REFUSED OR WITHDRAWN PUTS THE "+" BACK BY ONE SYMBOL
    /// REPLACE (#968): the relation read that lands after it (the screen
    /// re-reads on appearance) says the viewer does not follow them, and the
    /// clock is replaced by the "+", nothing else moving.
    @Test func aRequestRefusedOrWithdrawnPutsThePlusBackByOneReplace() async throws {
        let graph = GatedFollowGraph()
        let (feed, pill, window) = try await Self.onScreenFeed(graph: graph, relation: .requested)
        defer { window.isHidden = true }
        #expect(pill.window != nil, "the pill is not on screen: nothing to prove")
        #expect(pill.drawnBadgeSymbol == "clock.circle.fill")
        let item = try Self.authorItem(feed)
        let replaces = pill.badgeReplaceCount

        feed.followStore.resolve(for: ProfileID("prof-2"), refresh: true)
        await Self.settle { graph.pendingLookups == 1 }
        graph.answerLookup(.notFollowing)
        await Self.settle { pill.followBadge == .follow }

        #expect(pill.drawnBadgeSymbol == "plus")
        #expect(pill.badgeReplaceCount == replaces + 1, "pending → plus was not one symbol replace")
        #expect(!pill.isRedrawingWholePill, "pending → plus blurred the whole pill")
        #expect(try Self.authorItem(feed) === item)
        #expect(pill.offersFollow)
    }

    /// Following someone who already follows the viewer makes a FRIEND, and
    /// the optimistic draw says so at once.
    @Test func followingBackDrawsTheFriendsMark() async throws {
        let graph = GatedFollowGraph()
        let feed = Self.feed(graph: graph)
        feed.followStore.setRelation(.followedBy, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow, "following back is a follow")

        feed.followAuthor(ProfileID("prof-2"))

        #expect(try Self.pill(feed).followBadge == .friends)
        #expect(feed.followStore.relation(for: ProfileID("prof-2")) == .mutual)
        await Self.settle { graph.pendingFollows == 1 }
        #expect(graph.follows == [ProfileID("prof-2")])
        graph.answerFollow(accepting: true)
        await Self.settle { feed.followStore.followsInFlight.isEmpty }
        #expect(feed.followStore.relation(for: ProfileID("prof-2")) == .mutual)
    }

    /// A state mark is not an action: it takes no touch, so a tap on it is a
    /// tap on the pill (the profile), and it never follows.
    ///
    /// VOICEOVER READS ONE ELEMENT (#1277): the pill says "Name, @handle,
    /// Following"; the "+" is the pill's "Follow" custom action, not a
    /// separate tiny target.
    @Test(arguments: [SnapAuthorIdentityView.FollowBadge.following, .friends, .pending])
    func aStateMarkTakesNoTap(_ badge: SnapAuthorIdentityView.FollowBadge) throws {
        let host = SnapAuthorIdentityView()
        host.setPerson(id: ProfileID("prof-2"), name: "Ava Moreau", meta: "@ava", avatarURL: nil,
                       pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        host.setFollowBadge(badge)
        let glyph = try #require(Self.badgeButton(in: host))
        let pill = try #require(Self.personPill(in: host))

        #expect(glyph.isAccessibilityElement == false, "the badge is read with the pill")
        #expect(glyph.isUserInteractionEnabled == false)
        #expect(pill.isAccessibilityElement)
        #expect(pill.accessibilityLabel == "Ava Moreau, @ava, \(badge.accessibilityLabel ?? "")")
        #expect(pill.accessibilityCustomActions == nil, "a state mark offers no action")

        var followed: [ProfileID] = []
        host.onFollowTapped = { followed.append($0) }
        host.setFollowBadge(.follow)
        #expect(glyph.isUserInteractionEnabled, "the \"+\" is the one badge that acts")
        #expect(pill.accessibilityLabel == "Ava Moreau, @ava")
        let action = try #require(pill.accessibilityCustomActions?.first)
        #expect(action.name == "Follow")
        _ = action.actionHandler?(action)
        #expect(followed == [ProfileID("prof-2")], "the custom action did not follow")

        host.setFollowBadge(.none)
        #expect(host.drawnBadgeSymbol == nil)
        #expect(glyph.isUserInteractionEnabled == false)
        #expect(pill.accessibilityCustomActions == nil)
    }

    private static func personPill(in view: UIView) -> PersonPill? {
        for sub in view.subviews {
            if let pill = sub as? PersonPill { return pill }
            if let found = personPill(in: sub) { return found }
        }
        return nil
    }

    private static func badgeButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let button = sub as? UIButton { return button }
            if let found = badgeButton(in: sub) { return found }
        }
        return nil
    }

    /// A refused follow puts the "+" back — and says so (#802), in a failure
    /// toast naming the author.
    @Test func aRefusedFollowBringsTheFollowBackAndSaysSo() async throws {
        let graph = GatedFollowGraph()
        let feed = Self.feed(graph: graph)
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))

        feed.followAuthor(ProfileID("prof-2"))
        #expect(try Self.pill(feed).offersFollow == false)
        await Self.settle { graph.pendingFollows == 1 }
        #expect(try Self.pill(feed).offersFollow == false, "the \"+\" came back before the graph answered")
        #expect(Self.toast(in: feed.view) == nil, "the failure was said before the graph answered")
        #expect(feed.debugFollowFailureToastsShown == 0, "the failure was said before the graph answered")
        graph.answerFollow(accepting: false)
        await Self.settle { (try? Self.pill(feed).offersFollow) == true }
        #expect(try Self.pill(feed).offersFollow)
        // Counted on ARRIVAL (#1979): the toast is gone after a few seconds,
        // and a starved runner looked for it once, too late.
        await Self.settle { feed.debugFollowFailureToastsShown == 1 }
        #expect(feed.debugFollowFailureToastsShown == 1, "the refused follow was silent")
        if let toast = Self.toast(in: feed.view) { #expect(toast.style == .failure) }
    }

    /// The failure names the author by the model's handle, never by parsing
    /// the meta line; a model with none falls back to the display name.
    @Test func aFollowFailureNamesTheAuthorByTheModelsHandle() {
        let named = FeedItemDisplayModel(
            id: PostID("p"), authorID: ProfileID("a"), authorName: "Ava", metaText: "2h",
            avatarURL: nil, caption: nil, mediaURL: nil, mediaKind: .image, thumbnailURL: nil,
            audioText: nil, authorHandle: "ava"
        )
        #expect(SnapFeedViewController.followName(of: named) == "@ava")
        #expect(SnapFeedViewController.followName(of: Self.model(authorID: "bo")) == "Name bo")
    }

    private static func toast(in view: UIView) -> ToastView? {
        if let toast = view as? ToastView { return toast }
        return view.subviews.lazy.compactMap { toast(in: $0) }.first
    }

    /// A follow accepted ELSEWHERE — on the author's own profile — takes the
    /// "+" away, and an unfollow elsewhere brings it back: the pill and the
    /// profile's button never disagree.
    @Test func aFollowOrUnfollowMadeElsewhereReachesThePill() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).offersFollow)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: true))
        await Self.settle { (try? Self.pill(feed).offersFollow) == false }
        #expect(try Self.pill(feed).offersFollow == false)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        await Self.settle { (try? Self.pill(feed).offersFollow) == true }
        #expect(try Self.pill(feed).offersFollow)
    }

    /// A friend unfollowed elsewhere still follows the viewer: the "+" comes
    /// back, and following again from anywhere makes a friend again.
    @Test func aFriendUnfollowedElsewhereStillFollowsTheViewer() async throws {
        let events = FollowGraphEvents()
        let feed = Self.feed(events: events)
        feed.followStore.setRelation(.mutual, for: ProfileID("prof-2"))
        feed.showAuthor(Self.model(authorID: "prof-2"))
        #expect(try Self.pill(feed).followBadge == .friends)

        events.publish(FollowChange(profileID: ProfileID("prof-2"), isFollowing: false))
        await Self.settle { (try? Self.pill(feed).followBadge) == .follow }
        #expect(try Self.pill(feed).followBadge == .follow)
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

    /// Nothing to follow THROUGH, nothing offered — an action that cannot act
    /// is not drawn.
    @Test func withoutAFollowSeamThereIsNoFollow() throws {
        let feed = Self.feed(graph: nil)
        feed.followStore.setRelation(.notFollowing, for: ProfileID("prof-2"))
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
