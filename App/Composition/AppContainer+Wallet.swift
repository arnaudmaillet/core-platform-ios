import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
#if MOCK_BACKEND
import CoreNetworkingMocks
#endif
import CoreStorage
import DesignSystem
import Feed
import FeedInterface
import Foundation
import Maps
import MediaCore
import MediaPlayback
import UIKit
import Wallet

// Wallet (#2375): the one wallet, its likes outbox, the sheet and the Shop, and
// the economy's sellers. Its properties are declared in `AppContainer.swift`,
// since an extension holds no stored property; they are built here.
extension AppContainer {
    func makeWalletStore() -> WalletStore {
        let store = WalletStore(scope: storageScope)
        // A member's likes are points committed through `wallet.Stake`
        // (#676): every stake lands in the outbox too, and the sender commits
        // it — 10 s after the last tap, on leaving the post, on going to the
        // background — retrying with the batch's key.
        store.likeOutbox = likeOutbox
        // A member's balance and hourly claim are the server's (#1098):
        // wallet.v1 GetWallet / ClaimReward, read by `walletServerSync`.
        store.server = ServerWallet(
            walletClient: Wallet_V1_WalletServiceClient(client: authenticatedRPCClient),
            viewer: viewerSession
        )
        let sender = LikeOutboxSender(outbox: likeOutbox, wallet: store, staking: likeStaking)
        // A final failure is told (#1775): the shell says it over the screen
        // in front.
        sender.onLikesGivenBack = { [likesGivenBack] back in likesGivenBack.send(back.message) }
        sender.start()
        likeOutboxSender = sender
        // Mock mode has no settlement service, so the claim sheet's stake
        // list would open empty on every fresh install. A one-time demo plan
        // stakes on the first mock posts — some active, some settled.
        #if MOCK_BACKEND
        if environment == .mock {
            store.seedDemoStakesIfNeeded(targetIDs: mockBackend.dataset.posts.prefix(8).map(\.postID))
        }
        #endif
        return store
    }

    @MainActor
    func startWalletServerSync() {
        guard walletServerSync == nil else { return }
        let sync = WalletServerSync(wallet: walletStore, scope: storageScope)
        sync.start()
        walletServerSync = sync
    }

    /// The wallet sheet every balance badge presents: the store, plus the
    /// Feed feature's post lookup so each stake row shows its post.
    ///
    /// ⚠️ A MEMBER'S ONLY (#1146): a guest has no badge, no Shop and no
    /// wallet, so no entry point may open it for one — a stray one would show
    /// an empty member wallet.
    func makeWalletSheet() -> UIViewController {
        assert(memberGate.isMember, "the wallet sheet was asked for a guest (#1146)")
        // One sheet with two heights (#1494): the daily glance, and the rest
        // of the wallet below it.
        return WalletScreens.sheet(
            wallet: walletStore,
            lookUpPosts: { [unowned self] ids in await self.feedFeature.galleryPosts(ids) },
            imagePipeline: imagePipeline,
            // A stake row opens its post the way a For You or Profile card
            // does — the same flight, owned by Feed.
            openFeedHero: { [unowned self] ids, presenter, origin in
                self.feedFeature.presentSnapFeedHero(postIDs: ids, from: presenter, origin: origin)
            },
            // "Find a post to stake": the feed, the sheet down.
            findPosts: { [unowned self] in self.router.route(to: .feed) },
            // The Shop door: Maps' storefront, with the account's countries,
            // the Boosts and the profile items. None without countries.
            makeShop: countryAccess.map { countries in
                { [unowned self] in
                    CountryShopViewController.storefront(
                        access: countries, stakePacks: self.stakePacks, profileItems: self.profileItems,
                        media: ShopMedia(images: self.imagePipeline, videos: self.videoPlayback)
                    )
                }
            },
            historyCache: walletHistoryCache,
            // "How it works", once per account: who is here (#2376).
            owner: { [storageScope] in storageScope.owner }
        )
    }

    /// The Shop opened on its Boosts — where the stake menu's "Get ×100
    /// cartridges in the Shop" goes, from the feed rail, the composer and
    /// every card (`ShellTabBarController`, `StakeShopOpening`). The SAME
    /// screen the Wallet's gems card and the Explore header push, with the
    /// same sellers; nil where they sell nothing (no shop door either).
    func makeStakeShopScreen() -> UIViewController? {
        guard let countryAccess, let stakePacks else { return nil }
        return CountryShopViewController.storefront(
            access: countryAccess, stakePacks: stakePacks, profileItems: profileItems,
            focus: .boosts,
            media: ShopMedia(images: imagePipeline, videos: videoPlayback)
        )
    }

    /// Says a stake the server did not spend (#1775), on whatever is in front
    /// in `window`, for as long as the caller holds what this returns.
    func makeStakeRefundNotices(in window: UIWindow) -> AnyObject {
        StakeRefundNotifier(wallet: walletStore, window: window)
    }

    /// The balance badge on a root screen's header: `apply` installs each bar
    /// item it hands over, and the badge lasts as long as the caller holds
    /// what this returns. Its tap presents `makeWalletSheet()` from
    /// `presenter`.
    func makeWalletBadge(
        presenter: UIViewController?, apply: @escaping (UIBarButtonItem) -> Void
    ) -> AnyObject {
        let installer = WalletBadgeInstaller(
            wallet: walletStore,
            presenter: presenter,
            makeSheet: { [unowned self] in self.makeWalletSheet() },
            apply: apply
        )
        #if DEBUG
        // `-open-wallet` (QA, `WalletSheetUITests`): the Profile tab's badge
        // is the one root badge left since For You left the bar (#2455), so
        // it answers the hook. It presents only once its presenter is in the
        // window: pair `-open-wallet` with `-select-tab 2`.
        installer.presentSheetIfAskedAtLaunch()
        #endif
        return installer
    }

    func makeLikeStaking() -> WalletLikeStaking {
        WalletLikeStaking(
            walletClient: Wallet_V1_WalletServiceClient(client: authenticatedRPCClient),
            viewer: viewerSession
        )
    }

    func makeProfileItems() -> ProfileItemService? {
        #if MOCK_BACKEND
        guard environment == .mock else { return nil }
        return ProfileItemService(
            accountID: MockAuthService.accountID,
            wallet: walletStore,
            store: ProfileItemStore(),
            teen: teenProtections,
            isMember: { [unowned self] in self.memberGate.isMember }
        )
        #else
        return nil
        #endif
    }

    func makeStakePacks() -> StakePackService? {
        guard environment.isMock else { return nil }
        return StakePackService(wallet: walletStore)
    }
}
