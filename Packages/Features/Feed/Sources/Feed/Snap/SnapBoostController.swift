import CoreModels
import CoreStorage

/// The boost (stake) flow on the post the feed shows: the wallet's verdict on
/// each spend, the session undo, and what every cell's boost anchor is told.
///
/// The arithmetic is the wallet's (`WalletStore.stake`): the optimistic debit,
/// the per-post cap clamp, the refusal reasons, and the outbox the taps are
/// committed through. What this owns is the SESSION TALLY — the one post that
/// can still be undone, and how much — and its lifetime: the undo window is
/// the post's time on screen.
///
/// The screen keeps the member gate, the haptics, the cell's theatre and the
/// DEBUG `-wallet-log` lines; it hears plain values back.
///
/// Unit-tested without a screen (`SnapBoostControllerTests`).
@MainActor
final class SnapBoostController {
    /// Why the wallet refused a spend — nothing changed.
    enum Refusal: Equatable {
        case insufficientBalance(balance: Int)
        /// The post already holds the viewer's whole allowance.
        case targetCapReached(targetTotal: Int)
        /// The menu offers a shot only with a pack loaded and room on the
        /// post for all of it; a stale menu (the pack emptied, the post
        /// filled on another surface) or `-wallet-demo-shot` lands on these
        /// two.
        case noShotsLeft
        case shotDoesNotFit(room: Int)
    }

    /// What one spend did.
    enum Verdict: Equatable {
        /// `spent`, never the request: a near-cap boost is CLAMPED to the
        /// remainder, and the tally/float must say what actually left the
        /// wallet.
        case boosted(targetTotal: Int, spent: Int)
        case refused(Refusal)
    }

    /// What an undo gave back.
    struct Refund: Equatable {
        var refunded: Int
        var targetTotal: Int
        var newBalance: Int
    }

    /// What a cell's boost anchor is told: what the balance can still
    /// afford, how much of this post is still session-undoable, and the
    /// shots left in the pack.
    struct AnchorContext: Equatable {
        var balance: Int
        var undoable: Int
        var stakeShots: Int
    }

    /// The viewer's point balance, spent by the rail's boost anchor. Nil
    /// (an unwired host) drops every spend silently; the mock store is
    /// always wired in the app itself.
    let wallet: WalletStore?

    /// The active post's UNDOABLE spend: what this screen has boosted onto
    /// it while it stayed the active page. Paging away FINALIZES it — the
    /// lifecycle's resign hook clears the tally — which is the product
    /// rule stated as ownership: the undo window IS the post's time on
    /// screen. One post at a time, because only one post is on screen.
    private(set) var sessionID: PostID?
    private(set) var sessionAmount = 0

    init(wallet: WalletStore?) {
        self.wallet = wallet
    }

    /// One boost spend, wallet-first: the debit lands synchronously (or is
    /// refused) before any pixel moves, so the feedback can never promise a
    /// state the balance doesn't have. Nil without a wallet.
    func stake(_ spend: WalletStakeSpend, on id: PostID) -> Verdict? {
        guard let wallet else { return nil }
        switch wallet.stake(spend, on: id.rawValue) {
        case .boosted(_, let targetTotal, let spent):
            if sessionID == id {
                sessionAmount += spent
            } else {
                sessionID = id
                sessionAmount = spent
            }
            return .boosted(targetTotal: targetTotal, spent: spent)
        case .insufficientBalance(let balance):
            return .refused(.insufficientBalance(balance: balance))
        case .targetCapReached(let targetTotal):
            return .refused(.targetCapReached(targetTotal: targetTotal))
        case .noShotsLeft:
            return .refused(.noShotsLeft)
        case .shotDoesNotFit(let room):
            return .refused(.shotDoesNotFit(room: room))
        }
    }

    /// Takes back the whole session spend on `id` — the menu's Undo entry.
    /// Session-scoped by construction: the guard requires the tally to
    /// still name this post, and the tally dies the moment the post resigns
    /// the active page. Nil when there is nothing to take back.
    func undo(on id: PostID) -> Refund? {
        guard let wallet, sessionID == id, sessionAmount > 0,
              let result = wallet.undoBoost(targetID: id.rawValue, amount: sessionAmount)
        else { return nil }
        let refunded = sessionAmount
        sessionID = nil
        sessionAmount = 0
        return Refund(refunded: refunded, targetTotal: result.targetTotal, newBalance: result.newBalance)
    }

    /// The session-undoable amount on `id`: the tally when it names `id`.
    func undoable(on id: PostID) -> Int {
        sessionID == id ? sessionAmount : 0
    }

    /// What the viewer has already put on `id` (the ledger). Nil without a
    /// wallet.
    func boostTotal(on id: PostID) -> Int? {
        wallet?.boostTotal(forTarget: id.rawValue)
    }

    /// The wallet's current answer for `id`'s anchor. Nil without a wallet.
    func anchorContext(for id: PostID) -> AnchorContext? {
        guard let wallet else { return nil }
        return AnchorContext(
            balance: wallet.stakeableBalance, undoable: undoable(on: id), stakeShots: wallet.stakeShots
        )
    }

    /// Paging away FINALIZES the session's boosts: the undo window is the
    /// post's time on screen, and it just ended — and its taps are
    /// committed now, not 10 s after the last one (#676). Another post
    /// resigning leaves the tally alone.
    func pageResigned(_ id: PostID) {
        guard sessionID == id else { return }
        finalize()
    }

    /// Leaving the screen finalizes the session's boosts, same as paging
    /// away — "undo until you move on", and you just moved on. (The
    /// retained timeline can come back to the same post; the spend is
    /// still final: the window is the visit, not the post.)
    /// The taps are committed now, not 10 s after the last one (#676).
    func finalize() {
        if let id = sessionID { wallet?.commitStakes(on: id.rawValue) }
        sessionID = nil
        sessionAmount = 0
    }
}
