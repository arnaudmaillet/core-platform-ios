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
        lead.shelf.onViewAll = { pushed.append("following") }
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

    /// The post menu (#1498 §3): the post's rows, then the host's about the
    /// author under "@handle", with no "Open"; the preview's commit opens
    /// exactly what a tap on the card opens.
    @Test func aCardsPreviewCommitsToTheCardsOpen() throws {
        let lead = makeLead()
        let cards = [post("c0", by: "bo"), post("c1", by: "cy")]
        lead.render(railsState(friends: [], following: cards))
        lead.shelf.cardAuthorMenuActions = { _, _ in [.viewProfile {}] }
        let titles = lead.shelf.debugCardMenuTitles(at: 1)
        #expect(!titles.contains("Open"))
        #expect(titles.contains("Comment") && titles.contains("Share"))
        #expect(titles.last?.hasPrefix("@") == true, "the author's rows are not under their handle")

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

    /// ⚠️ #1794: a dismissed Friends lift lands on the face it came from, in
    /// an outline Core Animation can morph from the menu's platter — a rounded
    /// rect like the platter's. The face's super-ellipse, a polygon, could not
    /// morph: the outline jumped to a face-sized tile at the platter's
    /// top-left and flew to the face from there.
    @Test func aDismissedFriendsPreviewLandsOnTheFaceInAMorphableOutline() throws {
        let lead = makeLead()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(lead.stack)
        defer { lead.stack.removeFromSuperview() }
        lead.render(railsState(friends: [
            story("ana", unseen: true), story("bo", unseen: true), story("cy", unseen: false),
        ]))
        lead.layout()
        lead.friends.storiesView.layoutIfNeeded()

        let preview = try #require(lead.friends.debugDismissalPreview(at: 1))
        let cell = try #require(lead.friends.storiesView.cellForItem(at: IndexPath(item: 1, section: 0)) as? ForYouStoryCell)
        let face = cell.discFrame(in: lead.friends, restingBelow: lead.friends.storiesView)
        #expect(preview.target.container === lead.friends)
        #expect(abs(preview.target.center.x - face.midX) < 0.5 && abs(preview.target.center.y - face.midY) < 0.5)

        let outline = try #require(preview.parameters.visiblePath)
        let side = cell.faceView.bounds.width
        let platterLike = UIBezierPath(
            roundedRect: cell.faceView.bounds,
            cornerRadius: ForYouStoryCell.Metrics.faceShape.cornerRadius(side: side)
        )
        #expect(outline.bounds.size == cell.faceView.bounds.size)
        #expect(Self.elementCount(outline) == Self.elementCount(platterLike), "an outline Core Animation cannot morph")
    }

    private static func elementCount(_ path: UIBezierPath) -> Int {
        var count = 0
        path.cgPath.applyWithBlock { _ in count += 1 }
        return count
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

/// The long press's preview of a picture (#1498, the owner 2026-10-20): the
/// card's author band at card size over the media's foot, the likes at its
/// trailing end, the caption's lines above it.
@MainActor
struct PreviewAuthorBandTests {
    private static func photo(likes: Int64? = 123, caption: String = "Quiet morning, notes and a long walk before work") -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/p.jpg"),
            aspectRatio: 3.0 / 4.0, caption: caption, publishedAtMS: 1,
            authorID: ProfileID("marcus"), authorName: "Marcus Holt", authorHandle: "marcus.holt",
            reactionCount: likes
        )
    }

    private func laidOut(_ post: GalleryPost) -> ForYouPostPreviewViewController {
        let preview = ForYouPostPreviewViewController(
            post: post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), width: 360
        )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(origin: .zero, size: preview.preferredContentSize)
        preview.view.layoutIfNeeded()
        return preview
    }

    @Test func thePicturesAuthorIsTheCardsBandWithItsLikes() {
        let preview = laidOut(Self.photo())
        let band = preview.debugBand
        let size = preview.view.bounds.size
        #expect(band.superview === preview.view)
        #expect(band.frame.height == PostAuthorBandView.avatarDiameter, "not the card's band size: \(band.frame)")
        #expect(abs(band.frame.maxY - (size.height - ForYouPostPreviewViewController.footInset)) < 0.5, "not on the media's foot")
        #expect(band.overrideUserInterfaceStyle == .dark, "the band's ink is not light over the picture")

        let likes = preview.debugLikes
        #expect(!likes.isHidden && likes.postLikeCount == 123)
        #expect(likes.frame.maxX <= size.width - ForYouPostPreviewViewController.footInset + 0.5, "the likes are not trailing")
        #expect(band.frame.maxX <= likes.frame.minX, "the band runs under the likes")
        #expect(abs(likes.frame.midY - band.frame.midY) < 0.5, "the likes do not close the band's line")

        let caption = preview.debugCaption
        #expect(!caption.isHidden && caption.frame.maxY <= band.frame.minY, "the caption is not above the author")
        #expect(caption.numberOfLines == PostCardCaptionOverlay.mediaCaptionLines)
        #expect(!preview.view.subviews.contains { $0 is PostCardCaptionOverlay }, "the small author line came back")
    }

    /// No caption: the band alone; no count: no likes.
    @Test func withoutCaptionOrCountTheBandStandsAlone() {
        let preview = laidOut(Self.photo(likes: nil, caption: ""))
        #expect(preview.debugCaption.isHidden)
        #expect(preview.debugLikes.isHidden)
        #expect(abs(preview.debugBand.frame.maxX - (preview.view.bounds.width - ForYouPostPreviewViewController.footInset)) < 0.5)
    }

    /// A text post's preview is its own (`TextCardPreviewTests`): no media
    /// foot, no card overlay.
    @Test func aTextPostHasItsOwnPreview() {
        let text = GalleryPost(id: PostID("t"), kind: .text, isRepost: false, thumbnailURL: nil, caption: "Words", publishedAtMS: 1)
        let preview = laidOut(text)
        #expect(preview.debugTextCard != nil)
        #expect(!preview.view.subviews.contains { $0 is PostCardCaptionOverlay })
        #expect(preview.debugBand.superview == nil)
    }
}

