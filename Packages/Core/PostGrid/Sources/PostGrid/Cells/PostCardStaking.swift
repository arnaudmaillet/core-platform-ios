import CoreModels
import CoreStorage
import DesignSystem
import EntityStore
import UIKit
import CoreNavigation

/// What a card's like chip does with a wallet — one object per SURFACE (a For
/// You page, a profile gallery), shared by every row it draws.
///
/// ⚠️ **THE RAIL'S RULES, ON A CARD.** The feed's boost button settled them
/// first and this repeats them exactly, because they are one spend reached
/// from two places:
///   • wallet-first: the debit lands (or is refused) before a pixel moves, so
///     the card never promises a state the balance does not have;
///   • `spent`, never the request — a stake near the post's cap is clamped;
///   • a medium impact on a stake, an error notification on a refusal;
///   • the long press raises `StakeMenu`, the rail's menu, with an Undo for
///     what THIS surface staked while it was on screen (`endSession` closes
///     that window, as paging away does in the feed).
///
/// The card reads the store's answer back rather than counting for itself,
/// so a stake placed in the feed shows on the card that opened it the moment
/// the store says so (`didChangeNotification`).
///
/// The COUNT too, from the app's `EntityStore` (#896): every bound card draws
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
    private let wallet: WalletStore
    private let entities: EntityStore?
    /// Where a bound row's save glyph reads its answer back.
    private let saves: PostBookmarkStore
    private var entityObservation: EntityObservation?
    /// Which post each bound row shows — keyed by the CELL, weakly: a row is
    /// recycled onto another post, and keyed by post it would stay listed
    /// under the one it no longer draws.
    private let cells = NSMapTable<UIView, NSString>.weakToStrongObjects()
    /// The readouts bound for their count alone (`bindCount`): a bare tile,
    /// whose heart never shows the viewer's stake.
    private let countCells = NSMapTable<UIView, NSString>.weakToStrongObjects()
    /// What this surface staked since its session opened, per post.
    private var session: [String: Int] = [:]
    /// The stake toast up for one of those bursts (#957), and its post.
    private weak var stakeToast: ToastView?
    private var stakeToastKey: String?
    private var observer: NSObjectProtocol?

    /// Each card keeps the count its post was configured with.
    public convenience init(wallet: WalletStore) {
        self.init(wallet: wallet, entities: nil)
    }

    /// - Parameter entities: where the cards' counts come from. Nil: each
    ///   card keeps the count its post was configured with.
    /// - Parameter saves: the pile whose answers a bound row's save glyph
    ///   draws again when the store says a save changed.
    public init(wallet: WalletStore, entities: EntityStore?, saves: PostBookmarkStore = .shared) {
        self.wallet = wallet
        self.entities = entities
        self.saves = saves
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBoundCells() }
        }
        entityObservation = entities?.observePosts { [weak self] change in
            self?.refreshCounts(change)
        }
    }

    /// Wires `cell`'s like chip to stake on `postID`. Call after
    /// `configure(with:)`.
    public func bind(_ cell: PostGridListRowCell, to postID: PostID) {
        let key = postID.rawValue
        countCells.removeObject(forKey: cell)
        cells.setObject(key as NSString, forKey: cell)
        cell.stakeTapAmount = WalletStore.Policy.defaultStakeAmount
        cell.onStake = { [weak self, weak cell] amount in
            guard let self, let cell else { return }
            stake(.likes(amount), on: key, cell: cell, source: cell)
        }
        cell.stakeMenu = { [weak self, weak cell] in
            // A guest gets no stake menu (#1146): no amounts, no way into the
            // Shop. Their tap on the like still asks them to sign up.
            guard let self, let cell, !MemberGates.isGuest(cell) else { return nil }
            return StakeMenu.menu(
                for: menuState(for: key),
                stake: { [weak self, weak cell] amount in
                    guard let self, let cell else { return }
                    stake(.likes(amount), on: key, cell: cell, source: cell)
                },
                shoot: { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    stake(.shot, on: key, cell: cell, source: cell)
                },
                undo: { [weak self, weak cell] in
                    guard let self else { return }
                    undo(on: key, cell: cell)
                },
                // The empty pack's row opens the Shop, found up the card's
                // responder chain (`StakeShopOpening`) — For You, a profile,
                // a place page alike.
                openShop: StakeShop.openAction(from: cell)
            )
        }
        cell.setViewerStake(wallet.boostTotal(forTarget: key))
        showLiveCount(on: cell, for: postID)
    }

    /// Keeps `readout`'s heart on what the viewer has staked on `postID` —
    /// now, and whenever the wallet moves (a stake placed in the feed shows
    /// on the card that opened it) — WITHOUT making it a control: nothing on
    /// it spends. For You's compact cards (`PostLikeReadoutView`, a mosaic
    /// tile's count). Call after `configure(with:)`.
    public func bindReadout(_ readout: any PostCardLikeReadout, to postID: PostID) {
        let key = postID.rawValue
        countCells.removeObject(forKey: readout)
        cells.setObject(key as NSString, forKey: readout)
        readout.setViewerStake(wallet.boostTotal(forTarget: key))
        showLiveCount(on: readout, for: postID)
    }

    /// Keeps `readout`'s COUNT on its post's live one, and nothing else: a
    /// bare tile (a profile's media mosaic) draws a count without wearing the
    /// viewer's stake, so its heart stays as `configure` drew it. Call after
    /// `configure(with:)`.
    public func bindCount(_ readout: any PostCardLikeReadout, to postID: PostID) {
        cells.removeObject(forKey: readout)
        countCells.setObject(postID.rawValue as NSString, forKey: readout)
        showLiveCount(on: readout, for: postID)
    }

    /// The post's live count, on a card just configured with its post's:
    /// the store learns the card's count if it knew none, and the card
    /// draws the store's.
    private func showLiveCount(on readout: any PostCardLikeReadout, for postID: PostID) {
        guard let entities else { return }
        if let carried = readout.postLikeCount {
            entities.mergeCounts([postID: PostCounts(likes: carried)], freshness: .ifUnknown)
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
        wallet.boostTotal(forTarget: postID.rawValue)
    }

    /// The surface left the screen. A burst whose toast is still up stays
    /// undoable — the toast follows the screen on top and commits the burst
    /// when it ends (#1375, the owner 2026-10-18); every other tap of the
    /// session is committed now (#676).
    public func endSession() {
        let live = stakeToast.flatMap { $0.isDismissing ? nil : stakeToastKey }
        for postID in session.keys where postID != live { wallet.commitStakes(on: postID) }
        session = session.filter { $0.key == live }
    }

    // MARK: - Spending

    /// Internal for tests: the menu's state is the testable seam (a raised
    /// menu cannot be read back from a cell).
    func menuState(for key: String) -> StakeMenu.State {
        StakeMenu.State(
            balance: wallet.stakeableBalance,
            stakedOnTarget: wallet.boostTotal(forTarget: key),
            undoable: session[key] ?? 0,
            perTargetCap: WalletStore.Policy.perTargetBoostCap,
            tapAmount: WalletStore.Policy.defaultStakeAmount,
            shotsLeft: wallet.stakeShots,
            shotAmount: WalletStore.Policy.StakePack.likesPerShot
        )
    }

    /// The stake menu for `postID` raised from anywhere — a post's long-press
    /// or "..." menu (#1498: the palette's ♥ opens the amounts, the owner's
    /// choice). The card that shows the post, if one is bound, plays the
    /// receipt; the toast rises from `source`'s screen. Nil for a guest
    /// (#1146), as on the card.
    public func stakeMenu(for postID: PostID, from source: UIView) -> UIMenu? {
        guard !MemberGates.isGuest(source) else { return nil }
        let key = postID.rawValue
        return StakeMenu.menu(
            for: menuState(for: key),
            stake: { [weak self, weak source] amount in
                guard let self, let source else { return }
                stake(.likes(amount), on: key, cell: boundRow(for: key), source: source)
            },
            shoot: { [weak self, weak source] in
                guard let self, let source else { return }
                stake(.shot, on: key, cell: boundRow(for: key), source: source)
            },
            undo: { [weak self] in
                guard let self else { return }
                undo(on: key, cell: boundRow(for: key))
            },
            openShop: StakeShop.openAction(from: source)
        )
    }

    func stake(_ spend: WalletStakeSpend, on key: String, cell: PostGridListRowCell?, source: UIView) {
        if case .likes(let amount) = spend, amount <= 0 { return }
        // A guest signs up first; the stake then lands on the cell that asked,
        // if it still shows this post.
        MemberGates.perform(.like, from: source) { [weak self, weak cell, weak source] in
            guard let self, let source else { return }
            self.commitStake(spend, on: key, cell: cell, source: source)
        }
    }

    private func commitStake(_ spend: WalletStakeSpend, on key: String, cell: PostGridListRowCell?, source: UIView) {
        switch wallet.stake(spend, on: key) {
        case .boosted(_, let targetTotal, let spent):
            session[key, default: 0] += spent
            Haptics.play(.commit)
            // Receipt before theatre, as on the rail: the heart's ink first,
            // then the "+N" rising off it.
            if let cell, isBound(cell, to: key) {
                cell.setViewerStake(targetTotal)
                cell.playStakeConfirmation(amount: spent)
            }
            showStakeToast(on: key, from: cell ?? source)
        case .insufficientBalance, .targetCapReached, .noShotsLeft, .shotDoesNotFit:
            Haptics.play(.error)
            if let cell, isBound(cell, to: key) { cell.playStakeDenied() }
        }
    }

    private func undo(on key: String, cell: PostGridListRowCell?) {
        guard let amount = session[key], amount > 0,
              let result = wallet.undoBoost(targetID: key, amount: amount) else { return }
        session[key] = nil
        // The burst is taken back: its toast closing must not send it.
        _ = bursts[key]?.next()
        bursts[key] = nil
        if stakeToastKey == key { closeStakeToast() }
        // Turning off is silent (#1881).
        if let cell, isBound(cell, to: key) {
            cell.setViewerStake(result.targetTotal)
            cell.playStakeRefund(amount: amount)
        }
    }

    /// The burst so far on `key`, with Undo for all of it (#957), fired from
    /// the screen showing `cell`. Its Undo reaches whichever row shows the
    /// post by then.
    private func showStakeToast(on key: String, from cell: UIView) {
        guard let screen = Self.screen(of: cell), let amount = session[key] else { return }
        stakeToastKey = key
        let burst = bursts[key] ?? StakeMenu.Burst()
        bursts[key] = burst
        let generation = burst.next()
        let wallet = wallet
        stakeToast = StakeMenu.undoToast(
            staked: amount, on: key, from: screen,
            // The toast ending without an undo sends the burst — even once
            // the surface that staked is gone. An in-place update (the next
            // tap) is not an end.
            commit: { [weak self] in
                guard burst.isCurrent(generation) else { return }
                wallet.commitStakes(on: key)
                self?.burstCommitted(on: key)
            },
            undo: { [weak self] in
                if let self {
                    self.undo(on: key, cell: self.boundRow(for: key))
                } else {
                    // The surface is gone; the toast is not: take the burst
                    // back from the wallet itself.
                    _ = wallet.undoBoost(targetID: key, amount: amount)
                }
            }
        )
    }

    /// One `Burst` per post: numbers its toasts.
    private var bursts: [String: StakeMenu.Burst] = [:]

    /// The burst's toast ended and sent it: no longer undoable.
    private func burstCommitted(on key: String) {
        session[key] = nil
        bursts[key] = nil
        if stakeToastKey == key {
            stakeToast = nil
            stakeToastKey = nil
        }
    }

    private func closeStakeToast() {
        StakeMenu.closeUndoToast(stakeToast)
        stakeToast = nil
        stakeToastKey = nil
    }

    private static func screen(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    private func boundRow(for key: String) -> PostGridListRowCell? {
        let enumerator = cells.keyEnumerator()
        while let cell = enumerator.nextObject() as? PostGridListRowCell {
            if isBound(cell, to: key) { return cell }
        }
        return nil
    }

    /// Whether `cell` still shows `key` — a row can be recycled between the
    /// press and the store's answer.
    private func isBound(_ cell: UIView, to key: String) -> Bool {
        (cells.object(forKey: cell) as String?) == key
    }

    /// The store moved (a stake elsewhere, a refund): every bound row reads
    /// its post's total back.
    private func refreshBoundCells() {
        let enumerator = cells.keyEnumerator()
        while let cell = enumerator.nextObject() as? any PostCardLikeReadout {
            guard let key = cells.object(forKey: cell) else { continue }
            cell.setViewerStake(wallet.boostTotal(forTarget: key as String))
        }
    }

    #if DEBUG
    /// Internal for tests: what this surface can still take back on a post.
    public func debugUndoable(on postID: PostID) -> Int { session[postID.rawValue] ?? 0 }
    #endif
}
