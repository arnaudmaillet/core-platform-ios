import CoreModels
import CoreStorage
import DesignSystem
import EntityStore
import UIKit

/// What a card's like chip does with a wallet — one object per SURFACE (a For
/// You page, a profile gallery), shared by every row it draws.
///
/// The STAKE is the surface's `StakeSession` (#2532), the one every stake
/// control spends through — the feed's rail, the comments bar, a card: wallet
/// first, the clamp, the haptics, the receipts on the chip, the undo toast and
/// its burst, the menu's Undo while that toast is up. This wires the chips to
/// it and keeps the two jobs that are not staking:
///
/// The COUNT, from the app's `EntityStore` (#896): every bound card draws
/// its post's live count — a stake from any surface (`WalletStakeLikes`), a
/// realtime tick or a fresher read the feed made — and tells the store the
/// count its own post carried, for a post no feed has loaded yet. A bare
/// tile, which draws a count but no heart, binds its count alone
/// (`bindCount`).
///
/// And the SAVE glyph of every bound row: the store's saved fact is written
/// by the app's one `PostBookmarkStore`, so a save made in the feed, on
/// another surface's card or on the post page re-draws the row's glyph here.
@MainActor
public final class PostCardStaking {
    /// The surface's stakes: every bound chip spends through it.
    private let stakes: StakeSession
    /// The posts' live counts, through the store's post seams (#2377).
    private let entities: (any PostEntityReading & PostEntityWriting)?
    /// Where a bound row's save glyph reads its answer back.
    private let saves: PostBookmarkStore
    private var entityObservation: EntityObservation?
    /// Which post each bound card shows, for its count and save glyph — keyed
    /// by the CELL, weakly: a row is recycled onto another post, and keyed by
    /// post it would stay listed under the one it no longer draws.
    private let cells = NSMapTable<UIView, NSString>.weakToStrongObjects()
    /// The readouts bound for their count alone (`bindCount`): a bare tile,
    /// whose heart never shows the viewer's stake.
    private let countCells = NSMapTable<UIView, NSString>.weakToStrongObjects()

    /// Each card keeps the count its post was configured with.
    public convenience init(wallet: any WalletStaking, saves: PostBookmarkStore) {
        self.init(wallet: wallet, entities: nil, saves: saves)
    }

    /// - Parameter entities: where the cards' counts come from. Nil: each
    ///   card keeps the count its post was configured with.
    /// - Parameter saves: the pile whose answers a bound row's save glyph
    ///   draws again when the store says a save changed: the app's one
    ///   (#2376).
    public init(
        wallet: any WalletStaking,
        entities: (any PostEntityReading & PostEntityWriting)?,
        saves: PostBookmarkStore
    ) {
        stakes = StakeSession(wallet: wallet)
        self.entities = entities
        self.saves = saves
        entityObservation = entities?.observePosts { [weak self] change in
            self?.refreshCounts(change)
        }
    }

    /// Wires `cell`'s like chip to stake on `postID`. Call after
    /// `configure(with:)`.
    public func bind(_ cell: PostGridListRowCell, to postID: PostID) {
        countCells.removeObject(forKey: cell)
        cells.setObject(postID.rawValue as NSString, forKey: cell)
        cell.stakeTapAmount = WalletStore.Policy.defaultStakeAmount
        cell.onStake = { [weak self, weak cell] amount in
            guard let self, let cell else { return }
            stakes.stake(.likes(amount), on: postID, from: cell)
        }
        // The empty pack's row opens the Shop, found up the card's responder
        // chain (`StakeShopOpening`) — For You, a profile, a place page alike.
        cell.stakeMenu = { [weak self, weak cell] in
            guard let self, let cell else { return nil }
            return stakes.menu(for: postID, from: cell)
        }
        stakes.bind(cell, to: postID)
        showLiveCount(on: cell, for: postID)
    }

    /// Keeps `readout`'s heart on what the viewer has staked on `postID` —
    /// now, and whenever the wallet moves (a stake placed in the feed shows
    /// on the card that opened it) — WITHOUT making it a control: nothing on
    /// it spends. For You's compact cards (`PostLikeReadoutView`, a mosaic
    /// tile's count). Call after `configure(with:)`.
    public func bindReadout(_ readout: any PostCardLikeReadout, to postID: PostID) {
        countCells.removeObject(forKey: readout)
        cells.setObject(postID.rawValue as NSString, forKey: readout)
        stakes.bindReadout(readout, to: postID)
        showLiveCount(on: readout, for: postID)
    }