/// A text card's long press (#1498, the owner 2026-10-20): the author band,
/// the caption, then the top comments that fit, in the post screen's rows.
@MainActor
struct TextCardPreviewTests {
    private static let text = GalleryPost(
        id: PostID("t"), kind: .text, isRepost: false, thumbnailURL: nil,
        caption: "Third coffee. Still deciding whether the rewrite was a good idea.",
        publishedAtMS: Int64(Date().timeIntervalSince1970 * 1000),
        authorID: ProfileID("yuki"), authorName: "Yuki Shirakawa", authorHandle: "yuki.snow", reactionCount: 234
    )

    private static func comment(_ index: Int, reply: Bool = false) -> CommentEntry {
        CommentEntry(
            id: "c\(index)", authorID: ProfileID("a\(index)"), authorName: "Kenji \(index)", authorHandle: "k\(index)",
            body: "The second one \(index)", createdAt: Date().addingTimeInterval(-600),
            parentID: reply ? "c0" : nil
        )
    }

    private func preview(comments: [CommentEntry]) -> ForYouPostPreviewViewController {
        let preview = ForYouPostPreviewViewController(
            post: Self.text, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), width: 360, comments: comments
        )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(origin: .zero, size: preview.preferredContentSize)
        return preview
    }

    /// No comments: the band and the caption alone, the lift sized to them.
    @Test func withoutCommentsTheCaptionAlone() throws {
        let preview = preview(comments: [])
        let card = try #require(preview.debugTextCard)
        #expect(card.rows.isEmpty)
        #expect(card.band.superview === preview.view && card.caption.superview === preview.view)
        #expect(card.rule.superview == nil)
        #expect(card.caption.frame.minY >= card.band.frame.maxY, "the caption is not under the band")
        #expect(preview.preferredContentSize.height < 360 * TextCardPreview.maxHeightShare, "the lift did not fit its words")
        #expect(card.likes.postLikeCount == 234 && card.likes.frame.maxX <= 360 - TextCardPreview.inset + 0.5)
    }

    /// With comments: top-level ones, in order, as many as fit — never one
    /// cut in half — under the caption; replies are not shown.
    @Test func theTopCommentsThatFitAndNeverHalfOfOne() throws {
        let many = (0..<30).map { Self.comment($0) } + [Self.comment(99, reply: true)]
        let preview = preview(comments: many)
        let card = try #require(preview.debugTextCard)
        #expect(!card.rows.isEmpty && card.rows.count < 30, "\(card.rows.count) rows: not as many as fit")
        let maxHeight = (360 * TextCardPreview.maxHeightShare).rounded()
        #expect(preview.preferredContentSize.height <= maxHeight)
        for row in card.rows {
            #expect(row.frame.maxY <= preview.preferredContentSize.height, "a comment cut in half: \(row.frame)")
            #expect(row.frame.minY >= card.caption.frame.maxY, "a comment over the caption")
        }
        #expect(zip(card.rows, card.rows.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY + 0.5 }, "rows overlap")
        #expect(card.rule.superview === preview.view)
    }

    /// Two comments that fit: both shown, the lift sized to them.
    @Test func aFewCommentsAllShown() throws {
        let preview = preview(comments: [Self.comment(1), Self.comment(2)])
        let card = try #require(preview.debugTextCard)
        #expect(card.rows.count == 2)
    }
}
