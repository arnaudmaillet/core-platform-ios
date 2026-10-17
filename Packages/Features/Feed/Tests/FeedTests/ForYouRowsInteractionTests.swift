import CoreModels
import DesignSystem
import EmoteKit
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// How For You's rows answer a finger (2026-09-29 follow-up): the headers push
/// through their OWN tap path, a long press lifts a preview whose commit opens
/// what a tap would, "For you ›" titles the list and pushes Discover's whole
/// mosaic (2026-10-01), the Friends row holds its
/// order while the viewer is on the screen, and a card's caption animates its
/// emotes.
@MainActor
struct ForYouRowsInteractionTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func post(_ id: String, by author: String, kind: GalleryPost.Kind = .photo) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID(author), authorName: author.capitalized, authorHandle: author
        )
    }

    private func story(_ author: String, unseen: Bool) -> ForYouViewModel.FriendStory {
        ForYouViewModel.FriendStory(
            authorID: ProfileID(author), name: author.capitalized, handle: author, avatarURL: nil,
            posts: [post("\(author)-1", by: author)], hasUnseen: unseen
        )
    }

    private func makeLead() -> ForYouLeadFixture {
        let lead = ForYouLeadFixture(pipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil)
        lead.stack.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        return lead
    }

    private func railsState(
        friends: [ForYouViewModel.FriendStory], following: [GalleryPost] = []
    ) -> ForYouViewModel.Rails {
        var state = ForYouViewModel.Rails()
        state.friends = friends
        state.following = following
        return state
    }

    // MARK: - Headers

    /// The headers push through the bar's own recogniser — #312's chevron was
    /// dead on device while its test, calling the host's closure, passed.
    @Test func eachRowHeaderPushesItsList() {
        let lead = makeLead()
        var pushed: [String] = []
        lead.friends.onTitleTapped = { pushed.append("friends") }
        lead.shelf.onTitleTapped = { pushed.append("following") }
        lead.stack.onListTitleTapped = { pushed.append("for you") }
        lead.render(railsState(friends: [story("ana", unseen: true)], following: [post("c", by: "bo")]))
        lead.friends.debugTapTitle()
        lead.shelf.debugTapTitle()
        lead.stack.debugListTitleView.debugTap()
        #expect(pushed == ["friends", "following", "for you"])
    }

    /// "For you ›" pushes Discover's whole mosaic — the very screen a chunk's
    /// "View all" pushes, through the same entry point (asked for 2026-10-01).
    /// Through the heading's OWN recogniser and the screen's real wiring, so a
    /// heading drawn with a chevron but wired to nothing fails here.
    @Test func theForYouHeadingPushesTheGalleryViewAllPushes() {
        func pushed(by press: (ForYouViewController) -> Void) -> UIViewController? {
            let screen = ForYouViewController(
                viewModel: ForYouViewModel(repository: EmptyForYouProvider()),
                imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
                makeSnapFeed: { _, _ in UIViewController() },
                prewarm: { _ in }
            )
            let nav = UINavigationController(rootViewController: screen)
            screen.loadViewIfNeeded()
            press(screen)
            return nav.topViewController
        }
        let byHeading = pushed { $0.debugLead.debugListTitleView.debugTap() }
        let byViewAll = pushed { $0.debugPressViewAll() }
        #expect(byHeading is DiscoverGalleryViewController)
        #expect(byViewAll is DiscoverGalleryViewController)
        #expect(byHeading?.hidesBottomBarWhenPushed == true, "the gallery pushes without the tab bar")
    }

    /// "For you" under the rows — and nothing at all without rows.
    @Test func forYouTitlesTheListUnderTheRows() {
        let lead = makeLead()
        lead.render(railsState(friends: []))
        lead.stack.layoutIfNeeded()
        #expect(lead.stack.debugListTitleView.isHidden)
        #expect(ForYouLeadFixture.height(forWidth: 393, friends: 0, following: 0) == 0)

        lead.render(railsState(friends: [story("ana", unseen: false)]))
        lead.stack.layoutIfNeeded()
        #expect(!lead.stack.debugListTitleView.isHidden)
        let rowsOnly = SectionTitleView.Metrics.height + LeadRowMetrics.storySize(forWidth: 393).height
        #expect(ForYouLeadFixture.height(forWidth: 393, friends: 1, following: 0)
                >= rowsOnly + SectionTitleView.Metrics.height, "room for the title")
    }

    /// The three titles are the app's ONE section title (2026-09-30):
    /// `Friends 2 ›` with the count as secondary text, `For you ›` a link
    /// with no count (2026-10-01) — every one standing `SectionTitleView.Metrics.surfaceInset`
    /// from the list's edge, the same line the pushed lists' and the sound
    /// sheet's titles stand on.
    @Test func theRowTitlesAreTheAppsSectionTitle() {
        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let lead = makeLead()
        list.addSubview(lead.stack)
        var state = railsState(
            friends: [story("ana", unseen: true)], following: [post("p1", by: "bo"), post("p2", by: "cy")]
        )
        state.friendsBadge = 2
        lead.render(state)
        lead.stack.layoutIfNeeded()
        let headers = [lead.friends.header, lead.shelf.header, lead.stack.debugListTitleView]
        for header in headers { header.layoutIfNeeded() }
        #expect(headers.map(\.debugTitleText) == ["Friends", "Following", "For you"])
        #expect(headers.map(\.debugCountText) == ["2", nil, nil])
        #expect(headers.map(\.debugShowsChevron) == [true, true, true])
        for header in headers {
            let x = header.convert(header.debugFrames.title, to: list).minX
            #expect(abs(x - SectionTitleView.Metrics.surfaceInset) < 0.5, "\(header.debugTitleText ?? "") at \(x)")
        }
        let friends = headers[0].debugFrames
        #expect(abs(friends.count.minX - friends.title.maxX - SectionTitleView.Metrics.titleToCount) < 0.5)
        #expect(abs(friends.chevron.minX - friends.count.maxX - SectionTitleView.Metrics.countToChevron) < 0.5)
        #expect(headers[0].accessibilityValue == "2 new")
        // "For you ›": the chevron a word space after the title, as on a row
        // header with nothing new.
        let forYou = headers[2].debugFrames
        #expect(abs(forYou.chevron.minX - forYou.title.maxX - SectionTitleView.Metrics.titleToChevron) < 0.5)
        #expect(headers[2].accessibilityTraits.contains(.button))
    }

    // MARK: - Long press

    /// The menu leads with Open, then the host's rows; the preview's commit
    /// opens exactly what a tap on the card opens.
    @Test func aCardsPreviewCommitsToTheCardsOpen() throws {
        let lead = makeLead()
        let cards = [post("c0", by: "bo"), post("c1", by: "cy")]
        lead.render(railsState(friends: [], following: cards))
        lead.shelf.cardMenuElements = { _ in [UIAction(title: "View Profile") { _ in }] }
        #expect(lead.shelf.debugCardMenuTitles(at: 1) == ["Open", "View Profile"])

        var opened: [Int] = []
        lead.shelf.onCardTapped = { opened.append($0) }
        let configuration = try #require(lead.shelf.debugCardMenuConfiguration(at: 1))
        lead.shelf.debugCommitPreview(configuration)
        #expect(opened == [1])
    }

    /// A friend's menu: Open (their posts), then the host's rows.
    @Test func aFriendsMenuOpensTheirPosts() {
        let lead = makeLead()
        lead.render(railsState(friends: [story("ana", unseen: true)]))
        lead.friends.storyMenuElements = { _ in [UIAction(title: "View Profile") { _ in }] }
        #expect(lead.friends.debugStoryMenuTitles(at: 0) == ["Open", "View Profile"])
    }

    @Test func aMenuTargetSurvivesItsIdentifier() {
        let story = RowMenuTarget.story(ProfileID("ana"))
        let card = RowMenuTarget.card(PostID("post:with:colons"))
        #expect(RowMenuTarget(story.identifier) == story)
        #expect(RowMenuTarget(card.identifier) == card)
        #expect(RowMenuTarget("elsewhere" as NSString) == nil)
    }

    /// The preview is sized by the post's shape, held between 2:3 and 16:9.
    @Test func aPreviewTakesThePostsShapeWithinBounds() {
        let portrait = GalleryPost(
            id: PostID("p"), kind: .video, isRepost: false, thumbnailURL: nil,
            aspectRatio: 9.0 / 16.0, caption: "", publishedAtMS: 1
        )
        let size = ForYouPostPreviewViewController.preferredSize(for: portrait, width: 300)
        #expect(size.width == 300)
        #expect(size.height == 450, "a 9:16 clip previews at 2:3")
    }

    // MARK: - The Friends row's held order

    /// The pure merge: known friends keep the order shown, a newcomer keeps
    /// the slot the view model gave them, and one who left goes.
    @Test func holdingKeepsTheShownOrder() {
        let shown = [ProfileID("ana"), ProfileID("bo"), ProfileID("cy")]
        // The view model re-sorted: Ana's ring cleared, so she went last; Dee
        // arrived (a follow-back) and Cy left (an unfollow).
        let fresh = [story("bo", unseen: true), story("dee", unseen: true), story("ana", unseen: false)]
        let held = FriendsStoriesRow.holding(fresh, in: shown)
        #expect(held.map(\.authorID.rawValue) == ["ana", "dee", "bo"])
        #expect(held.first?.hasUnseen == false, "the ring is the fresh one")
    }

    /// On screen, a ring clearing moves nobody; once the viewer has left, the
    /// row takes the view model's order again.
    @Test func theRowReordersOnlyOnceTheViewerLeaves() {
        let lead = makeLead()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(lead.stack)
        lead.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: true)]))
        #expect(lead.friends.debugStoryOrder.map(\.rawValue) == ["ana", "bo"])

        // Ana's posts were watched: the view model puts her after Bo.
        lead.render(railsState(friends: [story("bo", unseen: true), story("ana", unseen: false)]))
        #expect(lead.friends.debugStoryOrder.map(\.rawValue) == ["ana", "bo"], "held while on screen")
        #expect(lead.friends.stories.first?.hasUnseen == false, "but her ring is gone")

        lead.friends.releaseStoryOrder()
        #expect(lead.friends.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
        // Still in the window (the app went to the background): the re-sorted
        // order is the one held from here.
        lead.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: false)]))
        #expect(lead.friends.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
        lead.stack.removeFromSuperview()
    }

    /// Off screen the row follows the view model; nothing has been shown to
    /// hold.
    @Test func anUnshownRowFollowsTheViewModel() {
        let lead = makeLead()
        lead.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: true)]))
        lead.render(railsState(friends: [story("bo", unseen: true), story("ana", unseen: false)]))
        #expect(lead.friends.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
    }

    // MARK: - Playback and emotes

    /// Every card on screen plays — at 2.3 per width, three at most — and the
    /// row plus the list never ask for more than the pool's six.
    @Test func theRowPlaysEveryVisibleCardWithinThePool() {
        #expect(PostShelfSection.concurrentPlayers == 3)
        #expect(LeadRowMetrics.cardsPerWidth < 3)
    }

    /// A card's caption is an `EmoteLabel`, so its emotes animate.
    @Test func aCardsCaptionAnimatesItsEmotes() {
        let overlay = PostShelfMediaCardCell.makeOverlay(
            for: post("c", by: "bo"), restingSize: CGSize(width: 150, height: 200)
        )
        #expect(overlay.subviews.contains { $0 is EmoteLabel })
    }
}

/// Pages nothing — the heading's push needs the screen, not its content.
final class EmptyForYouProvider: ForYouProviding, @unchecked Sendable {
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
}
