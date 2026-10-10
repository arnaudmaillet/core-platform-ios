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
///     not load, and a failed row with Try Again heads the list.
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
}

/// One row of the wallet sheet's stake list, under its summary.
public enum WalletStakeRow: Hashable, Sendable {
    /// A stake, by its target's id.
    case stake(String)
    /// No active stake: what staking is, where the list would be.
    case noActiveStakes
    /// Some posts could not be loaded: says so, with Try Again.
    case postsFailed
}

/// The stake list as the sheet lays it out: the ACTIVE section, always there
/// (its stakes, or the card saying there are none), and the SETTLED one, nil
/// when nothing has settled. The failed row heads the active section — the
/// head of the list, whichever section the failed posts sit in — so the small
/// detent shows it.
public struct WalletStakeList: Equatable, Sendable {
    public let active: [WalletStakeRow]
    public let settled: [WalletStakeRow]?

    public init(stakes: [WalletStake], loads: WalletStakePostLoads) {
        let activeStakes = stakes.filter { !$0.isSettled }
        let settledStakes = stakes.filter(\.isSettled)
        // Only a failure about a stake still listed: a stake gone from the
        // ledger takes its failure with it.
        let ids = stakes.map(\.targetID)
        let failed = ids.contains { loads.state(of: $0) == .failed }
        var active: [WalletStakeRow] = failed ? [.postsFailed] : []
        active += activeStakes.isEmpty ? [.noActiveStakes] : activeStakes.map { .stake($0.targetID) }
        self.active = active
        self.settled = settledStakes.isEmpty ? nil : settledStakes.map { .stake($0.targetID) }
    }
}
