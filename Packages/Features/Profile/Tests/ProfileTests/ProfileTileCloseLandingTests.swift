import CoreModels
import CoreNavigation
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// **A card-shaped close onto a TILE lands as that tile (#888).**
///
/// Filmed on the viewer's own profile: open a Discover pair's photo, page onto
/// a text post, close. The close is a window (the text page has nothing to
/// fly), and it lands on the post that opened the feed. Its stand-in and its
/// shape were a ROW's — a whole post card (author band, picture, comment chip)
/// at the pair's width on the card's white, with the row's author band
/// borrowed for the flight — so the old default post card faded in over the
/// page and was then swapped for the photo tile.
///
/// The arrival cell decides: a tile lands as its twin
/// (`PostGridTileStandInView`) on the tile's corner and fill, a row as the
/// card it always was.
///
/// And a MEDIA close onto a worded tile carries the tile's words (#910), so
/// they are on the landed frame rather than following it.
@MainActor
struct ProfileTileCloseLandingTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor NoProfiles: ProfileProviding {
        private func someone() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-demo"), handle: "you", displayName: "Demo Viewer",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0), reactionCount: .exact(0)
            )
        }
        func currentUserProfile() async throws -> UserProfile { someone() }
        func profile(id: ProfileID) async throws -> UserProfile { someone() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { someone() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { someone() }
    }

    private actor NoGallery: ProfileGalleryProviding {
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    /// Authored, as the viewer's own posts are: the row draws a band, which
    /// is what a tile's close must NOT borrow.
    private func post(_ index: Int, _ kind: GalleryPost.Kind, aspect: Double = 1) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p\(index)"),
            kind: kind,
            isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(index).jpg"),
            aspectRatio: aspect,
            caption: "Post \(index)",
            publishedAtMS: Int64(10_000 - index)
        )
        post.authorID = ProfileID("prof-demo")
        post.authorName = "Demo Viewer"
        post.authorHandle = "you"
        post.commentCount = 202
        return post
    }

    /// Two tall photos first (a pair), then the mock's mix: every third post
    /// text, the rest square photos — a chunk of tiles and text rows.
    private func corpus() -> [GalleryPost] {
        [post(0, .photo, aspect: 0.5625), post(1, .photo, aspect: 0.5625)]
            + (2..<30).map { post($0, $0 % 3 == 2 ? .text : .photo) }
    }

    private func page(_ style: ProfileGalleryGridView.Style, posts: [GalleryPost]) -> ProfileGalleryGridView {
        let page = ProfileGalleryGridView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            style: style,
            tab: .format(style == .grid ? .media : .activity)
        )
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.setCorpusComplete(true)
        page.render(.content(posts))
        page.layoutIfNeeded()
        page.collectionView.layoutIfNeeded()
        return page
    }

    /// Brings `id`'s cell on screen, as the tap that opens it would have.
    private func realize(_ id: PostID, on page: ProfileGalleryGridView) throws {
        let path = try #require(page.debugIndexPath(for: id))
        page.collectionView.scrollToItem(at: path, at: .top, animated: false)
        page.collectionView.layoutIfNeeded()
    }

    /// Opens `post` from `page` through the profile's real open, and returns
    /// the origin it hands the feed — the description the close lands by.
    private func origin(opening post: GalleryPost, from page: ProfileGalleryGridView) throws -> SnapFeedHeroOrigin {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil
        )
        var handed: SnapFeedHeroOrigin?
        screen.feedHero = { _, _, origin in handed = origin }
        screen.openGalleryPost(post, stream: [post], showingComments: false, from: page)
        return try #require(handed, "the open never reached the hero seam")
    }

    /// The bug itself: a pair's photo opened by a flight, closed from a text
    /// page. The window lands as the pair's TILE — its twin, at the slot's
    /// size, on the tile's corner and fill, with no author band borrowed and
    /// no caption to align to.
    @Test func aPairsCloseLandsAsItsTileNotAsAPostCard() throws {
        let page = self.page(.discover, posts: corpus())
        let pair = try #require(page.debugSegments.first { $0.isPairs }?.posts.first)
        try realize(pair.id, on: page)
        let slot = try #require(page.rowFrame(for: pair.id, in: page))

        let reveal = try #require(try origin(opening: pair, from: page).textReveal)

        let standIn = try #require(reveal.makeDismissStandIn(nil))
        #expect(standIn is PostGridTileStandInView, "the close lands as a post card, not as the tile")
        #expect(!(standIn is RevealDismissCardView))
        #expect(standIn.bounds.size == slot.size, "the twin is not the slot's size")
        #expect(reveal.authorBand == nil, "a post card's header is borrowed into a tile's flight")
        #expect(reveal.alignsPageToSource == false, "the page is aligned to a caption a tile does not have")
        #expect(reveal.cornerRadius == PostGridListRowCell.mediaCornerRadius, "not the pair's own corner")
        #expect(reveal.fill == PostGridTileCell.fillColor(for: pair), "not the tile's own fill")
    }

    /// A chunk's tile, the same rule at the mosaic's corner.
    @Test func aChunkTilesCloseLandsAsItsTile() throws {
        let page = self.page(.discover, posts: corpus())
        let tile = try #require(page.debugSegments.first { $0.chunk != nil }?.posts.first)
        try realize(tile.id, on: page)
        let slot = try #require(page.rowFrame(for: tile.id, in: page))

        let reveal = try #require(try origin(opening: tile, from: page).textReveal)

        let standIn = try #require(reveal.makeDismissStandIn(nil))
        #expect(standIn is PostGridTileStandInView)
        #expect(standIn.bounds.size == slot.size)
        #expect(reveal.authorBand == nil)
        #expect(reveal.alignsPageToSource == false)
        #expect(reveal.cornerRadius == ChaoticSliceLayout.harmonisedCornerRadius)
    }

    /// The media gallery's bricks ("View all") are tiles too.
    @Test func aMediaGalleryBricksCloseLandsAsItsTile() throws {
        let photos = (0..<12).map { post($0, .photo) }
        let page = self.page(.grid, posts: photos)
        try realize(photos[3].id, on: page)

        let reveal = try #require(try origin(opening: photos[3], from: page).textReveal)

        #expect(reveal.makeDismissStandIn(nil) is PostGridTileStandInView)
        #expect(reveal.cornerRadius == ChaoticSliceLayout.harmonisedCornerRadius)
        #expect(reveal.authorBand == nil)
    }

    /// ⚠️ ROWS ARE UNCHANGED: a text row still closes onto its card — the
    /// row-shaped stand-in, the card's corner and white, the page aligned to
    /// its caption, the band borrowed.
    @Test func aTextRowStillLandsAsItsCard() throws {
        let page = self.page(.discover, posts: corpus())
        let text = try #require(page.debugSegments.first { $0.chunk == nil && !$0.isPairs }?
            .posts.first { $0.kind == .text })
        try realize(text.id, on: page)

        let reveal = try #require(try origin(opening: text, from: page).textReveal)

        #expect(reveal.makeDismissStandIn(nil) is RevealDismissCardView)
        #expect(reveal.alignsPageToSource == true)
        #expect(reveal.cornerRadius == nil, "a row's window lost the card's corner")
        #expect(reveal.fill == PostGridListRowCell.cardFillColor)
        let band = try #require(page.textRowAuthorBand(for: text.id), "the row draws no band to borrow")
        #expect(reveal.authorBand == band)
    }

    // MARK: - The words a media close carries home (#910)

    /// The cell `id` is drawn in — a tile, for every caller below.
    private func tileCell(_ id: PostID, on page: ProfileGalleryGridView) throws -> PostGridTileCell {
        let path = try #require(page.debugIndexPath(for: id))
        return try #require(page.collectionView.cellForItem(at: path) as? PostGridTileCell)
    }

    /// The bug itself: a media close onto a Discover pair landed as the bare
    /// picture, its author, likes and caption appearing only once the tile was
    /// back — the profile's origin wore no overlay, For You's does. The origin
    /// now hands the flight the pair's words, at the slot's size, with the
    /// heart closing the author line as on the tile.
    @Test func aPairsOriginCarriesItsWords() throws {
        let page = self.page(.discover, posts: corpus())
        let pair = try #require(page.debugSegments.first { $0.isPairs }?.posts.first)
        try realize(pair.id, on: page)
        let slot = try #require(page.rowFrame(for: pair.id, in: page))
        #expect(try tileCell(pair.id, on: page).debugInfoOverlay != nil, "the pair wears no words to carry")

        let origin = try self.origin(opening: pair, from: page)

        let restingOverlay = try #require(origin.restingOverlay, "the origin carries no overlay: the close lands bare")
        let overlay = try #require(restingOverlay() as? PostCardCaptionOverlay, "the pair's words are not carried")
        #expect(overlay.bounds.size == slot.size, "the words are not wrapped at the tile's size")
        #expect(overlay.likeReadout != nil, "the carried words lost the heart that closes the tile's author line")
    }

    /// A chunk's tile carries its words when it wears any, and nothing when it
    /// is too small to — whatever the tile under the landing draws.
    @Test func aChunkTilesOriginCarriesWhatTheTileWears() throws {
        let page = self.page(.discover, posts: corpus())
        let tiles = try #require(page.debugSegments.first { $0.chunk != nil }?.posts)
        var sawWorded = false
        for tile in tiles {
            try realize(tile.id, on: page)
            let wears = try tileCell(tile.id, on: page).debugInfoOverlay != nil
            sawWorded = sawWorded || wears
            let carried = try origin(opening: tile, from: page).restingOverlay?()
            #expect((carried is PostCardCaptionOverlay) == wears, "tile \(tile.id.rawValue): carries \(carried != nil), wears \(wears)")
        }
        #expect(sawWorded, "no chunk tile large enough to wear words: the test proves nothing")
    }

    /// ⚠️ NOTHING IS ADDED where the tile wears no words: the media gallery's
    /// bricks fly their corner count as before, and a row has no overlay.
    @Test func bricksAndRowsCarryNoWords() throws {
        let photos = (0..<12).map { post($0, .photo) }
        let grid = page(.grid, posts: photos)
        try realize(photos[3].id, on: grid)
        #expect(try origin(opening: photos[3], from: grid).restingOverlay?() == nil)

        let discover = page(.discover, posts: corpus())
        let row = try #require(discover.debugSegments.first { $0.chunk == nil && !$0.isPairs }?.posts.first)
        try realize(row.id, on: discover)
        #expect(try origin(opening: row, from: discover).restingOverlay?() == nil)
    }
}
