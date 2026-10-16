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
            == SectionTitleView.Metrics.height + ForYouFollowingRows.height(forWidth: 402, media: media, text: text))
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
        #expect(lead.preferredHeight(forWidth: 402)
            == ForYouRailsView.height(forWidth: 402, friends: 0, following: media + text, textCards: text))
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
