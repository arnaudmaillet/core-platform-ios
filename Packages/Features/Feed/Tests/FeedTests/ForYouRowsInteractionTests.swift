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
/// what a tap would, "For you" titles the list, the Friends row holds its
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

    private func makeRails() -> ForYouRailsView {
        let rails = ForYouRailsView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil)
        rails.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        return rails
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
        let rails = makeRails()
        var pushed: [String] = []
        rails.onFriendsHeaderTapped = { pushed.append("friends") }
        rails.onFollowingHeaderTapped = { pushed.append("following") }
        rails.render(railsState(friends: [story("ana", unseen: true)], following: [post("c", by: "bo")]))
        rails.debugTapFriendsHeader()
        rails.debugTapFollowingHeader()
        #expect(pushed == ["friends", "following"])
    }

    /// "For you" under the rows — and nothing at all without rows.
    @Test func forYouTitlesTheListUnderTheRows() {
        let rails = makeRails()
        rails.render(railsState(friends: []))
        rails.layoutIfNeeded()
        #expect(!rails.debugShowsListHeader)
        #expect(ForYouRailsView.height(forWidth: 393, friends: 0, following: 0) == 0)

        rails.render(railsState(friends: [story("ana", unseen: false)]))
        rails.layoutIfNeeded()
        #expect(rails.debugShowsListHeader)
        let rowsOnly = SectionTitleView.Metrics.height + ForYouRailsView.Metrics.storySize(forWidth: 393).height
        #expect(ForYouRailsView.height(forWidth: 393, friends: 1, following: 0)
                >= rowsOnly + SectionTitleView.Metrics.height, "room for the title")
    }

    /// The three titles are the app's ONE section title (2026-09-30):
    /// `Friends 2 ›` with the count as secondary text, "For you" a plain
    /// heading — every one standing `SectionTitleView.Metrics.surfaceInset`
    /// from the list's edge, the same line the pushed lists' and the sound
    /// sheet's titles stand on.
    @Test func theRowTitlesAreTheAppsSectionTitle() {
        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let rails = makeRails()
        list.addSubview(rails)
        var state = railsState(
            friends: [story("ana", unseen: true)], following: [post("p1", by: "bo"), post("p2", by: "cy")]
        )
        state.friendsBadge = 2
        rails.render(state)
        rails.layoutIfNeeded()
        let headers = rails.debugHeaders
        for header in headers { header.layoutIfNeeded() }
        #expect(headers.map(\.debugTitleText) == ["Friends", "Following", "For you"])
        #expect(headers.map(\.debugCountText) == ["2", nil, nil])
        #expect(headers.map(\.debugShowsChevron) == [true, true, false])
        for header in headers {
            let x = header.convert(header.debugFrames.title, to: list).minX
            #expect(abs(x - SectionTitleView.Metrics.surfaceInset) < 0.5, "\(header.debugTitleText ?? "") at \(x)")
        }
        let friends = headers[0].debugFrames
        #expect(abs(friends.count.minX - friends.title.maxX - SectionTitleView.Metrics.titleToCount) < 0.5)
        #expect(abs(friends.chevron.minX - friends.count.maxX - SectionTitleView.Metrics.countToChevron) < 0.5)
        #expect(headers[0].accessibilityValue == "2 new")
    }

    // MARK: - Long press

    /// The menu leads with Open, then the host's rows; the preview's commit
    /// opens exactly what a tap on the card opens.
    @Test func aCardsPreviewCommitsToTheCardsOpen() throws {
        let rails = makeRails()
        let cards = [post("c0", by: "bo"), post("c1", by: "cy")]
        rails.render(railsState(friends: [], following: cards))
        rails.cardMenuElements = { _ in [UIAction(title: "View Profile") { _ in }] }
        #expect(rails.debugCardMenuTitles(at: 1) == ["Open", "View Profile"])

        var opened: [Int] = []
        rails.onCardTapped = { opened.append($0) }
        let configuration = try #require(rails.debugCardMenuConfiguration(at: 1))
        rails.debugCommitPreview(configuration)
        #expect(opened == [1])
    }

    /// A friend's menu: Open (their posts), then the host's rows.
    @Test func aFriendsMenuOpensTheirPosts() {
        let rails = makeRails()
        rails.render(railsState(friends: [story("ana", unseen: true)]))
        rails.storyMenuElements = { _ in [UIAction(title: "View Profile") { _ in }] }
        #expect(rails.debugStoryMenuTitles(at: 0) == ["Open", "View Profile"])
    }

    @Test func aMenuTargetSurvivesItsIdentifier() {
        let story = ForYouRailsView.MenuTarget.story(ProfileID("ana"))
        let card = ForYouRailsView.MenuTarget.card(PostID("post:with:colons"))
        #expect(ForYouRailsView.MenuTarget(story.identifier) == story)
        #expect(ForYouRailsView.MenuTarget(card.identifier) == card)
        #expect(ForYouRailsView.MenuTarget("elsewhere" as NSString) == nil)
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
        let held = ForYouRailsView.holding(fresh, in: shown)
        #expect(held.map(\.authorID.rawValue) == ["ana", "dee", "bo"])
        #expect(held.first?.hasUnseen == false, "the ring is the fresh one")
    }

    /// On screen, a ring clearing moves nobody; once the viewer has left, the
    /// row takes the view model's order again.
    @Test func theRowReordersOnlyOnceTheViewerLeaves() {
        let rails = makeRails()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(rails)
        rails.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: true)]))
        #expect(rails.debugStoryOrder.map(\.rawValue) == ["ana", "bo"])

        // Ana's posts were watched: the view model puts her after Bo.
        rails.render(railsState(friends: [story("bo", unseen: true), story("ana", unseen: false)]))
        #expect(rails.debugStoryOrder.map(\.rawValue) == ["ana", "bo"], "held while on screen")
        #expect(rails.stories.first?.hasUnseen == false, "but her ring is gone")

        rails.releaseStoryOrder()
        #expect(rails.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
        // Still in the window (the app went to the background): the re-sorted
        // order is the one held from here.
        rails.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: false)]))
        #expect(rails.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
        rails.removeFromSuperview()
    }

    /// Off screen the row follows the view model; nothing has been shown to
    /// hold.
    @Test func anUnshownRowFollowsTheViewModel() {
        let rails = makeRails()
        rails.render(railsState(friends: [story("ana", unseen: true), story("bo", unseen: true)]))
        rails.render(railsState(friends: [story("bo", unseen: true), story("ana", unseen: false)]))
        #expect(rails.debugStoryOrder.map(\.rawValue) == ["bo", "ana"])
    }

    // MARK: - Playback and emotes

    /// Every card on screen plays — at 2.3 per width, three at most — and the
    /// row plus the list never ask for more than the pool's six.
    @Test func theRowPlaysEveryVisibleCardWithinThePool() {
        #expect(ForYouRailsView.concurrentPlayers == 3)
        #expect(ForYouRailsView.Metrics.cardsPerWidth < 3)
    }

    /// A card's caption is an `EmoteLabel`, so its emotes animate.
    @Test func aCardsCaptionAnimatesItsEmotes() {
        let overlay = ForYouFollowingCardCell.makeOverlay(
            for: post("c", by: "bo"), restingSize: CGSize(width: 150, height: 200)
        )
        #expect(overlay.subviews.contains { $0 is EmoteLabel })
    }
}
