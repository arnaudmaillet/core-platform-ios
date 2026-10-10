import Foundation

/// Where the wallet sheet stands on the POSTS behind its stake rows (#834).
///
/// A stake is read locally and at once (`WalletStore.stakes()`): its amount
/// and its countdown are never in doubt. The post it was placed on — author,
/// caption, thumbnail — is a lookup, and a lookup can be slow or fail. So
/// each stake's post has its own state, and the sheet draws from it:
///
///   • **loading** — asked for, not answered: the row's post part is bones;
///   • **loaded** — the post is in hand: the row is the post;
///   • **failed** — the lookup came back without it: the row says it could
///     not load, and a failed row with Try Again heads its section.
///
/// ⚠️ **ASKED FOR ONCE, ASKED AGAIN ONLY BY TRY AGAIN.** Every wallet change
/// refreshes the sheet; a refresh must not re-ask for a post already on its
/// way or one that failed, or a flaky network would spin the rows between
/// bones and "couldn't load" on every claim tick. Before this type the sheet
/// asked once and never again, so a post that failed stayed a row about
/// nothing for the sheet's lifetime.
///
/// A plain value with no clock and no I/O: the sheet does the asking, this
/// says what to ask for and what each row is.
public struct WalletStakePostLoads: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    private var states: [String: State] = [:]
    /// The posts a Try Again is asking for, until their answer lands.
    private var retrying: Set<String> = []
    /// The latest failure came from a Try Again: the failed row says the
    /// retry did not help, rather than repeating the first message.
    public private(set) var failedAfterRetry = false

    public init() {}

    /// Where `targetID`'s post stands; nil when it was never asked for.
    public func state(of targetID: String) -> State? {
        states[targetID]
    }

    /// The posts among `targetIDs` never asked for, now marked loading: the
    /// ones to look up. Posts loading, loaded or failed are left alone.
    public mutating func begin(_ targetIDs: [String]) -> [String] {
        var fresh: [String] = []
        for id in targetIDs where states[id] == nil && !fresh.contains(id) {
            states[id] = .loading
            fresh.append(id)
        }
        return fresh
    }

    /// A lookup of `requested` answered with `found`: those are loaded, and
    /// every other one asked for failed. True when THIS answer failed a Try
    /// Again — the moment the sheet gives its warning.
    @discardableResult
    public mutating func finish(requested: [String], found: Set<String>) -> Bool {
        let failed = requested.filter { !found.contains($0) }
        for id in requested {
            states[id] = found.contains(id) ? .loaded : .failed
        }
        let retryFailed = failed.contains(where: retrying.contains)
        if !failed.isEmpty {
            failedAfterRetry = retryFailed
        } else if !hasFailures {
            failedAfterRetry = false
        }
        retrying.subtract(requested)
        return retryFailed
    }

    /// Try Again: every failed post back to loading — the ones to look up
    /// again, and only those.
    public mutating func retry() -> [String] {
        let failed = states.filter { $0.value == .failed }.map(\.key).sorted()
        for id in failed { states[id] = .loading }
        retrying.formUnion(failed)
        return failed
    }

    /// True while some post could not be loaded.
    public var hasFailures: Bool {
        states.values.contains(.failed)
    }

    /// True while a Try Again is out for `targetID`'s post.
    public func isRetrying(_ targetID: String) -> Bool {
        retrying.contains(targetID)
    }

    /// True while a Try Again is out: the failed row stays, saying so, until
    /// the answer.
    public var isRetrying: Bool {
        !retrying.isEmpty
    }
}

/// One row of the wallet sheet's stake list, under its summary.
public enum WalletStakeRow: Hashable, Sendable {
    /// A stake, by its target's id.
    case stake(String)
    /// No active stake: what staking is, where the list would be.
    case noActiveStakes
    /// Some posts could not be loaded: says so, with Try Again — or "Trying
    /// again…" while one is out.
    case postsFailed
}

/// The stake list as the sheet lays it out: the ACTIVE section, always there
/// (its stakes, or the card saying there are none), and the SETTLED one, nil
/// when nothing has settled.
///
/// ⚠️ **THE FAILED ROW HEADS A SECTION THAT HAS A FAILED ROW** — the active
/// one when an active stake's post failed, else the settled one — and there
/// is ONE (a Try Again retries every failed post, whichever section). It
/// first headed the active section whatever failed, so a sheet whose only
/// failures were settled stakes said "Couldn't load some posts" right over
/// "No active stakes" (filmed, 10 October 2026).
///
/// ⚠️ **THE FAILED ROW STAYS WHILE ITS TRY AGAIN IS OUT** ("Trying again…"),
/// and leaves only once the retry has loaded everything. Dropping it the
/// moment Try Again was pressed slid every row up under the finger, and a
/// second failure slid them all back down.
///
/// This is the wallet sheet's own layout rule, kept beside `WalletStore` only
/// because the App target has no unit-test target to keep it in.
public struct WalletStakeList: Equatable, Sendable {
    public let active: [WalletStakeRow]
    public let settled: [WalletStakeRow]?

    public init(stakes: [WalletStake], loads: WalletStakePostLoads) {
        let activeStakes = stakes.filter { !$0.isSettled }
        let settledStakes = stakes.filter(\.isSettled)
        // Only a failure about a stake still listed: a stake gone from the
        // ledger takes its failure with it.
        let failing: (WalletStake) -> Bool = {
            loads.state(of: $0.targetID) == .failed || loads.isRetrying($0.targetID)
        }
        let activeFailed = activeStakes.contains(where: failing)
        let settledFailed = !activeFailed && settledStakes.contains(where: failing)
        self.active = activeStakes.isEmpty
            ? [.noActiveStakes]
            : (activeFailed ? [.postsFailed] : []) + activeStakes.map { .stake($0.targetID) }
        self.settled = settledStakes.isEmpty
            ? nil
            : (settledFailed ? [.postsFailed] : []) + settledStakes.map { .stake($0.targetID) }
    }
}
