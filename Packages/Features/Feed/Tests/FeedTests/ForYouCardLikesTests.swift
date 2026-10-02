import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// EXPERIMENT `-foryou-card-likes`: a like (the stake) on For You's compact
/// cards — the paired half-width cards and chunk tiles of the Discover list,
/// the pushed gallery's tiles, the Following row's text cards — in each
/// card's bottom-right, through the list card's own machinery. Flag off, none.
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
        style: ForYouGridPage.Style = .discover, stakes: Bool, wallet: WalletStore
    ) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: pipeline(), style: style)
        page.staking = PostCardStaking(wallet: wallet)
        page.stakesOnCompactCards = stakes
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

    // MARK: - The flag

    @Test func theFlagIsTheLaunchArgument() {
        #expect(ForYouCardLikes.launchArgument == "-foryou-card-likes")
        #expect(ForYouCardLikes.isEnabled(arguments: ["App", "-foryou-card-likes"]))
        #expect(ForYouCardLikes.isEnabled(arguments: ["App"]) == false)
    }

    /// Flag off: no compact card carries a like — not a paired card, not a
    /// tile, not a copy of either. The list's full cards keep theirs.
    @Test func withoutTheFlagNoCompactCardHasALike() throws {
        let wallet = Self.wallet()
        let page = page(stakes: false, wallet: wallet)
        let paired = try #require(page.segments.first(where: \.isPairs)?.posts.first)
        let tile = try #require(page.segments.first(where: { $0.chunk != nil })?.posts.first)

        let pairedCell = try #require(page.debugCell(for: paired.id) as? ForYouFollowingCardCell)
        #expect(pairedCell.debugStakeChip == nil)
        let tileCell = try #require(page.debugCell(for: tile.id) as? PostGridTileCell)
        #expect(tileCell.debugStakeChip == nil)
        #expect(page.compactCardStake(for: paired.id) == nil)
        let overlay = try #require(page.restingOverlay(for: paired.id) as? ForYouCardCaptionOverlay)
        #expect(overlay.stakeChip == nil)
    }

    // MARK: - Paired cards

    /// A paired card closes its author line with the heart: bottom-right, the
    /// ink on the card's 10pt inset, the name ending before it. A tap stakes
    /// the one default point; a hold raises the stake menu.
    @Test func aPairedCardStakesFromItsAuthorLine() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let page = page(stakes: true, wallet: wallet)
        let paired = try #require(page.segments.first(where: \.isPairs)?.posts.first)
        let cell = try #require(page.debugCell(for: paired.id) as? ForYouFollowingCardCell)
        cell.layoutIfNeeded()
        let chip = try #require(cell.debugStakeChip)

        let frame = chip.convert(chip.bounds, to: cell.contentView)
        let bounds = cell.contentView.bounds
        #expect(abs(frame.maxX - (bounds.maxX - 10 + PostStakeChipView.inkInset)) < 0.5, "\(frame)")
        #expect(frame.midY > bounds.midY, "in the card's lower half: \(frame) in \(bounds)")
        #expect(frame.maxY < bounds.maxY, "inside the card")
        #expect(chip.ground == .media)

        #expect(chip.debugTap())
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(chip.debugIsStaked)
        #expect(ActionAffordance.attached(to: chip)?.debugHasMenu == true)
        #expect(try #require(cell.stakeMenu?()).children.isEmpty == false)

        // The copies a flight and a close wear carry the heart, red now.
        let overlay = try #require(page.restingOverlay(for: paired.id) as? ForYouCardCaptionOverlay)
        #expect(overlay.stakeChip?.debugIsStaked == true)
        #expect(overlay.stakeChip?.isUserInteractionEnabled == false, "scenery, not a control")
        #expect(page.compactCardStake(for: paired.id) == WalletStore.Policy.defaultStakeAmount)
    }

    // MARK: - Tiles

    /// A chunk's tile: its count becomes the like, in its corner.
    @Test func aChunkTileStakesFromItsCorner() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let page = page(stakes: true, wallet: wallet)
        let tile = try #require(page.segments.first(where: { $0.chunk != nil })?.posts.first)
        let cell = try #require(page.debugCell(for: tile.id) as? PostGridTileCell)
        cell.layoutIfNeeded()
        let chip = try #require(cell.debugStakeChip)
        let frame = chip.convert(chip.bounds, to: cell.contentView)
        #expect(abs(frame.maxX - cell.contentView.bounds.maxX) < 0.5, "\(frame)")
        #expect(frame.midY > cell.contentView.bounds.midY)

        #expect(chip.debugTap())
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(ActionAffordance.attached(to: chip)?.debugHasMenu == true)
    }

    /// The pushed gallery's tiles, the same.
    @Test func aGalleryTileStakes() throws {
        let wallet = Self.wallet()
        let page = page(style: .grid, stakes: true, wallet: wallet)
        let first = try #require(page.posts.first)
        let cell = try #require(page.debugCell(for: first.id) as? PostGridTileCell)
        let chip = try #require(cell.debugStakeChip)
        #expect(chip.debugTap())
        #expect(wallet.boostTotal(forTarget: first.id.rawValue) == WalletStore.Policy.defaultStakeAmount)

        let off = self.page(style: .grid, stakes: false, wallet: wallet)
        let unbound = try #require(off.debugCell(for: first.id) as? PostGridTileCell)
        #expect(unbound.debugStakeChip == nil)
    }

    // MARK: - The Following row

    private func rails(stakes: Bool, wallet: WalletStore) -> ForYouRailsView {
        let rails = ForYouRailsView(imagePipeline: pipeline(), videoPlayback: nil)
        rails.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        rails.staking = PostCardStaking(wallet: wallet)
        rails.stakesOnTextCards = stakes
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

    /// A TEXT card closes its author line — its foot — with the heart; a
    /// picture card in the row has none (the product asked for text cards).
    /// A hold on the heart is the stake's menu, not the card's preview.
    @Test func aFollowingTextCardStakesFromItsCorner() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let rails = rails(stakes: true, wallet: wallet)
        let words = try #require(rails.debugCardCell(at: 0))
        words.layoutIfNeeded()
        let chip = try #require(words.debugStakeChip)
        #expect(chip.ground == .card)
        let frame = chip.convert(chip.bounds, to: words.contentView)
        let bounds = words.contentView.bounds
        #expect(abs(frame.maxX - (bounds.maxX - 10 + PostStakeChipView.inkInset)) < 0.5, "\(frame)")
        #expect(frame.maxY < bounds.maxY && frame.maxY > bounds.maxY - 30, "on the foot line: \(frame)")
        #expect(rails.debugCardCell(at: 1)?.debugStakeChip == nil, "a picture card has no like")

        #expect(chip.debugTap())
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(ActionAffordance.attached(to: chip)?.debugHasMenu == true)

        let onHeart = chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: rails.debugCardsView)
        #expect(rails.debugCardMenuConfiguration(at: 0, point: onHeart) == nil, "the heart's hold")
        let onWords = words.convert(CGPoint(x: 20, y: 20), to: rails.debugCardsView)
        #expect(rails.debugCardMenuConfiguration(at: 0, point: onWords) != nil, "the card's preview")
    }

    @Test func withoutTheFlagAFollowingTextCardHasNoLike() throws {
        let rails = rails(stakes: false, wallet: Self.wallet())
        #expect(try #require(rails.debugCardCell(at: 0)).debugStakeChip == nil)
        #expect(rails.cardStake(for: rails.cards[0]) == nil)
    }
}
