import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A SHELF OF POSTS (#1271): a titled section with a media row and a text
/// row, drawn by itself — the host only says what it is called and what it
/// holds.
@MainActor
struct PostShelfSectionTests {
    private static func shelf() -> PostShelfSection {
        let shelf = PostShelfSection(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), videoPlayback: nil)
        shelf.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        return shelf
    }

    /// The title is the host's: the section has no word of its own.
    @Test func theTitleAndCountAreTheHosts() {
        let shelf = Self.shelf()
        #expect(shelf.title.isEmpty, "the section named itself")
        shelf.title = "Popular"
        shelf.setCount(new: 4)
        #expect(shelf.header.content.title == "Popular")
        #expect(shelf.debugCountText == "4")
        var tapped = 0
        shelf.onTitleTapped = { tapped += 1 }
        shelf.debugTapTitle()
        #expect(tapped == 1, "the title's own tap path did not reach the host")
    }

    /// The host describes the shelf with ONE model — title, count, posts,
    /// limits, "View all" — and the shelf draws it (#1271).
    @Test func aModelDescribesTheWholeShelf() {
        let shelf = Self.shelf()
        let posts = [Self.post("m0", kind: .photo), Self.post("m1", kind: .video), Self.post("t0", kind: .text)]
        let model = PostShelfSection.Model(
            title: "Recent", newCount: 2, posts: posts, mediaLimit: 1, textLimit: nil, showsViewAll: true
        )
        #expect(shelf.apply(model))
        #expect(shelf.model == model)
        #expect(shelf.header.content.title == "Recent")
        #expect(shelf.debugCountText == "2")
        #expect(shelf.debugRowIDs.media == [posts[0].id], "the media limit was not applied")
        #expect(shelf.debugRowIDs.text == [posts[2].id])
        #expect(!shelf.apply(model), "the same posts again reported a change")
    }

    /// Nothing to show, nothing drawn: no heading over nothing.
    @Test func anEmptyShelfIsZeroTall() {
        let shelf = Self.shelf()
        shelf.render([])
        shelf.layoutIfNeeded()
        #expect(shelf.preferredHeight(forWidth: 402) == 0)
        #expect(shelf.header.isHidden)
    }

    /// A row with nothing in it collapses; the shelf is then media-only or
    /// text-only, and its height is its title plus the one row.
    @Test(arguments: [GalleryPost.Kind.video, .text])
    func aRowWithNothingCollapses(kind: GalleryPost.Kind) {
        let shelf = Self.shelf()
        shelf.render([Self.post("a", kind: kind), Self.post("b", kind: kind)])
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.isHidden == (kind == .text))
        #expect(shelf.textView.isHidden == (kind != .text))
        let media = kind == .text ? 0 : 2
        let text = kind == .text ? 2 : 0
        #expect(shelf.preferredHeight(forWidth: 402)
            == SectionTitleView.Metrics.height + PostShelfRows.height(forWidth: 402, media: media, text: text))
    }

    /// A tap on a card opens it by its index into the shelf's posts,
    /// whichever row it sits in.
    @Test func aTapOpensTheCardsPost() throws {
        let shelf = Self.shelf()
        let posts = [Self.post("m", kind: .photo), Self.post("t", kind: .text)]
        shelf.render(posts)
        shelf.layoutIfNeeded()
        var opened: [Int] = []
        shelf.onCardTapped = { opened.append($0) }
        #expect(shelf.debugTapCard(at: 1))
        #expect(shelf.debugTapCard(at: 0))
        #expect(opened == [1, 0])
    }

    // MARK: - Limits and "View all"

    /// Each row draws at most its limit, in the section's order, and the
    /// shelf is as tall as what it draws.
    @Test func aRowDrawsAtMostItsLimit() {
        let shelf = Self.shelf()
        let media = (0..<6).map { Self.post("m\($0)", kind: .photo) }
        let text = (0..<4).map { Self.post("t\($0)", kind: .text) }
        shelf.render(media + text)
        var changes = 0
        shelf.onHeightChange = { changes += 1 }
        shelf.mediaLimit = 3
        shelf.textLimit = 1
        #expect(shelf.debugRowIDs.media == media.prefix(3).map(\.id))
        #expect(shelf.debugRowIDs.text == [text[0].id])
        #expect(shelf.rowCounts == (3, 1))
        #expect(changes == 2, "\(changes): a limit that moved a row's count did not re-size the host")
        shelf.textLimit = 0
        shelf.layoutIfNeeded()
        #expect(shelf.textView.isHidden, "a row limited to nothing still drew")
        #expect(shelf.preferredHeight(forWidth: 402)
            == SectionTitleView.Metrics.height + PostShelfRows.height(forWidth: 402, media: 3, text: 0))
    }

    /// EACH ROW ENDS ON THE CHEVRON CARD (the owner, 2026-10-16, #1296): a
    /// narrow card, no words, the shelf's "View all" — it runs the title's
    /// action, and is drawn only while the title has one.
    @Test func eachRowEndsOnTheChevronCardRunningTheTitlesAction() throws {
        let shelf = Self.shelf()
        shelf.render([Self.post("m", kind: .photo), Self.post("t", kind: .text)])
        #expect(shelf.showsViewAll, "the chevron card is not on by default")
        #expect(!shelf.debugTapViewAll(), "drawn with no action behind it")
        var tapped = 0
        shelf.onTitleTapped = { tapped += 1 }
        shelf.layoutIfNeeded()
        #expect(shelf.mediaView.numberOfItems(inSection: 0) == 2, "the media row does not end on it")
        #expect(shelf.textView.numberOfItems(inSection: 0) == 2, "the text row does not end on it")
        #expect(shelf.debugTapViewAll())
        #expect(tapped == 1)

        // Narrow, and as tall as the row.
        shelf.mediaView.layoutIfNeeded()
        let card = try #require(shelf.mediaView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let chevron = try #require(shelf.mediaView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        #expect(chevron.size.width == ShelfViewAllCell.width)
        #expect(chevron.size.height == card.size.height)

        var opened: [Int] = []
        shelf.onCardTapped = { opened.append($0) }
        _ = shelf.debugTapViewAll()
        #expect(opened.isEmpty, "the chevron card opened a post")
    }

    /// TEN CARDS A ROW by default (#1296), the section's order.
    @Test func aRowDrawsTenCardsByDefault() {
        let shelf = Self.shelf()
        let media = (0..<14).map { Self.post("m\($0)", kind: .photo) }
        shelf.render(media)
        #expect(shelf.rowCounts.media == PostShelfSection.rowLimit)
        #expect(shelf.debugRowIDs.media == media.prefix(10).map(\.id))
    }

    /// LOADING (#1296): the title over a row of skeleton cards, as tall as
    /// a media row; the posts arriving take its place, and a shelf that
    /// loaded nothing disappears.
    @Test func aLoadingShelfShowsItsTitleOverSkeletonCards() {
        let shelf = Self.shelf()
        shelf.title = "Following"
        var changes = 0
        shelf.onHeightChange = { changes += 1 }
        shelf.isLoading = true
        shelf.layoutIfNeeded()
        #expect(changes == 1)
        #expect(shelf.preferredHeight(forWidth: 402) == PostShelfSection.loadingHeight(forWidth: 402))
        #expect(!shelf.header.isHidden, "no title over the skeleton")
        #expect(shelf.subviews.contains { $0 is SkeletonBoneView }, "no skeleton cards")

        shelf.apply(.init(title: "Following", posts: [Self.post("m", kind: .photo)]))
        shelf.layoutIfNeeded()
        #expect(!shelf.subviews.contains { $0 is SkeletonBoneView }, "the skeleton outlived the posts")
        #expect(!shelf.isLoading)

        shelf.isLoading = true
        shelf.apply(.init(title: "Following", posts: []))
        shelf.layoutIfNeeded()
        #expect(shelf.preferredHeight(forWidth: 402) == 0, "a shelf that loaded nothing stayed")
    }

    // MARK: - The lead stack

    /// A lead with nothing shown is zero tall and titles nothing.
    @Test func anEmptyLeadIsZeroTallAndUntitled() {
        let shelf = Self.shelf()
        let lead = GridLeadStack(sections: [shelf])
        lead.listTitle = "Recent"
        lead.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        lead.layoutIfNeeded()
        #expect(lead.preferredHeight(forWidth: 402) == 0)
        #expect(lead.debugListTitleView.isHidden)
    }

    /// One shelf over the list's title is as tall as the rails were with only
    /// their card row (the place page's and the hashtag page's lead before
    /// #1271), so the list under it starts where it did.
    @Test(arguments: [(3, 0), (0, 2), (4, 3)])
    func aShelfLeadKeepsTheRailsHeight(media: Int, text: Int) {
        let shelf = Self.shelf()
        let posts = (0..<media).map { Self.post("m\($0)", kind: .photo) }
            + (0..<text).map { Self.post("t\($0)", kind: .text) }
        shelf.render(posts)
        let lead = GridLeadStack(sections: [shelf])
        // The rails' old formula with only a card row: the row, the section
        // gap, the list's title and its own gap.
        #expect(lead.preferredHeight(forWidth: 402)
            == PostShelfSection.height(forWidth: 402, media: media, text: text)
                + LeadRowMetrics.rowGap + SectionTitleView.Metrics.height + LeadRowMetrics.listGap)
    }

    /// The shelf's rows changing size reaches the host through the stack, and
    /// the list's title takes its own tap.
    @Test func theStackForwardsHeightChangesAndTheTitlesTap() {
        let shelf = Self.shelf()
        let lead = GridLeadStack(sections: [shelf])
        var changes = 0
        lead.onHeightChange = { changes += 1 }
        shelf.render([Self.post("m", kind: .photo)])
        #expect(changes == 1)
        shelf.render([Self.post("m2", kind: .photo)])
        #expect(changes == 1, "the same row counts moved the lead")
        var tapped = 0
        lead.onListTitleTapped = { tapped += 1 }
        lead.debugListTitleView.debugTap()
        #expect(tapped == 1)
    }

    private static func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
            reactionCount: 3, commentCount: 1
        )
    }
}
