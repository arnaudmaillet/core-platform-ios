import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A compact card's like — a mosaic TILE's count, a For You card's
/// `PostLikeReadoutView` — is a READOUT: the post's count, the heart red once
/// the viewer has staked, kept current from the wallet by `PostCardStaking`
/// (`bindReadout`) and never a control. The list card's chip is the one that
/// stakes (`CardStakeTests`).
@MainActor
struct CompactCardLikeTests {
    private static func defaults() -> UserDefaults {
        let name = "compact-card-like-tests-\(UUID().uuidString)"
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

    /// Unbound, a tile is the readout it always was, white.
    @Test func anUnboundTileIsAWhiteReadout() {
        let cell = tile()
        #expect(cell.debugCounterText == "1.2K")
        #expect(cell.debugIsStaked == false)
    }

    /// Bound, the tile reads the viewer's stake — red once there is any —
    /// and the count stays the post's. Binding spends nothing.
    @Test func aBoundTileReadsTheViewersStake() {
        let wallet = WalletStore(defaults: Self.defaults())
        let before = wallet.balance
        let staking = PostCardStaking(wallet: wallet)
        let cell = tile()
        staking.bindReadout(cell, to: Self.post.id)
        #expect(cell.debugIsStaked == false)
        #expect(wallet.balance == before)

        _ = wallet.stake(.points(1), on: "tile-1")
        let other = tile()
        staking.bindReadout(other, to: Self.post.id)
        #expect(other.debugIsStaked)
        #expect(other.debugCounterText == "1.2K", "a stake never adds to the count")
    }

    /// Recycled, the tile forgets the last post's stake.
    @Test func aRecycledTileForgetsTheStake() {
        let wallet = WalletStore(defaults: Self.defaults())
        _ = wallet.stake(.points(1), on: "tile-1")
        let staking = PostCardStaking(wallet: wallet)
        let cell = tile()
        staking.bindReadout(cell, to: Self.post.id)
        #expect(cell.debugIsStaked)

        cell.prepareForReuse()

        #expect(cell.debugIsStaked == false)
    }

    /// A tile's stand-in draws the heart the tile it lands on draws.
    @Test func aTileStandInWearsTheViewersStake() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let size = CGSize(width: 150, height: 150)
        let staked = PostGridTileStandInView(post: Self.post, size: size, imagePipeline: pipeline, viewerStake: 3)
        #expect(staked.debugIsStaked)
        let plain = PostGridTileStandInView(post: Self.post, size: size, imagePipeline: pipeline)
        #expect(plain.debugIsStaked == false)
    }

    /// The readout's own contract: absent with no count, the post's count
    /// otherwise, red only for the viewer's stake — and no touch of its own.
    @Test func theReadoutDrawsTheCountAndTheViewersStake() {
        let like = PostLikeReadoutView(ground: .card, font: .preferredFont(forTextStyle: .caption1))
        #expect(like.debugCountText == nil)
        #expect(like.isHidden)
        #expect(like.fittedSize == .zero)
        like.setCount(42)
        #expect(like.debugCountText == "42")
        #expect(like.fittedSize.width > 0)
        like.setViewerStake(3)
        #expect(like.debugIsStaked)
        #expect(like.debugCountText == "42", "a stake never adds to the count")
        like.setViewerStake(0)
        #expect(like.debugIsStaked == false)
        #expect(like.isUserInteractionEnabled == false, "scenery: the card takes the touch")
        #expect(ActionAffordance.attached(to: like) == nil)
        #expect(like.gestureRecognizers?.isEmpty ?? true)
    }
}
