import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import ThreadKit
import UIKit

/// What the composer's boost asks of its panel (#2523): the composer, the
/// post, whether the post's actions still show, and the panel's notices.
///
/// A view controller: the member gate and the stake toast are presented
/// from it, never from the boost.
@MainActor
protocol PostDetailComposerBoostHost: UIViewController {
    var composeBar: CommentsInputBar { get }
    var viewModel: PostDetailViewModel { get }
    var showsPostActions: Bool { get }
    func presentNotice(_ title: String, _ message: String)
}

/// The composer's boost, out of `PostDetailViewController` (#2523): the
/// spend through the member gate, its theatre on the bar, the stake toast
/// that is the burst's undo window (#957, #1375), the session undo, the
/// commit on leaving and the wallet's observation.
///
/// ⚠️ SYNCHRONOUS WITH ITS PANEL: every entry point runs in the caller's
/// turn, where the panel ran it before. The panel alone holds it, so it
/// goes with the panel, as the boost's state did.
@MainActor
final class PostDetailComposerBoost {
    private unowned let host: any PostDetailComposerBoostHost
    /// The viewer's point balance, spent by the compose bar's boost button.
    /// Injected (one instance app-wide — the map's badge watches it); nil
    /// leaves the button visible but inert.
    private let wallet: (any WalletStaking)?
    /// Keeps the compose bar's receipt honest when the SAME post is boosted
    /// through another surface (a text page shows this bar and the snap
    /// screen's spend path at once). It stops observing when it goes, with
    /// this controller: a nonisolated deinit has nothing to undo.
    private var walletObservation: StoreObservation?
    /// The session's undoable spend through THIS bar. Its window is this
    /// controller's lifetime, which IS the product rule: the embedded
    /// comments panel is torn down when the page changes, so moving on
    /// finalizes the spend.
    private var sessionBoostAmount = 0
    /// The stake toast up for that spend (#957), closed with the window.
    private weak var stakeToast: ToastView?

    init(host: any PostDetailComposerBoostHost, wallet: (any WalletStaking)?) {
        self.host = host
        self.wallet = wallet
    }

    /// Takes back everything this bar spent while the screen stayed up — the
    /// menu's Undo entry and the stake toast's (#957).
    private func undoSessionBoost() {
        guard let wallet, sessionBoostAmount > 0, let postID = host.viewModel.postID,
              let result = wallet.undoBoost(targetID: postID.rawValue, amount: sessionBoostAmount)
        else { return }
        let refunded = sessionBoostAmount
        sessionBoostAmount = 0
        // Taken back: the toast closing must not send it.
        _ = stakeBurst.next()
        // Turning off is silent (#1881).
        host.composeBar.setBoostTotal(result.targetTotal, animated: true)
        host.composeBar.playBoostRefund(amount: refunded)
        refreshComposeBarBoostState()
        StakeMenu.closeUndoToast(stakeToast)
    }

    /// Leaving the post commits its likes now, rather than 10 s after the
    /// last tap (#676) — unless its stake toast is still up: the toast
    /// follows the screen on top, its Undo live, and sends the burst when
    /// it ends (#1375, the owner 2026-10-18).
    func commitUnlessToastIsUp() {
        let toastIsUp = stakeToast.map { !$0.isDismissing } ?? false
        if !toastIsUp, let postID = host.viewModel.postID { wallet?.commitStakes(on: postID.rawValue) }
    }

    /// Numbers this screen's stake toasts (`StakeMenu.Burst`).
    private let stakeBurst = StakeMenu.Burst()

    /// Pushes the wallet's current answer — affordability and the session
    /// tally — into the bar's boost button: the enable state and the menu
    /// it will build on its next long-press both derive from it.
    private func refreshComposeBarBoostState() {
        guard let wallet else { return }
        host.composeBar.setBoostContext(
            balance: wallet.stakeableBalance, undoableAmount: sessionBoostAmount, stakeShots: wallet.stakeShots
        )
    }

    /// The boost button's opening face: this viewer's spend on this post so
    /// far, from the wallet's ledger — nothing on a draft, which is not a post.
    func refreshBoostTotal() {
        guard let wallet else { return }
        host.composeBar.setBoostTotal(host.viewModel.postID.map { wallet.boostTotal(forTarget: $0.rawValue) } ?? 0)
        refreshComposeBarBoostState()
    }

    /// Wires the bar's boost button, its Undo entry and its opening face:
    /// `configureComposeBar`, once.
    func install() {
        // The bar's boost button: wallet verdict here, theatre back on the
        // bar — the snap rail's exact contract, on the comments surface.
        // Debit-first, so the animation never promises a state the balance
        // doesn't have. Nil wallet (an unwired host) leaves the tap inert.
        host.composeBar.onBoost = { [weak self] spend in
            guard let self else { return }
            // A guest signs up first; the boost then lands as asked.
            MemberGates.perform(.like, from: self.host) { [weak self] in
                // A sign-up that finished after the post went unavailable
                // (#1404) has nothing left to boost.
                guard let self, self.host.showsPostActions, let wallet = self.wallet else { return }
                // A DRAFT is not a post yet, and a boost has nothing to land on —
                // said, rather than spent against an id that does not exist.
                guard let postID = self.host.viewModel.postID else {
                    return self.host.presentNotice("Boost", "You can boost your post once it's published.")
                }
                switch wallet.stake(spend, on: postID.rawValue) {
                case .boosted(_, let targetTotal, let spent):
                    // `spent`, never the request — a near-cap boost is clamped.
                    self.sessionBoostAmount += spent
                    Haptics.play(.commit)
                    // Receipt before theatre — the button flips to (or grows)
                    // its number face, then the "+N" float rises off it.
                    self.host.composeBar.setBoostTotal(targetTotal, animated: true)
                    self.host.composeBar.playBoostConfirmation(amount: spent)
                    // The burst so far, with Undo for all of it (#957) — until
                    // the toast ends, wherever it has followed to (#1375).
                    let burst = self.stakeBurst
                    let generation = burst.next()
                    let amount = self.sessionBoostAmount
                    let key = postID.rawValue
                    self.stakeToast = StakeMenu.undoToast(
                        staked: amount, on: key, from: self.host,
                        commit: { [weak self] in
                            guard burst.isCurrent(generation) else { return }
                            wallet.commitStakes(on: key)
                            self?.sessionBoostAmount = 0
                        },
                        undo: { [weak self] in
                            if let self {
                                self.undoSessionBoost()
                            } else {
                                _ = wallet.undoBoost(targetID: key, amount: amount)
                            }
                        }
                    )
                case .insufficientBalance, .targetCapReached, .noShotsLeft, .shotDoesNotFit:
                    Haptics.play(.error)
                    self.host.composeBar.playBoostDenied()
                }
                self.refreshComposeBarBoostState()
            }
        }
        // The menu's Undo entry: takes back everything this bar spent while
        // the screen stayed up. Session-scoped by construction — the tally
        // lives on this controller, and this controller dies with the visit.
        host.composeBar.onBoostUndo = { [weak self] in self?.undoSessionBoost() }
        // The button's opening face: this viewer's spend so far on this
        // post, from the wallet's ledger — a boosted post greets its
        // booster with the receipt, not the invitation. The observer keeps
        // it honest against spends made through any other surface.
        if let wallet {
            refreshBoostTotal()
            walletObservation = wallet.changes.observeOnMain { [weak self] in
                self?.refreshBoostTotal()
            }
        }
    }
}

extension PostDetailViewController: PostDetailComposerBoostHost {}
