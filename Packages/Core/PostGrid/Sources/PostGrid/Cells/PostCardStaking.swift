import CoreModels
import CoreStorage
import DesignSystem
import UIKit

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
@MainActor
public final class PostCardStaking {
    private let wallet: WalletStore
    /// Which post each bound row shows — keyed by the CELL, weakly: a row is
    /// recycled onto another post, and keyed by post it would stay listed
    /// under the one it no longer draws.
    private let cells = NSMapTable<PostGridListRowCell, NSString>.weakToStrongObjects()
    /// What this surface staked since its session opened, per post.
    private var session: [String: Int] = [:]
    private var observer: NSObjectProtocol?

    public init(wallet: WalletStore) {
        self.wallet = wallet
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBoundCells() }
        }
    }

    /// Wires `cell`'s like chip to stake on `postID`. Call after
    /// `configure(with:)`.
    public func bind(_ cell: PostGridListRowCell, to postID: PostID) {
        let key = postID.rawValue
        cells.setObject(key as NSString, forKey: cell)
        cell.stakeTapAmount = WalletStore.Policy.tapBoostAmount
        cell.onStake = { [weak self, weak cell] amount in
            guard let self, let cell else { return }
            stake(amount, on: key, cell: cell)
        }
        cell.stakeMenu = { [weak self, weak cell] in
            guard let self else { return nil }
            return StakeMenu.menu(
                for: menuState(for: key),
                stake: { [weak self, weak cell] amount in
                    guard let self, let cell else { return }
                    stake(amount, on: key, cell: cell)
                },
                undo: { [weak self, weak cell] in
                    guard let self else { return }
                    undo(on: key, cell: cell)
                }
            )
        }
        cell.setViewerStake(wallet.boostTotal(forTarget: key))
    }

    /// Closes the undo window — the surface left the screen.
    public func endSession() {
        session.removeAll()
    }

    // MARK: - Spending

    private func menuState(for key: String) -> StakeMenu.State {
        StakeMenu.State(
            balance: wallet.balance,
            stakedOnTarget: wallet.boostTotal(forTarget: key),
            undoable: session[key] ?? 0,
            perTargetCap: WalletStore.Policy.perTargetBoostCap,
            denominations: WalletStore.Policy.boostDenominations,
            tapAmount: WalletStore.Policy.tapBoostAmount
        )
    }

    private func stake(_ amount: Int, on key: String, cell: PostGridListRowCell) {
        guard amount > 0 else { return }
        switch wallet.boost(targetID: key, amount: amount) {
        case .boosted(_, let targetTotal, let spent):
            session[key, default: 0] += spent
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // Receipt before theatre, as on the rail: the heart's ink first,
            // then the "+N" rising off it.
            if isBound(cell, to: key) {
                cell.setViewerStake(targetTotal)
                cell.playStakeConfirmation(amount: spent)
            }
        case .insufficientBalance, .targetCapReached:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if isBound(cell, to: key) { cell.playStakeDenied() }
        }
    }

    private func undo(on key: String, cell: PostGridListRowCell?) {
        guard let amount = session[key], amount > 0,
              let result = wallet.undoBoost(targetID: key, amount: amount) else { return }
        session[key] = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let cell, isBound(cell, to: key) {
            cell.setViewerStake(result.targetTotal)
            cell.playStakeRefund(amount: amount)
        }
    }

    /// Whether `cell` still shows `key` — a row can be recycled between the
    /// press and the store's answer.
    private func isBound(_ cell: PostGridListRowCell, to key: String) -> Bool {
        (cells.object(forKey: cell) as String?) == key
    }

    /// The store moved (a stake elsewhere, a refund): every bound row reads
    /// its post's total back.
    private func refreshBoundCells() {
        let enumerator = cells.keyEnumerator()
        while let cell = enumerator.nextObject() as? PostGridListRowCell {
            guard let key = cells.object(forKey: cell) else { continue }
            cell.setViewerStake(wallet.boostTotal(forTarget: key as String))
        }
    }

    #if DEBUG
    /// Internal for tests: what this surface can still take back on a post.
    public func debugUndoable(on postID: PostID) -> Int { session[postID.rawValue] ?? 0 }
    #endif
}
