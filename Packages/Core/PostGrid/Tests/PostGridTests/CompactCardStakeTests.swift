import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A mosaic TILE's like, as a stake (`-foryou-card-likes` on For You): the
/// tile's count becomes the card's like chip, in place, through the list
/// card's own machinery (`PostCardStaking`, `ActionAffordance`, `StakeMenu`).
@MainActor
struct CompactCardStakeTests {
    private static func defaults() -> UserDefaults {
        let name = "compact-card-stake-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let post = GalleryPost(
        id: PostID("tile-1"), kind: .photo, isRepost: false,
        thumbnailURL: URL(string: "https://example.com/tile-1.jpg"),
        caption: "", publishedAtMS: 0, reactionCount: 1_200
    )

    private func tile() -> PostGridTileCell {
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 150, height: 150))
        cell.configure(with: Self.post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    /// Unbound, a tile is the readout it always was: no control anywhere.
    @Test func anUnboundTileHasNoLike() {
        let cell = tile()
        #expect(cell.debugStakeChip == nil)
        #expect(cell.debugCounterText == "1.2K")
    }

    /// Bound, the count IS the like: the same number, now a control in the
    /// tile's bottom-right corner — and a tap stakes the ONE default point.
    @Test func aBoundTileStakesOnePointFromItsCorner() throws {
        let wallet = WalletStore(defaults: Self.defaults())
        let before = wallet.balance
        let staking = PostCardStaking(wallet: wallet)
        let cell = tile()
        staking.bind(cell, to: Self.post.id)
        cell.layoutIfNeeded()

        let chip = try #require(cell.debugStakeChip)
        #expect(cell.debugCounterText == "1.2K", "the count stays the post's")
        #expect(chip.debugIsStaked == false)
        // Bottom-right: the ink's trailing edge on the readout's 8pt inset,
        // the box (ink + `inkInset`) flush with the tile's edge, inside it.
        let frame = chip.convert(chip.bounds, to: cell.contentView)
        #expect(abs(frame.maxX - cell.contentView.bounds.maxX) < 0.5, "\(frame)")
        #expect(frame.maxY <= cell.contentView.bounds.maxY + 0.5, "\(frame)")
        #expect(frame.minY > cell.contentView.bounds.midY, "\(frame)")

        #expect(chip.debugTap())
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(wallet.boostTotal(forTarget: "tile-1") == WalletStore.Policy.defaultStakeAmount)
        #expect(chip.debugIsStaked, "the heart turns red")
    }

    /// A hold raises the stake menu — the card's, with the ×100 cartridges.
    @Test func aHeldTileRaisesTheStakeMenu() throws {
        let wallet = WalletStore(defaults: Self.defaults())
        let staking = PostCardStaking(wallet: wallet)
        let cell = tile()
        staking.bind(cell, to: Self.post.id)

        let chip = try #require(cell.debugStakeChip)
        #expect(ActionAffordance.attached(to: chip)?.debugHasMenu == true)
        let menu = try #require(cell.stakeMenu?())
        #expect(!menu.children.isEmpty)
    }

    /// Recycled, the tile is a readout again until its next host binds it.
    @Test func aRecycledTileForgetsItsStake() {
        let wallet = WalletStore(defaults: Self.defaults())
        let staking = PostCardStaking(wallet: wallet)
        let cell = tile()
        staking.bind(cell, to: Self.post.id)
        staking.stake(.points(1), on: "tile-1", cell: cell)

        cell.prepareForReuse()

        #expect(cell.debugStakeChip == nil)
        #expect(cell.onStake == nil)
        #expect(cell.debugCounterText == "1.2K", "the readout again")
    }

    /// The chip's own contract: a heart kept with no count, the post's count
    /// otherwise, red only for the viewer's stake.
    @Test func theChipDrawsTheCountAndTheViewersStake() {
        let chip = PostStakeChipView(ground: .card, font: .preferredFont(forTextStyle: .caption1))
        #expect(chip.debugCountText == nil)
        chip.setCount(42)
        #expect(chip.debugCountText == "42")
        chip.setViewerStake(3)
        #expect(chip.debugIsStaked)
        #expect(chip.debugCountText == "42", "a stake never adds to the count")
        chip.reset()
        #expect(chip.debugIsStaked == false)
        #expect(chip.onStake == nil)
        #expect(chip.debugTap() == false, "unwired, it is not a control")
        // Its declared height is its type's, not the closing line's 32pt.
        let size = chip.fittedSize
        #expect(abs(size.height - PostStakeChipView.height(for: .preferredFont(forTextStyle: .caption1))) < 0.5)
    }
}
