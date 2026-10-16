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
