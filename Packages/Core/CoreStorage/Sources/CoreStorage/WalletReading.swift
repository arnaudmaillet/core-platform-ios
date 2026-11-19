import Foundation

/// What a screen reads of the viewer's wallet: the balances it shows and what
/// the viewer has staked so far (#2377).
///
/// Modules hold the wallet through this protocol (or `WalletStaking`), never
/// through `WalletStore`. Only the app builds the store. A test can then hand
/// a screen a fake instead of the real store, with its storage, server and
/// launch arguments.
///
/// Observers follow the instance's own `changes` (#2376), so a fake sends
/// its changes there.
public protocol WalletReading: AnyObject, Sendable {
    /// Sent after every balance-affecting change, on whatever thread made it.
    var changes: StoreChanges<Void> { get }
    /// The likes the viewer can spend.
    var balance: Int { get }
    /// What a stake control judges affordability against: the balance, and
    /// no limit for a guest (their tap is the member gate's to answer).
    var stakeableBalance: Int { get }
    /// Shots left in the active stake pack; 0 when none is loaded.
    var stakeShots: Int { get }
    /// The whole wallet, read at once.
    func snapshot() -> WalletSnapshot
    /// Total likes ever boosted into one post or comment, this device.
    func boostTotal(forTarget targetID: String) -> Int
    /// Every stake: the active ones first, soonest to settle first; then the
    /// settled ones, most recent first.
    func stakes() -> [WalletStake]
}

/// What a screen that stakes needs of the wallet: put likes or shots on a
/// target, take them back during the undo window, and commit or settle the
/// stake once the server has answered (#2377).
public protocol WalletStaking: WalletReading {
    func stake(_ spend: WalletStakeSpend, on targetID: String) -> WalletBoostOutcome
    func undoBoost(targetID: String, amount: Int) -> (newBalance: Int, targetTotal: Int)?
    func commitStakes(on targetID: String)
    func settleCommittedStake(targetID: String, asked: Int, spent: Int)
}

extension WalletStore: WalletStaking {}
