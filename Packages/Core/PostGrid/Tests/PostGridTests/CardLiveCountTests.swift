import CoreModels
import CoreStorage
import EntityStore
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A card's count is its post's LIVE one (#896): `PostCardStaking` draws the
/// app's `EntityStore` count on every card it binds, re-draws it when the
/// store moves — a like in the feed, a realtime tick — and tells the store
/// the count a grid loaded for a post no feed has seen.
@MainActor
struct CardLiveCountTests {
    private static func defaults() -> UserDefaults {
        let name = "card-live-count-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func post(_ id: String, likes: Int64?) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/\(id).jpg"),
            caption: "", publishedAtMS: 0, reactionCount: likes
        )
    }

    private func tile(_ post: GalleryPost) -> PostGridTileCell {
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 150, height: 150))
        cell.configure(with: post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    private func row(_ post: GalleryPost) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        cell.configure(with: post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    /// The scenario of the simulator check: a post liked in the vertical feed
    /// is liked on the grid tile it opened from — two surfaces, one count.
    @Test func aLikeInTheFeedReachesEveryBoundTile() {
        let wallet = WalletStore(defaults: Self.defaults())
        let entities = EntityStore()
        let forYou = PostCardStaking(wallet: wallet, entities: entities)
        let profile = PostCardStaking(wallet: wallet, entities: entities)
        let gridTile = tile(Self.post("p1", likes: 40))
        let profileTile = tile(Self.post("p1", likes: 40))
        forYou.bindReadout(gridTile, to: PostID("p1"))
        profile.bindReadout(profileTile, to: PostID("p1"))

        // The vertical feed's like: one point on the post.
        entities.addLikes(1, to: PostID("p1"))

        #expect(gridTile.debugCounterText == "41")
        #expect(profileTile.debugCounterText == "41")
    }

    @Test func aTileBoundAfterAChangeDrawsTheStoresCount() {
        let entities = EntityStore()
        entities.setLikeCount(57, for: PostID("p1"))
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()), entities: entities)
        let cell = tile(Self.post("p1", likes: 40))
        staking.bindReadout(cell, to: PostID("p1"))
        #expect(cell.debugCounterText == "57", "the grid's own copy is older than the store's")
    }

    /// A grid's tile names a post no feed has loaded: its count becomes the
    /// store's, so the next stake has a number to move.
    @Test func aGridTellsTheStoreTheCountItLoaded() {
        let entities = EntityStore()
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()), entities: entities)
        staking.bindReadout(tile(Self.post("p1", likes: 40)), to: PostID("p1"))
        #expect(entities.post(PostID("p1"))?.likeCount == 40)
        // …and never over a count the store knows.
        staking.bindReadout(tile(Self.post("p1", likes: 12)), to: PostID("p1"))
        #expect(entities.post(PostID("p1"))?.likeCount == 40)
    }

    /// The list's card, whose chip stakes: a stake through the wallet moves
    /// its count once (`WalletStakeLikes`) and an undo moves it back.
    @Test func aStakeOnACardMovesItsCountOnce() {
        let scope = StorageScope(owner: .unscoped)
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope)
        let entities = EntityStore()
        let bridge = WalletStakeLikes(wallet: wallet, entities: entities, scope: scope)
        let staking = PostCardStaking(wallet: wallet, entities: entities)
        let card = row(Self.post("p1", likes: 40))
        staking.bind(card, to: PostID("p1"))

        _ = wallet.stake(.likes(2), on: "p1")
        #expect(card.debugReactionCount == 42)
        _ = wallet.undoBoost(targetID: "p1", amount: 2)
        #expect(card.debugReactionCount == 40)
        withExtendedLifetime(bridge) {}
    }

    /// A recycled tile shows another post: a change to the first one leaves
    /// it alone.
    @Test func aRecycledTileFollowsItsNewPost() {
        let entities = EntityStore()
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()), entities: entities)
        let cell = tile(Self.post("p1", likes: 40))
        staking.bindReadout(cell, to: PostID("p1"))
        cell.prepareForReuse()
        cell.configure(with: Self.post("p2", likes: 7), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        staking.bindReadout(cell, to: PostID("p2"))

        entities.setLikeCount(41, for: PostID("p1"))

        #expect(cell.debugCounterText == "7")
    }

    // MARK: - Bare tiles, saves (#896)

    /// A profile's bare tile (its media mosaic) draws a count and no stake:
    /// the count is the live one, the heart stays as drawn — while a tile
    /// wearing its words, bound beside it, reads the stake.
    @Test func aBareTileDrawsTheLiveCountButNotTheStake() async throws {
        let scope = StorageScope(owner: .unscoped)
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope)
        let entities = EntityStore()
        let bridge = WalletStakeLikes(wallet: wallet, entities: entities, scope: scope)
        let staking = PostCardStaking(wallet: wallet, entities: entities)
        let bare = tile(Self.post("p1", likes: 40))
        let worded = tile(Self.post("p1", likes: 40))
        staking.bindCount(bare, to: PostID("p1"))
        staking.bindReadout(worded, to: PostID("p1"))

        // A like from the feed, then a stake from a card elsewhere.
        entities.addLikes(1, to: PostID("p1"))
        #expect(bare.debugCounterText == "41")
        _ = wallet.stake(.likes(2), on: "p1")
        // The wallet's change is delivered on the main queue.
        try await Task.sleep(for: .milliseconds(50))

        #expect(bare.debugCounterText == "43")
        #expect(worded.debugIsStaked, "the control: a worded tile reads the stake")
        #expect(!bare.debugIsStaked, "a bare tile never wears it")
        withExtendedLifetime(bridge) {}
    }

    /// A cell bound with its words, recycled bare: it leaves the stake's
    /// binding (and the other way round).
    @Test func aCellReboundForItsCountAloneLeavesTheStake() async throws {
        let scope = StorageScope(owner: .unscoped)
        let wallet = WalletStore(defaults: Self.defaults(), scope: scope)
        let entities = EntityStore()
        let staking = PostCardStaking(wallet: wallet, entities: entities)
        let cell = tile(Self.post("p1", likes: 40))
        let control = tile(Self.post("p1", likes: 40))
        staking.bindReadout(cell, to: PostID("p1"))
        staking.bindReadout(control, to: PostID("p1"))
        staking.bindCount(cell, to: PostID("p1"))

        _ = wallet.stake(.likes(2), on: "p1")
        try await Task.sleep(for: .milliseconds(50))

        #expect(control.debugIsStaked)
        #expect(!cell.debugIsStaked)
    }

    /// The save glyph: the app's one pile writes the store's fact, so a save
    /// made in the feed (or on another surface's card) re-draws every bound
    /// row's glyph.
    @Test func aSaveMadeElsewhereRedrawsABoundCardsGlyph() {
        let entities = EntityStore()
        let pile = PostBookmarkStore(defaults: Self.defaults(), scope: StorageScope(owner: .member(account: "A", profile: "P1")))
        pile.facts = entities
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()), entities: entities, saves: pile)
        let card = row(Self.post("p1", likes: 40))
        staking.bind(card, to: PostID("p1"))
        #expect(!card.isBookmarked)

        // Saved from the vertical feed's bookmark.
        pile.toggle("p1")
        #expect(card.isBookmarked)
        pile.toggle("p1")
        #expect(!card.isBookmarked)
    }

    /// Without a store a card keeps what it loaded, as before.
    @Test func withoutAStoreTheCardKeepsItsCount() {
        let staking = PostCardStaking(wallet: WalletStore(defaults: Self.defaults()))
        let cell = tile(Self.post("p1", likes: 40))
        staking.bindReadout(cell, to: PostID("p1"))
        #expect(cell.debugCounterText == "40")
    }
}