    /// Keeps `readout`'s COUNT on its post's live one, and nothing else: a
    /// bare tile (a profile's media mosaic) draws a count without wearing the
    /// viewer's stake, so its heart stays as `configure` drew it. Call after
    /// `configure(with:)`.
    public func bindCount(_ readout: any PostCardLikeReadout, to postID: PostID) {
        cells.removeObject(forKey: readout)
        stakes.unbind(readout)
        countCells.setObject(postID.rawValue as NSString, forKey: readout)
        showLiveCount(on: readout, for: postID)
    }

    /// The post's live count, on a card just configured with its post's:
    /// the store learns the card's count if it knew none, and the card
    /// draws the store's.
    private func showLiveCount(on readout: any PostCardLikeReadout, for postID: PostID) {
        guard let entities else { return }
        if let carried = readout.postLikeCount {
            entities.mergeCounts([postID: PostCounts(likes: carried)], tier: .recent, freshness: .ifUnknown)
        }
        if let live = entities.post(postID)?.likeCount { readout.showLikeCount(live) }
    }

    /// The store moved: every bound card of a changed post draws its count,
    /// and every bound row its save glyph (a viewer change, `.everything`,
    /// re-reads them all).
    private func refreshCounts(_ change: EntityChange<PostID>) {
        guard let entities else { return }
        for table in [cells, countCells] {
            let enumerator = table.keyEnumerator()
            while let cell = enumerator.nextObject() as? any PostCardLikeReadout {
                guard let key = table.object(forKey: cell) as String? else { continue }
                let postID = PostID(key)
                guard change.contains(postID) else { continue }
                if let live = entities.post(postID)?.likeCount { cell.showLikeCount(live) }
                if let row = cell as? PostGridListRowCell { row.isBookmarked = saves.isSaved(key) }
            }
        }
    }

    /// `post` with its live like count — for a copy of a card (a flight's
    /// card, a close's stand-in), which must draw the number the bound card
    /// draws, or the count changes in the landing frame. `post` itself when
    /// the store knows no count, or the card draws none.
    public func liveCopy(of post: GalleryPost) -> GalleryPost {
        guard let entities, post.reactionCount != nil,
              let live = entities.post(post.id)?.likeCount else { return post }
        var copy = post
        copy.reactionCount = live
        return copy
    }

    /// What the viewer has staked on `postID` — the answer a bound row draws,
    /// for a stand-in that has no binding (`RevealDismissCardView.RowActions`).
    public func viewerStake(on postID: PostID) -> Int {
        stakes.total(on: postID)
    }

    /// The surface left the screen (`StakeSession.end`). A burst whose toast
    /// is still up stays undoable — the toast follows the screen on top and
    /// commits the burst when it ends (#1375, the owner 2026-10-18); a burst
    /// with no toast is committed now (#676).
    public func endSession() {
        stakes.end()
    }

    // MARK: - Spending

    /// Internal for tests: the menu's state is the testable seam (a raised
    /// menu cannot be read back from a cell).
    func menuState(for key: String) -> StakeMenu.State {
        stakes.menuState(for: PostID(key))
    }

    /// The stake menu for `postID` raised from anywhere — a post's long-press
    /// or "..." menu (#1498: the palette's ♥ opens the amounts, the owner's
    /// choice). The card that shows the post, if one is bound, plays the
    /// receipt; the toast rises from `source`'s screen. Nil for a guest
    /// (#1146), as on the card.
    public func stakeMenu(for postID: PostID, from source: UIView) -> UIMenu? {
        stakes.menu(for: postID, from: source)
    }

    /// Internal for tests: one stake, as the chip (`cell`) or a menu raised
    /// from `source` asks it.
    func stake(_ spend: WalletStakeSpend, on key: String, cell: PostGridListRowCell?, source: UIView) {
        stakes.stake(spend, on: PostID(key), from: cell ?? source)
    }

    #if DEBUG
    /// Internal for tests: what this surface can still take back on a post.
    public func debugUndoable(on postID: PostID) -> Int { stakes.menuState(for: postID).undoable }
    #endif
}
