import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A card's like chip STAKES — likes and points are one thing.
@MainActor
struct CardStakeTests {
    private static func defaults() -> UserDefaults {
        let name = "card-stake-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func row(reactions: Int64? = 160) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 520))
        cell.configure(
            with: GalleryPost(
                id: PostID("post-1"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: "Third coffee.", publishedAtMS: 0,
                reactionCount: reactions, commentCount: 3, viewCount: nil
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        return cell
    }

    @Test func aTapStakesTheTapAmount() {
        let cell = row()
        var asked: [Int] = []
        cell.stakeTapAmount = 10
        cell.onStake = { asked.append($0) }

        #expect(cell.debugTapLikesChip())
        #expect(asked == [10])
    }

    @Test func anUnwiredChipIsACounter() {
        let cell = row()
        #expect(cell.debugTapLikesChip() == false)
    }

    /// Through the wallet: the balance pays, the surface can take it back.
    @Test func stakingSpendsFromTheWalletAndCanBeUndone() throws {
        let wallet = WalletStore(defaults: Self.defaults())
        let before = wallet.balance
        let staking = PostCardStaking(wallet: wallet)
        let cell = row()
        staking.bind(cell, to: PostID("post-1"))

        #expect(cell.debugTapLikesChip())

        #expect(wallet.balance == before - WalletStore.Policy.tapBoostAmount)
        #expect(wallet.boostTotal(forTarget: "post-1") == WalletStore.Policy.tapBoostAmount)
        #expect(staking.debugUndoable(on: PostID("post-1")) == WalletStore.Policy.tapBoostAmount)

        staking.endSession()
        #expect(staking.debugUndoable(on: PostID("post-1")) == 0)
    }

    /// A recycled row forgets the stake it was wired for — it would otherwise
    /// spend on someone else's post.
    @Test func aRecycledRowForgetsTheStake() {
        let cell = row()
        var asked = 0
        cell.onStake = { _ in asked += 1 }

        cell.prepareForReuse()
        _ = cell.debugTapLikesChip()

        #expect(asked == 0)
    }
}
