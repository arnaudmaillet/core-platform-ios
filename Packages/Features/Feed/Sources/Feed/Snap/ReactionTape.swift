import Foundation

/// The reaction band's tape (#2005): per lane, an APPEND-ONLY sequence of
/// reactions read at indexes that only grow, instead of the old queue read
/// modulo its length — which replayed the same sequence every cycle, and
/// almost at once under a fast scrub.
///
/// - **Forward:** a lane nearing the end of its tape gets the next CYCLE: the
///   pool shuffled again (seeded by the band and the cycle number), dealt
///   between the lanes so a cycle never puts one reaction in both, at most
///   `cycleSize` long.
/// - **Backward:** a scrub back reads what was shown, exactly. Past the
///   tape's start (the first seconds of a page) a cycle is laid in front.
/// - **Fresh entries are chosen at the write head** (`item(lane:at:avoiding:)`):
///   a reaction on screen in either lane, or among this lane's last few, is
///   swapped for the next one that is not — while the pool allows it.
/// - **A page that lands** joins the pool (`merge`); the next cycle carries
///   it, mixed in. Nothing already on the tape moves.
/// - **The tape is trimmed** far behind what a scrub can reach (`trim`), so
///   it stays small however long the band runs.
///
/// Pure value type: the band owns one, and a re-activation starts a new one.
struct ReactionTape {
    /// How many entries one cycle deals at most (`CommentTickerBuilder.maxItems`).
    static let cycleSize = CommentTickerBuilder.maxItems
    /// How many of a lane's last entries a fresh one avoids repeating — about
    /// a band's width of bubbles.
    static let recentDistance = 6
    /// How far behind the lowest index in use the tape is kept.
    static let keptBehind = 200

    private(set) var pool: [TickerCommentModel]
    private let laneCount: Int
    private let seed: UInt64
    /// Per lane: the logical index of `entries[0]`, and the entries.
    private var bases: [Int]
    private var entries: [[TickerCommentModel]]
    /// Per lane: the highest index handed out so far — everything up to it
    /// was shown and never changes.
    private var shownHigh: [Int]
    /// How many cycles have been dealt, forward and backward.
    private var forwardCycles = 0
    private var backwardCycles = 0

    init(pool: [TickerCommentModel], laneCount: Int, seed: UInt64) {
        self.pool = pool
        self.laneCount = laneCount
        self.seed = seed
        bases = Array(repeating: 0, count: laneCount)
        entries = Array(repeating: [], count: laneCount)
        shownHigh = Array(repeating: -1, count: laneCount)
    }

    var isEmpty: Bool { pool.isEmpty }

    /// The reaction at `index` in `lane`, extending the tape either way as
    /// needed. A FRESH index (past everything handed out in that lane) is
    /// chosen to avoid `avoiding` (ids on screen) and the lane's last
    /// `recentDistance` entries, while the pool has another to offer.
    mutating func item(lane: Int, at index: Int, avoiding: Set<String> = []) -> TickerCommentModel {
        precondition(!pool.isEmpty, "a tape with no pool")
        while index >= bases[lane] + entries[lane].count { appendCycle() }
        while index < bases[lane] { prependCycle() }
        if index > shownHigh[lane] {
            chooseHead(lane: lane, at: index, avoiding: avoiding)
            shownHigh[lane] = index
        }
        return entries[lane][index - bases[lane]]
    }

    /// New reactions join the pool (a page that landed): ids already in it
    /// are ignored. The next cycle carries the newcomers.
    mutating func merge(_ newPool: [TickerCommentModel]) {
        let known = Set(pool.map(\.id))
        pool += newPool.filter { !known.contains($0.id) }
    }

    /// Drops entries far behind `lowestInUse` in `lane`.
    mutating func trim(lane: Int, lowestInUse: Int) {
        let keepFrom = lowestInUse - Self.keptBehind
        let drop = keepFrom - bases[lane]
        guard drop > 0, drop <= entries[lane].count else { return }
        entries[lane].removeFirst(drop)
        bases[lane] += drop
    }

    /// How many entries `lane` holds — for tests and traces.
    func count(lane: Int) -> Int { entries[lane].count }

    // MARK: - Cycles

    /// The pool shuffled for cycle `number` (negative: dealt backward),
    /// dealt round the lanes: lane `l` takes positions `l`, `l + laneCount`…
    private func deal(cycle number: Int) -> [[TickerCommentModel]] {
        var generator = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(number)) &* 0x9E37_79B9_7F4A_7C15)
        let shuffled = Array(pool.shuffled(using: &generator).prefix(Self.cycleSize))
        var hands = Array(repeating: [TickerCommentModel](), count: laneCount)
        for (position, item) in shuffled.enumerated() { hands[position % laneCount].append(item) }
        // A pool smaller than the lanes leaves a lane empty-handed: it takes
        // the whole cycle rather than nothing.
        for lane in hands.indices where hands[lane].isEmpty { hands[lane] = shuffled }
        return hands
    }

    private mutating func appendCycle() {
        let hands = deal(cycle: forwardCycles)
        forwardCycles += 1
        for lane in 0..<laneCount { entries[lane] += hands[lane] }
    }

    private mutating func prependCycle() {
        backwardCycles += 1
        let hands = deal(cycle: -backwardCycles)
        for lane in 0..<laneCount {
            entries[lane].insert(contentsOf: hands[lane], at: 0)
            bases[lane] -= hands[lane].count
        }
    }

    /// Swaps the entry at a fresh `index` with the first one after it that
    /// avoids what is on screen and the lane's recent entries. Leaves it when
    /// nothing within a cycle does: a small pool repeats rather than stalls.
    private mutating func chooseHead(lane: Int, at index: Int, avoiding onScreen: Set<String>) {
        let position = index - bases[lane]
        let recent = Set(entries[lane][max(0, position - Self.recentDistance)..<position].map(\.id))
        let avoided = onScreen.union(recent)
        guard avoided.contains(entries[lane][position].id) else { return }
        let horizon = Self.cycleSize
        for offset in 1...horizon {
            if position + offset >= entries[lane].count { appendCycle() }
            let candidate = position + offset
            if !avoided.contains(entries[lane][candidate].id) {
                entries[lane].swapAt(position, candidate)
                return
            }
        }
    }
}
