import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The hearts on For You's compact cards — the paired half-width cards and
/// chunk tiles of the Discover list, the pushed gallery's tiles, and the
/// Following row's media cards — at each card's bottom-right
/// (a tile's corner, the end of a Following card's author line).
///
/// No flag (validated 3 October 2026), and DISPLAY ONLY: the post's count,
/// red once the viewer has staked, never a control — a tap on the heart is a
/// tap on the card, and nothing on it spends. The list's full cards keep
/// their staking chip (`CardStakeTests`), and so do the Following row's text
/// cards, which are the list's card.
@MainActor
struct ForYouCardLikesTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: SilentFetcher()) }

    private static func wallet() -> WalletStore {
        let name = "foryou-card-likes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults)
    }

    /// The feed's mix with every other media post vertical (9:16): blocks of
    /// pairs, chunks, full cards.
    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = index % 3 == 2
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: isText ? .text : .photo,
                isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: index % 2 == 0 ? 9.0 / 16.0 : 1.5,
                caption: "post \(index)",
                publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 1_200, commentCount: 34
            )
        }
    }

    private func page(
        style: ForYouGridPage.Style = .discover, wallet: WalletStore
    ) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: style)
        page.staking = PostCardStaking(wallet: wallet)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 6000)
        page.setCorpusComplete(true)
        page.render(.content(corpus(60)))
        page.layoutIfNeeded()
        collectionView(of: page).layoutIfNeeded()
        return page
    }

    private func collectionView(of page: ForYouGridPage) -> UICollectionView {
        page.subviews.compactMap { $0 as? UICollectionView }.first!
    }

    /// Stakes on `postID` straight through the wallet — the way the feed's
    /// rail does, never through a card.
    private func stake(on postID: PostID, in wallet: WalletStore) {
        guard case .boosted = wallet.stake(.points(1), on: postID.rawValue) else {
            Issue.record("the wallet refused the stake")
            return
        }
    }

    /// A touch at the heart finds the CARD — no control, no press of its own
    /// — so the collection view's selection opens the post as it does
    /// anywhere else on the card.
    private func expectTouchFallsThrough(
        _ readout: UIView, in cell: UICollectionViewCell, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(readout.isUserInteractionEnabled == false, sourceLocation: sourceLocation)
        #expect(ActionAffordance.attached(to: readout) == nil, "no press", sourceLocation: sourceLocation)
        let point = readout.convert(CGPoint(x: readout.bounds.midX, y: readout.bounds.midY), to: cell)
        let hit = cell.hitTest(point, with: nil)
        #expect(hit === cell || hit === cell.contentView, "the card takes it: \(String(describing: hit))",
                sourceLocation: sourceLocation)
    }

    // MARK: - Paired cards

    /// A paired card closes its author line with the heart and the post's
    /// count: bottom-right, ending on the card's 10pt inset — over the
    /// picture, the tile's white filled heart.
    @Test func aPairedCardShowsTheHeartOnItsAuthorLine() throws {
        let page = page(wallet: Self.wallet())
        let paired = try #require(page.segments.first(where: \.isPairs)?.posts.first)
        let cell = try #require(page.debugCell(for: paired.id) as? ForYouFollowingCardCell)
        cell.layoutIfNeeded()
        let like = try #require(cell.debugLikeReadout)

        #expect(like.debugCountText == "1.2K")
        #expect(like.debugIsStaked == false)
        #expect(like.ground == .media)
        let frame = like.convert(like.bounds, to: cell.contentView)
        let bounds = cell.contentView.bounds
        #expect(abs(frame.maxX - (bounds.maxX - 10)) < 0.5, "\(frame)")
        #expect(frame.midY > bounds.midY, "in the card's lower half: \(frame) in \(bounds)")
        #expect(frame.maxY < bounds.maxY, "inside the card")
        expectTouchFallsThrough(like, in: cell)
    }

    /// Tapping where the heart is opens the post — the page's own selection,
    /// and the wallet untouched.
    @Test func aTapOnAPairedCardOpensThePostAndStakesNothing() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let page = page(wallet: wallet)
        let paired = try #require(page.segments.first(where: \.isPairs)?.posts.first)
        let index = try #require(page.posts.firstIndex(where: { $0.id == paired.id }))
        var opened: [Int] = []
        page.onItemTapped = { opened.append($0) }

        #expect(page.debugSelectItem(at: index))
        #expect(opened == [index])
        #expect(wallet.balance == before)
        #expect(wallet.boostTotal(forTarget: paired.id.rawValue) == 0)
    }

    /// Staked, the heart is red — on the card and on the copies a flight and
    /// a close wear, so nothing changes colour in the landing frame. The
    /// count stays the post's.
    @Test func aStakedPairedCardsHeartIsRedOnTheCardAndItsCopies() throws {
        let paired = try #require(page(wallet: Self.wallet()).segments.first(where: \.isPairs)?.posts.first)
        let wallet = Self.wallet()
        stake(on: paired.id, in: wallet)
        let page = page(wallet: wallet)
        let cell = try #require(page.debugCell(for: paired.id) as? ForYouFollowingCardCell)
        let like = try #require(cell.debugLikeReadout)
        #expect(like.debugIsStaked)
        #expect(like.debugCountText == "1.2K", "a stake never adds to the count")

        let overlay = try #require(page.restingOverlay(for: paired.id) as? ForYouCardCaptionOverlay)
        #expect(overlay.likeReadout?.debugIsStaked == true)
        #expect(page.viewerStake(on: paired.id) == 1)
    }

    // MARK: - Tiles

    /// A chunk's tile keeps its count in its corner, white until the viewer
    /// stakes, red after — and a touch there is the tile's.
    @Test func aChunkTileShowsTheHeartAndTheViewersStake() throws {
        let wallet = Self.wallet()
        let page = page(wallet: wallet)
        let tile = try #require(page.segments.first(where: { $0.chunk != nil })?.posts.first)
        let cell = try #require(page.debugCell(for: tile.id) as? PostGridTileCell)
        #expect(cell.debugCounterText == "1.2K")
        #expect(cell.debugIsStaked == false)

        let staked = Self.wallet()
        stake(on: tile.id, in: staked)
        let stakedPage = self.page(wallet: staked)
        let stakedCell = try #require(stakedPage.debugCell(for: tile.id) as? PostGridTileCell)
        #expect(stakedCell.debugIsStaked)
        #expect(stakedCell.debugCounterText == "1.2K")
    }

    /// The pushed gallery's tiles, the same.
    @Test func aGalleryTileShowsTheHeartAndTheViewersStake() throws {
        let wallet = Self.wallet()
        stake(on: PostID("p0"), in: wallet)
        let page = page(style: .grid, wallet: wallet)
        let first = try #require(page.debugCell(for: PostID("p0")) as? PostGridTileCell)
        #expect(first.debugCounterText == "1.2K")
        #expect(first.debugIsStaked)
        let second = try #require(page.debugCell(for: PostID("p1")) as? PostGridTileCell)
        #expect(second.debugIsStaked == false)
    }

    /// A stake placed elsewhere (the feed, the post page) shows on the card
    /// that is on screen: the wallet's change reaches every bound heart.
    @Test func aStakeElsewhereTurnsTheVisibleHeartRed() async throws {
        let wallet = Self.wallet()
        let page = page(wallet: wallet)
        let tile = try #require(page.segments.first(where: { $0.chunk != nil })?.posts.first)
        let cell = try #require(page.debugCell(for: tile.id) as? PostGridTileCell)
        #expect(cell.debugIsStaked == false)

        stake(on: tile.id, in: wallet)
        // The wallet's notification is delivered on the main queue.
        for _ in 0..<100 where !cell.debugIsStaked {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cell.debugIsStaked)
    }

    // MARK: - The Following row

    private func rails(wallet: WalletStore) -> ForYouRailsView {
        let rails = ForYouRailsView(imagePipeline: pipeline(), videoPlayback: nil)
        rails.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        rails.staking = PostCardStaking(wallet: wallet)
        var state = ForYouViewModel.Rails()
        state.following = [
            GalleryPost(
                id: PostID("words"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: "Third coffee.", publishedAtMS: 1,
                authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo", reactionCount: 7
            ),
            GalleryPost(
                id: PostID("picture"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/picture.jpg"),
                caption: "Sunset", publishedAtMS: 1,
                authorID: ProfileID("cy"), authorName: "Cy", authorHandle: "cy", reactionCount: 9
            )
        ]
        rails.render(state)
        rails.layoutIfNeeded()
        rails.debugCardsView.layoutIfNeeded()
        return rails
    }

    /// Every Following MEDIA card closes its author line with the heart and
    /// the post's count. A TEXT card is the list's own card (since 3 October
    /// 2026), whose like is the staking chip — see `aFollowingTextCardsLikeStakes`.
    @Test func everyFollowingCardShowsTheHeartOnItsAuthorLine() throws {
        let wallet = Self.wallet()
        stake(on: PostID("picture"), in: wallet)
        let rails = rails(wallet: wallet)

        #expect(rails.debugCardCell(at: 0) == nil, "the text post is not a Following card")
        #expect(rails.debugTextCardCell(at: 0) != nil, "the text post is the list's card")

        let picture = try #require(rails.debugCardCell(at: 1))
        picture.layoutIfNeeded()
        let pictureLike = try #require(picture.debugLikeReadout)
        #expect(pictureLike.ground == .media)
        #expect(pictureLike.debugCountText == "9")
        #expect(pictureLike.debugIsStaked, "red: the viewer staked on it")
        let pictureFrame = pictureLike.convert(pictureLike.bounds, to: picture.contentView)
        #expect(abs(pictureFrame.maxX - (picture.contentView.bounds.maxX - 10)) < 0.5, "\(pictureFrame)")
        #expect(pictureFrame.midY > picture.contentView.bounds.midY)
        expectTouchFallsThrough(pictureLike, in: picture)
        #expect(rails.cardStake(for: rails.cards[1]) == 1)
    }

    /// A tap opens the post; a hold on a media card's heart is the card's own
    /// preview (no stake menu) — and nothing is spent either way.
    @Test func theHeartOfAFollowingCardIsTheCardsToTapAndHold() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let rails = rails(wallet: wallet)
        var opened: [Int] = []
        rails.onCardTapped = { opened.append($0) }

        #expect(rails.debugTapCard(at: 1))
        #expect(opened == [1])

        let picture = try #require(rails.debugCardCell(at: 1))
        picture.layoutIfNeeded()
        let like = try #require(picture.debugLikeReadout)
        let onHeart = like.convert(CGPoint(x: like.bounds.midX, y: like.bounds.midY), to: rails.debugCardsView)
        #expect(rails.debugCardMenuConfiguration(at: 1, point: onHeart) != nil, "the card's preview")
        #expect(wallet.balance == before)
    }

    /// ⚠️ A TEXT card's like is NOT a readout: it is the list's staking chip,
    /// and a tap on it spends, the heart turning red.
    @Test func aFollowingTextCardsLikeStakes() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let rails = rails(wallet: wallet)
        let words = try #require(rails.debugTextCardCell(at: 0))
        #expect(words.debugTapLikesChip())
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(rails.cardStake(for: rails.cards[0]) == WalletStore.Policy.defaultStakeAmount)
    }

    /// The copies a flight and a close wear carry the card's heart, in the
    /// card's colour.
    @Test func aFollowingCardsCopiesWearTheHeart() throws {
        let post = GalleryPost(
            id: PostID("picture"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/picture.jpg"),
            caption: "Sunset", publishedAtMS: 1,
            authorID: ProfileID("cy"), authorName: "Cy", authorHandle: "cy", reactionCount: 7
        )
        let size = CGSize(width: 150, height: 200)
        let overlay = ForYouFollowingCardCell.makeOverlay(for: post, restingSize: size, viewerStake: 2)
        #expect(overlay.likeReadout?.debugIsStaked == true)
        #expect(overlay.likeReadout?.debugCountText == "7")
        #expect(!overlay.debugLikeFrame.isNull)

        let standIn = ForYouFollowingCardCell.makeStandIn(for: post, cover: nil, size: size)
        let standInOverlay = try #require(standIn.subviews.compactMap { $0 as? ForYouCardCaptionOverlay }.first)
        #expect(standInOverlay.likeReadout?.debugIsStaked == false)
        #expect(standInOverlay.likeReadout?.debugCountText == "7")
    }
}
