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
                reactionCount: reactions, commentCount: 3
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        return cell
    }

    /// The chip's tap stakes the ONE default amount unless told otherwise.
    @Test func aTapStakesTheDefaultAmount() {
        let cell = row()
        var asked: [Int] = []
        #expect(cell.stakeTapAmount == WalletStore.Policy.defaultStakeAmount)
        cell.onStake = { asked.append($0) }

        #expect(cell.debugTapLikesChip())
        #expect(asked == [WalletStore.Policy.defaultStakeAmount])
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

        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(wallet.boostTotal(forTarget: "post-1") == WalletStore.Policy.defaultStakeAmount)
        #expect(staking.debugUndoable(on: PostID("post-1")) == WalletStore.Policy.defaultStakeAmount)

        staking.endSession()
        #expect(staking.debugUndoable(on: PostID("post-1")) == 0)
    }

    /// The card's menu reads the wallet's pack: the default only without one,
    /// "×100 — N left" with one.
    @Test func theCardMenuReadsThePack() {
        let wallet = WalletStore(defaults: Self.defaults())
        let staking = PostCardStaking(wallet: wallet)

        let empty = staking.menuState(for: "post-1")
        #expect(empty.shotsLeft == 0)
        #expect(empty.tapAmount == WalletStore.Policy.defaultStakeAmount)
        #expect(empty.canShoot == false)

        #expect(wallet.buyStakePack() == .bought(
            shots: WalletStore.Policy.StakePack.shots,
            remainingGems: WalletStore.Policy.seededGems - WalletStore.Policy.StakePack.price
        ))
        let loaded = staking.menuState(for: "post-1")
        #expect(loaded.shotsLeft == WalletStore.Policy.StakePack.shots)
        #expect(loaded.shotAmount == WalletStore.Policy.StakePack.pointsPerShot)
        #expect(loaded.canShoot)
    }

    /// A shot from a card: a hundred points in one gesture, one shot off the
    /// pack, and the "+100" receipt's amount is what the wallet spent.
    @Test func aShotFromACardStakesAHundredAndUsesOneShot() {
        let wallet = WalletStore(defaults: Self.defaults())
        wallet.buyStakePack()
        let before = wallet.balance
        let staking = PostCardStaking(wallet: wallet)
        let cell = row()
        staking.bind(cell, to: PostID("post-1"))

        staking.stake(.shot, on: "post-1", cell: cell)

        let shot = WalletStore.Policy.StakePack.pointsPerShot
        #expect(wallet.balance == before - shot)
        #expect(wallet.boostTotal(forTarget: "post-1") == shot)
        #expect(wallet.stakeShots == WalletStore.Policy.StakePack.shots - 1)
        #expect(staking.debugUndoable(on: PostID("post-1")) == shot)
    }

    /// Two shots fill a post but for 50: a third would be clamped, so the
    /// card's menu refuses it — and says how much still fits.
    @Test func aThirdShotOnOnePostIsRefusedByTheMenu() throws {
        let defaults = Self.defaults()
        defaults.set(true, forKey: "wallet.seeded")
        defaults.set(1_000, forKey: "wallet.balance")
        let wallet = WalletStore(defaults: defaults)
        wallet.buyStakePack()
        let staking = PostCardStaking(wallet: wallet)
        let cell = row()
        staking.bind(cell, to: PostID("post-1"))
        staking.stake(.shot, on: "post-1", cell: cell)
        staking.stake(.shot, on: "post-1", cell: cell)

        let state = staking.menuState(for: "post-1")
        #expect(state.stakedOnTarget == 200)
        #expect(state.shotsLeft == 1)
        #expect(state.canShoot == false)
        let shot = try #require(cell.stakeMenu?()?.children.first as? UIAction)
        #expect(shot.attributes.contains(.disabled))
        #expect(shot.subtitle == "Only 50 points more fit on this post")
    }

    /// Without a pack, the card's "×100" row is the Shop's door: enabled
    /// under a screen that can open the Shop, and picking it asks THAT
    /// opener (found up the card's responder chain) for the Shop.
    @Test func theCardsEmptyPackRowOpensTheShop() throws {
        let wallet = WalletStore(defaults: Self.defaults())
        let staking = PostCardStaking(wallet: wallet)
        let screen = ShopOpenerSpy()
        let cell = row()
        screen.view.addSubview(cell)
        staking.bind(cell, to: PostID("post-1"))

        let row = try #require(cell.stakeMenu?()?.children.first as? UIAction)
        #expect(row.title == "×100")
        #expect(row.subtitle == StakeMenu.shopSubtitle(100))
        #expect(row.attributes.contains(.disabled) == false)

        row.performWithSender(nil, target: nil)
        #expect(screen.asked == 1)
        #expect(wallet.boostTotal(forTarget: "post-1") == 0)
    }

    /// No Shop above the card (the fleet): the row stays a disabled signpost.
    @Test func withoutAShopTheEmptyPackRowIsDisabled() throws {
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()))
        let cell = row()
        staking.bind(cell, to: PostID("post-1"))

        let row = try #require(cell.stakeMenu?()?.children.first as? UIAction)
        #expect(row.attributes.contains(.disabled))
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

/// A screen that can open the Shop — counts the asks, builds nothing (a
/// presentation never completes in the test host; `StakeShopTests` covers it).
@MainActor
private final class ShopOpenerSpy: UIViewController, StakeShopOpening {
    var asked = 0
    func makeStakeShop() -> UIViewController? {
        asked += 1
        return nil
    }
}
