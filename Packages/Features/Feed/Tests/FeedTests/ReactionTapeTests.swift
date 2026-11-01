import Testing
@testable import Feed

/// The band's tape (#2005): an append-only sequence per lane, so the loop
/// never replays the same sequence and a scrub back reads what was shown.
struct ReactionTapeTests {
    private func pool(_ count: Int) -> [TickerCommentModel] {
        (0..<count).map { TickerCommentModel(id: "r\($0)", text: "GG \($0)") }
    }

    /// Two cycles of one lane: the same reactions, in another order.
    @Test func aNewCycleReordersThePool() {
        var tape = ReactionTape(pool: pool(20), laneCount: 1, seed: 7)
        let first = (0..<20).map { tape.item(lane: 0, at: $0).id }
        let second = (20..<40).map { tape.item(lane: 0, at: $0).id }
        #expect(first != second, "the second cycle replayed the first")
        #expect(Set(second).isSubset(of: Set(pool(20).map(\.id))))
    }

    /// No ten bubbles in a row repeat a sequence already shown, over many
    /// cycles.
    @Test func noSequenceOfTenRepeats() {
        var tape = ReactionTape(pool: pool(24), laneCount: 2, seed: 11)
        let lane = (0..<300).map { tape.item(lane: 0, at: $0).id }
        var seen = Set<[String]>()
        for start in 0...(lane.count - 10) {
            let run = Array(lane[start..<(start + 10)])
            #expect(seen.insert(run).inserted, "a run of ten came back at \(start)")
        }
    }

    /// A fresh entry never repeats one of the lane's last few, nor one on
    /// screen in another lane, while the pool allows.
    @Test func aFreshEntryAvoidsTheRecentAndTheOnScreen() {
        var tape = ReactionTape(pool: pool(20), laneCount: 2, seed: 3)
        var shown: [String] = []
        for index in 0..<120 {
            let onScreen: Set<String> = ["r1", "r2", "r3"]
            let item = tape.item(lane: 0, at: index, avoiding: onScreen)
            #expect(!onScreen.contains(item.id), "on screen in the other lane: \(item.id)")
            #expect(!shown.suffix(ReactionTape.recentDistance).contains(item.id), "repeated within the lane at \(index)")
            shown.append(item.id)
        }
    }

    /// Within one cycle, the lanes are dealt disjoint hands.
    @Test func aCycleDealsTheLanesDisjointHands() {
        var tape = ReactionTape(pool: pool(20), laneCount: 2, seed: 5)
        let zero = Set((0..<10).map { tape.item(lane: 0, at: $0).id })
        let one = Set((0..<10).map { tape.item(lane: 1, at: $0).id })
        #expect(zero.isDisjoint(with: one))
    }

    /// A scrub back reads exactly what was shown; before the tape's start a
    /// cycle is laid in front.
    @Test func aBackwardWalkReturnsWhatWasShown() {
        var tape = ReactionTape(pool: pool(20), laneCount: 2, seed: 9)
        let forward = (0..<40).map { tape.item(lane: 0, at: $0).id }
        let back = (0..<40).reversed().map { tape.item(lane: 0, at: $0).id }
        #expect(back == forward.reversed())
        _ = tape.item(lane: 0, at: -5) // before the start: still an entry
    }

    /// Trimmed far behind what is in use, the tape keeps the window.
    @Test func theTrimKeepsTheWindow() {
        var tape = ReactionTape(pool: pool(20), laneCount: 1, seed: 1)
        let shown = (0..<600).map { tape.item(lane: 0, at: $0).id }
        tape.trim(lane: 0, lowestInUse: 590)
        #expect(tape.count(lane: 0) < 600)
        let kept = (390..<600).map { tape.item(lane: 0, at: $0).id }
        #expect(kept == Array(shown[390..<600]), "the trim changed what a scrub back reads")
    }

    /// A page that lands joins the pool; the next cycles carry it, and
    /// nothing already on the tape moves.
    @Test func aMergedPageJoinsTheNextCycles() {
        var tape = ReactionTape(pool: pool(10), laneCount: 1, seed: 2)
        let before = (0..<10).map { tape.item(lane: 0, at: $0).id }
        tape.merge(pool(10) + [TickerCommentModel(id: "new", text: "W")])
        #expect(tape.pool.count == 11)
        #expect((0..<10).map { tape.item(lane: 0, at: $0).id } == before)
        let later = (10..<60).map { tape.item(lane: 0, at: $0).id }
        #expect(later.contains("new"))
    }
}
