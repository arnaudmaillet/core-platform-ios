import CoreModels
import CoreStorage
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// The wallet's screens, as the app opens them (#2385). The controllers stay
/// internal to the feature; the composition root asks for a screen and hands
/// in what the wallet cannot reach itself: the Feed feature's posts and
/// flight, the route to the feed, and Maps' Shop.
public enum WalletScreens {
    /// The wallet sheet, wrapped for presentation: one sheet with two
    /// heights (#1494). A member's only (#1146).
    public static func sheet(
        wallet: WalletStore,
        lookUpPosts: (@MainActor ([PostID]) async -> [PostID: GalleryPost])? = nil,
        imagePipeline: ImagePipeline? = nil,
        openFeedHero: (@MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)? = nil,
        findPosts: (() -> Void)? = nil,
        makeShop: (() -> UIViewController)? = nil,
        historyCache: WalletHistoryLocalCache? = nil,
        /// Who is here: the app's one storage scope's owner (#2376).
        owner: @escaping @MainActor () -> StorageScope.Owner
    ) -> UIViewController {
        WalletSheetViewController(
            wallet: wallet, lookUpPosts: lookUpPosts, imagePipeline: imagePipeline, openFeedHero: openFeedHero,
            findPosts: findPosts, makeShop: makeShop, historyCache: historyCache, owner: owner
        ).wrappedInSheet()
    }

    /// The wallet's history: Settings → Wallet and Purchases (#400).
    public static func history(wallet: WalletStore, deviceCache: WalletHistoryLocalCache? = nil) -> UIViewController {
        WalletHistoryViewController(wallet: wallet, deviceCache: deviceCache)
    }
}
