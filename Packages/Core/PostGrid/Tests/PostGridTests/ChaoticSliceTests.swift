import CoreGraphics
import CoreModels
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// The tiling's four load-bearing properties: it produces the count it was
/// asked for, it covers the slice exactly, it is reproducible, and it varies
/// across the scroll. Each of the first three was a defect in the prototype
/// this was ported from.
struct ChaoticSliceEngineTests {
    private let engine = ChaoticSliceEngine.standard
    /// The geometry the layout actually resolves on a modern iPhone: the CANVAS
    /// width — 393 less the two 8pt side margins — against a slice a little over
    /// one screenful. Testing at the raw 393 measures a tiling the engine is
    /// never asked for, and those 16pt are enough to change which cuts are legal.
    private let slice = CGSize(width: 377, height: 980)

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    // MARK: - Count

    /// The port's headline fix. The prototype nets +2 blocks per split from a
    /// start of 1, so it can only ever produce odd counts — asked for 10 it
    /// returns 11, and a feed's tail or a gallery of eight posts is
    /// unexpressible. The two-way bisect makes every count reachable.
    ///
    /// Bounded at 16 because this is about *parity*, not capacity: a 393x980
    /// slice runs out of legible room around 19 tiles, and the ceiling is the
    /// subject of `anImpossibleCountIsCutShortNotShredded` below. 16 covers
    /// every tail a `cellsPerSlice` of 11 can produce, with headroom.
    @Test func everyCountIsReachable() {
        for seed in UInt64(0)..<8 {
            for requested in 1...16 {
                let plan = engine.plan(cellCount: requested, sliceSize: slice, seed: seed)
                #expect(plan.count == requested,
                        "seed \(seed) asked for \(requested), got \(plan.count)")
            }
        }
    }

    /// The floor is allowed to cut a slice short, but never to overshoot: a
    /// caller that laid out more blocks than it had items would trap.
    @Test func countIsNeverExceededEvenUnderTheFloor() {
        let cramped = CGSize(width: 200, height: 200)
        for requested in 1...40 {
            #expect(engine.plan(cellCount: requested, sliceSize: cramped, seed: 3).count <= requested)
        }
    }

    // MARK: - Coverage

    /// Full bleed, no gaps: the blocks must sum to the slice and not overlap.
    @Test func blocksTileTheSliceExactly() {
        for seed in UInt64(0)..<8 {
            let plan = engine.plan(cellCount: 11, sliceSize: slice, seed: seed)
            let covered = plan.blocks.reduce(CGFloat.zero) { $0 + area($1) }
            #expect(abs(covered - 1) < 1e-9, "seed \(seed) covered \(covered)")
            for (index, block) in plan.blocks.enumerated() {
                #expect(block.minX >= -1e-9 && block.maxX <= 1 + 1e-9)
                #expect(block.minY >= -1e-9 && block.maxY <= 1 + 1e-9)
                for other in plan.blocks[(index + 1)...] {
                    let overlap = block.intersection(other)
                    #expect(overlap.isNull || area(overlap) < 1e-9, "seed \(seed) overlap at \(index)")
                }
            }
        }
    }

    // MARK: - Determinism and variety

    /// Reproducibility is the contract that lets the layout cache slices and a
    /// scroll back up land on the tiling it left.
    @Test func sameSeedGivesTheSameTiling() {
        for seed in UInt64(0)..<8 {
            #expect(
                engine.plan(cellCount: 11, sliceSize: slice, seed: seed)
                    == engine.plan(cellCount: 11, sliceSize: slice, seed: seed)
            )
        }
    }

    /// The prototype's other defect: with no seed input every slice resolves to
    /// the identical tiling, so the feed repeats one picture down the scroll.
    @Test func differentSeedsGiveDifferentTilings() {
        let plans = (UInt64(0)..<8).map { engine.plan(cellCount: 11, sliceSize: slice, seed: $0) }
        for (index, plan) in plans.enumerated() {
            for other in plans[(index + 1)...] {
                #expect(plan != other, "slice \(index) tiles identically to a later one")
            }
        }
    }

    // MARK: - Legibility

    /// A tile carries counters and a play badge; below ~90pt of width the
    /// furniture collides. The engine stops splitting rather than emit one.
    @Test func noBlockFallsBelowTheMinimumSide() {
        for seed in UInt64(0)..<8 {
            let plan = engine.plan(cellCount: 11, sliceSize: slice, seed: seed)
            for block in plan.blocks {
                #expect(block.width * slice.width >= engine.minimumTileSide - 0.5)
                #expect(block.height * slice.height >= engine.minimumTileSide - 0.5)
            }
        }
    }

    /// Asking for more tiles than the slice can legibly hold returns fewer,
    /// rather than shredding it or spinning. The prototype's equivalent path
    /// divides by zero, scores `NaN`, and silently returns whatever it had.
    @Test func anImpossibleCountIsCutShortNotShredded() {
        let plan = engine.plan(cellCount: 200, sliceSize: slice, seed: 1)
        #expect(plan.count > 0)
        #expect(plan.count < 200)
        let covered = plan.blocks.reduce(CGFloat.zero) { $0 + area($1) }
        #expect(abs(covered - 1) < 1e-9, "a cut-short slice must still be fully covered")
    }

    @Test func degenerateInputYieldsNoBlocks() {
        #expect(engine.plan(cellCount: 0, sliceSize: slice, seed: 0).blocks.isEmpty)
        #expect(engine.plan(cellCount: 5, sliceSize: .zero, seed: 0).blocks.isEmpty)
    }

    // MARK: - Visual harmony

    /// No horizontal cross-section may hold more than three tiles. Checked at
    /// every row boundary, not just at the obvious ones — the count changes
    /// only at a block's top edge, so those edges sample every distinct row.
    @Test func noRowExceedsThreeBlocks() {
        for seed in UInt64(0)..<12 {
            for count in [5, 8, 11, 14] {
                let plan = engine.plan(cellCount: count, sliceSize: slice, seed: seed)
                for probe in plan.blocks {
                    let row = probe.minY + 1e-9
                    let across = plan.blocks.filter { $0.minY <= row && $0.maxY > row }.count
                    #expect(across <= engine.maximumBlocksPerRow,
                            "seed \(seed) count \(count): \(across) blocks across at y=\(probe.minY)")
                }
            }
        }
    }

    /// Counts adjacent pairs whose proportions are within
    /// `adjacentRatioTolerance` of each other, over a spread of slices.
    private func twinRate(of engine: ChaoticSliceEngine) -> (twins: Int, pairs: Int) {
        let sliceAspect = slice.width / slice.height
        func logAspect(_ rect: CGRect) -> CGFloat { log((rect.width * sliceAspect) / rect.height) }
        var twins = 0
        var pairs = 0
        for seed in UInt64(0)..<40 {
            let plan = engine.plan(
                cellCount: ChaoticSliceEngine.defaultCellsPerSlice, sliceSize: slice, seed: seed
            )
            for (index, block) in plan.blocks.enumerated() {
                for other in plan.blocks[(index + 1)...]
                where ChaoticSliceEngine.areAdjacent(block, other) {
                    pairs += 1
                    if abs(logAspect(block) - logAspect(other)) < engine.adjacentRatioTolerance {
                        twins += 1
                    }
                }
            }
        }
        return (twins, pairs)
    }

    /// Touching blocks should not repeat each other's proportions.
    ///
    /// A *penalty*, subordinate to ratio fidelity — which is the trade the
    /// grid's owner asked for explicitly, and it has a price. Ranking twin-free
    /// cuts ahead of everything else got repeats down to 5.5% of adjacent
    /// pairs, but only by accepting whatever shapes were left over (0.23, 2.80).
    /// Demoted to a tiebreak among well-proportioned cuts it lands near 17%,
    /// against a higher figure with the rule off entirely. The headroom is small
    /// for a structural reason: the tighter the tiling clusters on five ratios,
    /// the more often two neighbours land on the same one.
    ///
    /// That headroom is small for a structural reason: the tighter the tiling
    /// clusters on five ratios, the more often two neighbours land on the same
    /// one. Strict ratios and twin avoidance genuinely pull against each other.
    @Test func touchingBlocksRarelyRepeatTheSameRatio() {
        var control = engine
        control.twinPenalty = 0

        let ruled = twinRate(of: engine)
        let unruled = twinRate(of: control)
        #expect(ruled.pairs > 100, "not enough adjacency to measure")
        #expect(Double(ruled.twins) / Double(ruled.pairs) < 0.35,
                "\(ruled.twins)/\(ruled.pairs) adjacent pairs are twins")
        #expect(ruled.twins < unruled.twins,
                "the rule did nothing: \(ruled.twins) vs \(unruled.twins) unruled")
    }

    /// Every block's aspect, over a spread of slices.
    private func aspects(
        cellCount: Int = ChaoticSliceEngine.defaultCellsPerSlice,
        seeds: Range<UInt64> = 0..<40
    ) -> [[CGFloat]] {
        let sliceAspect = slice.width / slice.height
        return seeds.map { seed in
            engine.plan(cellCount: cellCount, sliceSize: slice, seed: seed).blocks.map {
                ($0.width * sliceAspect) / $0.height
            }
        }
    }

    /// The band is a guard rail, not a guarantee, and the difference is
    /// structural: a BSP does not choose every shape it makes. The last child
    /// of a cut is whatever area the parent has left over, so about one block
    /// per slice is a complement rather than a decision and can land outside.
    ///
    /// What IS guaranteed is that the misses stay small — the out-of-band
    /// charge grows with the excess, so a cornered search takes a near miss
    /// over a sliver.
    @Test func blocksLeaveTheAspectBandOnlyNarrowlyAndRarely() {
        let perSlice = aspects()
        let all = perSlice.flatMap(\.self)
        let escaped = all.filter { !engine.aspectBounds.contains($0) }
        #expect(Double(escaped.count) / Double(all.count) < 0.15,
                "\(escaped.count)/\(all.count) blocks left the band")
        for slice in perSlice {
            let out = slice.filter { !engine.aspectBounds.contains($0) }.count
            #expect(out <= 2, "\(out) blocks out of band in one slice")
        }
        // And nothing is ever a sliver, band or no band.
        for aspect in all {
            #expect(aspect > 0.4 && aspect < 2.5, "block at aspect \(aspect)")
        }
    }

    /// Blocks should sit ON the five targets, not merely inside the band.
    ///
    /// The positive claim that scoring actually pulls toward `allowedRatios`,
    /// measured the way the engine measures it — in log space, where a ratio
    /// and its inverse are equally wrong.
    @Test func blocksClusterOnTheTargetRatios() {
        let deviations = aspects().flatMap(\.self).map {
            abs(log($0) - log(engine.nearestAllowedRatio(to: $0)))
        }
        let onTarget = deviations.filter { $0 < 0.05 }.count
        let mean = deviations.reduce(0, +) / CGFloat(deviations.count)
        #expect(mean < 0.06, "mean log deviation from the nearest target is \(mean)")
        #expect(Double(onTarget) / Double(deviations.count) > 0.7,
                "only \(onTarget)/\(deviations.count) blocks are within 0.05 of a target")
    }

    /// The tiling must INTERLOCK, not band.
    ///
    /// This is the property that makes it read as a chaotic partition rather
    /// than as a grid: at most boundaries some block should span straight past,
    /// so tile tops and bottoms stagger instead of lining up into rows.
    ///
    /// The regression this guards against was self-inflicted. Chasing a
    /// three-column quota, the engine grew a mechanism that cut full-width
    /// strips and divided them into equal columns — which is precisely a row,
    /// and turned every boundary into a line running the full width of the
    /// canvas. Density, not scoring, is what produces three-across rows without
    /// flattening the tiling.
    @Test func theTilingInterlocksRatherThanFormingRows() {
        var clean = 0
        var total = 0
        for seed in UInt64(0)..<60 {
            let plan = engine.plan(
                cellCount: ChaoticSliceEngine.defaultCellsPerSlice, sliceSize: slice, seed: seed
            )
            for boundary in ChaoticSliceEngine.interiorBoundaries(of: plan.blocks) {
                total += 1
                if boundary.isCleanBreak { clean += 1 }
            }
        }
        #expect(total > 100, "not enough boundaries to measure")
        // A banded grid scores 100%: every seam runs edge to edge. Measured at
        // 40% here, so three boundaries in five are spanned by some block.
        #expect(Double(clean) / Double(total) < 0.6,
                "\(clean)/\(total) boundaries run the full width — the tiling has banded")
    }

    /// Three-across rows should appear on their own, as a consequence of tile
    /// size, rather than being manufactured.
    ///
    /// Soft on purpose: forcing a quota is what produced the banding above. At
    /// the shipped density roughly a quarter of rows come out three across.
    @Test func threeAcrossRowsOccurNaturally() {
        var histogram: [Int: Int] = [:]
        for seed in UInt64(0)..<60 {
            let counts = ChaoticSliceEngine.rowCounts(
                of: engine.plan(
                    cellCount: ChaoticSliceEngine.defaultCellsPerSlice, sliceSize: slice, seed: seed
                ).blocks
            )
            for count in counts { histogram[count, default: 0] += 1 }
        }
        let total = histogram.values.reduce(0, +)
        #expect(Double(histogram[3] ?? 0) / Double(total) > 0.12,
                "only \(histogram[3] ?? 0)/\(total) rows are three across")
        #expect(Double(histogram[2] ?? 0) / Double(total) > 0.4,
                "two-across rows should still be the backbone")
        // The max is the one hard rule; nothing wider may appear.
        #expect(histogram.keys.allSatisfy { $0 <= engine.maximumBlocksPerRow })
    }

    /// Ratio fidelity outranks twin avoidance, and the row limit outranks both.
    /// Pinned because each was, at some point, allowed to win instead — and
    /// each time the tiling got visibly worse.
    @Test func theRowLimitIsNeverTradedAwayForShape() {
        for seed in UInt64(0)..<40 {
            let plan = engine.plan(cellCount: 11, sliceSize: slice, seed: seed)
            for probe in plan.blocks {
                let row = probe.minY + 1e-9
                let across = plan.blocks.filter { $0.minY <= row && $0.maxY > row }.count
                #expect(across <= engine.maximumBlocksPerRow,
                        "seed \(seed): \(across) across — the row cap was relaxed to buy a shape")
            }
        }
    }

    /// Corner contact is not adjacency: two blocks meeting at a point share no
    /// seam, so their shapes rhyming is not something the eye picks up. Getting
    /// this wrong would over-penalise and distort the tiling for no gain.
    @Test func adjacencyRequiresASharedEdgeNotACorner() {
        let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let bottomRight = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let topRight = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        #expect(!ChaoticSliceEngine.areAdjacent(topLeft, bottomRight))
        #expect(ChaoticSliceEngine.areAdjacent(topLeft, topRight))
        #expect(ChaoticSliceEngine.areAdjacent(topRight, bottomRight))
        // Separated blocks are not adjacent either.
        #expect(!ChaoticSliceEngine.areAdjacent(
            topLeft, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.5)
        ))
    }

    /// The harmony rules must not cost the guarantees they were added on top
    /// of: coverage and count still hold with both switched on.
    @Test func harmonyRulesPreserveCoverageAndCount() {
        for seed in UInt64(0)..<8 {
            for count in 1...14 {
                let plan = engine.plan(cellCount: count, sliceSize: slice, seed: seed)
                #expect(plan.count == count)
                let covered = plan.blocks.reduce(CGFloat.zero) { $0 + area($1) }
                #expect(abs(covered - 1) < 1e-9)
            }
        }
    }

    // MARK: - Slot metrics

    /// The shapes the arrangement matches against must describe the blocks the
    /// layout will actually draw.
    @Test func slotAspectsDescribeTheOnScreenShape() {
        let plan = engine.plan(cellCount: 11, sliceSize: slice, seed: 2)
        let metrics = plan.metrics(sliceAspect: slice.width / slice.height)
        for (block, slot) in zip(plan.blocks, metrics) {
            let onScreen = (block.width * slice.width) / (block.height * slice.height)
            #expect(abs(slot.aspect - onScreen) < 1e-6)
            #expect(abs(slot.relativeArea - area(block)) < 1e-9)
        }
        #expect(abs(metrics.reduce(CGFloat.zero) { $0 + $1.relativeArea } - 1) < 1e-9)
    }
}

// MARK: - Stack

struct ChaoticSliceStackTests {
    private let engine = ChaoticSliceEngine.standard

    private func stack(itemCount: Int, width: CGFloat = 393, sliceHeight: CGFloat = 980) -> ChaoticSliceStack {
        engine.stack(
            itemCount: itemCount, contentWidth: width, sliceHeight: sliceHeight,
            cellsPerSlice: 11, pixelScale: 3
        )
    }

    @Test func everyItemGetsExactlyOneFrame() {
        for count in [1, 5, 11, 12, 23, 24, 47] {
            #expect(stack(itemCount: count).frames.count == count, "count \(count)")
            #expect(stack(itemCount: count).slotMetrics.count == count, "metrics \(count)")
        }
    }

    /// The seam test. Blocks are exact complements in unit space, but points are
    /// not: rounding a width independently of its neighbour's origin is what
    /// puts hairlines between tiles. Snapping shared EDGES makes adjacent frames
    /// meet exactly.
    @Test func adjacentFramesShareTheirEdges() {
        let stack = stack(itemCount: 33)
        for frame in stack.frames {
            for other in stack.frames where other != frame {
                // Vertically overlapping neighbours must abut, not overlap.
                let overlap = frame.intersection(other)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01,
                        "frames overlap: \(frame) / \(other)")
            }
        }
        // Every frame lands on the pixel grid, both edges.
        for frame in stack.frames {
            for edge in [frame.minX, frame.maxX, frame.minY, frame.maxY] {
                #expect(abs((edge * 3).rounded() - edge * 3) < 1e-6, "off-grid edge \(edge)")
            }
        }
    }

    /// Slices stack without gaps or overlap, and the content height is the sum.
    @Test func slicesStackContiguously() {
        let stack = stack(itemCount: 40)
        #expect(stack.slices.first?.minY == 0)
        for (index, slice) in stack.slices.enumerated().dropFirst() {
            #expect(abs(slice.minY - stack.slices[index - 1].maxY) < 1e-6)
        }
        // Content height tracks occupied tiles, not the last band — see
        // `contentHeightStopsAtTheLastOccupiedTile`. 40 items fill three slices
        // and part of a fourth, so the final band extends past the content.
        #expect(stack.contentHeight <= (stack.slices.last?.maxY ?? 0) + 1e-6)
        // Item ranges partition the feed in order.
        #expect(stack.slices.map(\.itemRange.lowerBound) == stack.slices.map(\.itemRange.lowerBound).sorted())
        #expect(stack.slices.last?.itemRange.upperBound == 40)
    }

    /// **The pagination guarantee.** Appending may never move a frame that
    /// already exists — not even in the partial slice the new items land in.
    ///
    /// This is what a page landing during a scroll used to break: the tail was
    /// re-planned at its new count and new height, so every tile in the last
    /// slice jumped while the viewer was looking at it. Checked across every
    /// count, not just at slice boundaries, because the boundary cases were the
    /// only ones that ever worked.
    @Test func appendingNeverMovesAnExistingFrame() {
        var previous = stack(itemCount: 1)
        for count in 2...60 {
            let current = stack(itemCount: count)
            #expect(current.frames.count == count, "count \(count)")
            #expect(Array(current.frames.prefix(previous.frames.count)) == previous.frames,
                    "appending to \(count) moved an existing frame")
            #expect(Array(current.slotMetrics.prefix(previous.slotMetrics.count)) == previous.slotMetrics,
                    "appending to \(count) reshaped an existing slot")
            previous = current
        }
    }

    /// The same guarantee stated the other way: a slice's plan depends on its
    /// index and the geometry, never on how many items happen to exist.
    @Test func aSlicePlanIsIndependentOfTheItemCount() {
        // Slice 1 spans items 11..<22. Its first frame must be identical
        // whether the feed holds 12 items or 200.
        let sparse = stack(itemCount: 12)
        let full = stack(itemCount: 200)
        #expect(sparse.frames.count == 12)
        #expect(sparse.frames[11] == full.frames[11])
        #expect(sparse.slices[1].minY == full.slices[1].minY)
        #expect(sparse.slices[1].maxY == full.slices[1].maxY)
    }

    /// Every slice is a full one now, including the last. A partial slice keeps
    /// its band and simply leaves later blocks empty — that is the price of the
    /// plan not depending on the count.
    @Test func aPartialSliceKeepsTheFullSliceHeight() {
        let tail = stack(itemCount: 14)
        #expect(tail.slices.count == 2)
        for slice in tail.slices {
            #expect(abs((slice.maxY - slice.minY) - 980) < 0.5)
        }
        #expect(tail.slices[1].itemRange.count == 3)
    }

    /// Content height tracks the tiles that exist, not the slice band they sit
    /// in, so a partial final slice does not hang a screenful of empty
    /// background off the end of the feed.
    @Test func contentHeightStopsAtTheLastOccupiedTile() {
        let tail = stack(itemCount: 14)
        #expect(tail.contentHeight <= tail.slices[1].maxY)
        #expect(tail.contentHeight == tail.frames.map(\.maxY).max())
        // And it never shrinks as the feed grows.
        var previous: CGFloat = 0
        for count in 1...40 {
            let height = stack(itemCount: count).contentHeight
            #expect(height >= previous, "content height shrank at \(count)")
            previous = height
        }
    }

    /// Blocks are placed top-to-bottom, so a partial slice's holes are at the
    /// bottom where they read as "more coming" rather than scattered through it.
    @Test func blocksArePlacedInReadingOrder() {
        let stack = stack(itemCount: 33)
        for slice in stack.slices {
            let inSlice = stack.frames[slice.itemRange]
            for (index, frame) in inSlice.enumerated().dropFirst() {
                let earlier = inSlice[inSlice.startIndex + index - 1]
                #expect(frame.minY > earlier.minY
                    || (frame.minY == earlier.minY && frame.minX > earlier.minX),
                        "slice item \(index) is out of reading order")
            }
        }
    }

    @Test func anEmptyFeedHasNoContent() {
        #expect(stack(itemCount: 0).frames.isEmpty)
        #expect(stack(itemCount: 0).contentHeight == 0)
    }
}

// MARK: - Gutter

@MainActor
struct ChaoticSliceGutterTests {
    private static let width: CGFloat = 393

    /// Holds the collection view AND its data source for the life of a test.
    ///
    /// `UICollectionView.dataSource` is a weak reference: a stub owned only by
    /// the helper that made it is deallocated before the layout ever asks it
    /// for a count, and the layout pass then crashes the whole test process —
    /// which reads as every unrelated test failing at once.
    private final class Harness: NSObject, UICollectionViewDataSource {
        let layout = ChaoticSliceLayout()
        let collectionView: UICollectionView
        let itemCount: Int

        init(itemCount: Int) {
            self.itemCount = itemCount
            collectionView = UICollectionView(
                frame: CGRect(x: 0, y: 0, width: ChaoticSliceGutterTests.width, height: 852),
                collectionViewLayout: layout
            )
            super.init()
            // Registered so `cellForItemAt` can DEQUEUE. Returning a freshly
            // constructed cell instead throws inside UIKit and takes the whole
            // test process with it — which shows up as every unrelated suite
            // dying rather than as one failure here.
            collectionView.register(
                UICollectionViewCell.self, forCellWithReuseIdentifier: Harness.reuseID
            )
            collectionView.dataSource = self
            collectionView.layoutIfNeeded()
        }

        static let reuseID = "harness"

        var frames: [CGRect] {
            (0..<itemCount).compactMap {
                layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
            }
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            itemCount
        }

        func collectionView(
            _ view: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            view.dequeueReusableCell(withReuseIdentifier: Harness.reuseID, for: indexPath)
        }
    }

    /// Half a gutter comes off each side of a seam, so the gap between two
    /// tiles is one full gutter.
    @Test func neighbouringTilesAreOneGutterApart() {
        let harness = Harness(itemCount: 22)
        let layout = harness.layout
        let frames = harness.frames
        #expect(frames.count == 22)
        var seams = 0
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                let verticalOverlap = min(frame.maxY, other.maxY) - max(frame.minY, other.minY)
                guard verticalOverlap > 1 else { continue }
                let gap = other.minX - frame.maxX
                guard gap > 0, gap < layout.gutter * 2 else { continue }
                #expect(abs(gap - layout.gutter) < 1.0, "side-by-side gap \(gap)")
                seams += 1
            }
        }
        #expect(seams > 0, "no side-by-side pairs found — the assertion never ran")
    }

    /// The background beside an outer tile is exactly as wide as the background
    /// between two inner ones, so the grid reads as evenly spaced all the way
    /// across.
    @Test func theSideMarginsMatchTheGutter() {
        let harness = Harness(itemCount: 22)
        let margin = harness.layout.gutter
        let frames = harness.frames
        #expect(!frames.isEmpty)
        // Something actually reaches each margin — otherwise the bounds check
        // below would pass on an empty grid.
        #expect(frames.contains { abs($0.minX - margin) < 0.5 })
        #expect(frames.contains { abs($0.maxX - (Self.width - margin)) < 0.5 })
        for frame in frames {
            #expect(frame.minX >= margin - 0.01, "tile crosses the leading margin")
            #expect(frame.maxX <= Self.width - margin + 0.01, "tile crosses the trailing margin")
        }
        // Vertical is unchanged: the feed scrolls, so the first slice still
        // starts flush at the top.
        #expect(frames.contains { $0.minY == 0 })
    }

    /// Gap and curve are one decision — see `ChaoticSliceLayout.harmonisedGutter`.
    /// The mosaic keeps its own tighter pairing, so the tile's default must not
    /// have moved with it.
    @Test func theGutterAndRadiusMoveTogether() {
        let layout = ChaoticSliceLayout()
        #expect(layout.gutter == ChaoticSliceLayout.harmonisedGutter)
        #expect(layout.tileCornerRadius == ChaoticSliceLayout.harmonisedCornerRadius)
        #expect(layout.gutter < layout.tileCornerRadius)
        // The profile gallery's pairing is untouched.
        #expect(PostGridTileCell.mosaicCornerRadius == 10)
        #expect(PostGridMosaic.gutter == 1.5)
    }
}

// MARK: - Arrangement

struct PostGridSliceArrangementTests {
    private let engine = ChaoticSliceEngine.standard

    private func metrics(_ count: Int) -> [SlotMetrics] {
        engine.stack(
            itemCount: count, contentWidth: 393, sliceHeight: 980,
            cellsPerSlice: 11, pixelScale: 3
        ).slotMetrics
    }

    private func video(_ id: String, aspect: Double = 0.5625) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .video, isRepost: false, thumbnailURL: nil,
            videoURL: URL(string: "mock://video/\(id)"), aspectRatio: aspect,
            caption: "", publishedAtMS: 0
        )
    }

    private func photo(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            aspectRatio: 1, caption: "", publishedAtMS: 0
        )
    }

    private func ids(_ posts: [GalleryPost]) -> [String] { posts.map(\.id.rawValue) }

    private func mixed(_ count: Int) -> [GalleryPost] {
        (0..<count).map { $0 % 3 == 0 ? video("v\($0)") : photo("p\($0)") }
    }

    /// The invariant everything else rests on.
    @Test func nothingIsDroppedOrDuplicated() {
        let input = mixed(22)
        let slots = metrics(22)
        for start in [0, 3, 11] {
            let window = Array(input.prefix(22 - start))
            let out = PostGridSliceArrangement.arranged(window, startingAt: start, slotMetrics: slots)
            #expect(out.count == window.count)
            #expect(Set(ids(out)) == Set(ids(window)))
        }
    }

    @Test func stillsKeepTheirOrder() {
        let input = mixed(11)
        let out = PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: metrics(11))
        #expect(ids(out.filter { !$0.autoplaysInGrid }) == ids(input.filter { !$0.autoplaysInGrid }))
    }

    /// The point of the pass: a clip lands in the block whose shape is NEAREST
    /// its own, because aspect-fill crops by the difference and the hero flight
    /// has to unwind that crop at takeoff.
    ///
    /// Nearest, not tallest. With one video among stills every slot is free, so
    /// the block it takes must be the best match in the whole slice — which is
    /// emphatically not the most extreme one: against a 0.5625 clip, a 0.58
    /// block beats a 0.27 block by a factor of twenty.
    @Test func videoTakesTheBlockNearestItsOwnShape() {
        let slots = metrics(11)
        let clipAspect: CGFloat = 0.5625
        let input = [photo("p0"), video("tall", aspect: Double(clipAspect))]
            + (1...9).map { photo("p\($0)") }
        let out = PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: slots)
        let placed = out.firstIndex { $0.id.rawValue == "tall" }
        #expect(placed != nil)
        func distance(_ index: Int) -> CGFloat {
            abs(log(slots[index].aspect) - log(clipAspect))
        }
        let nearest = slots.indices.min { distance($0) < distance($1) }
        #expect(abs(distance(placed!) - distance(nearest!)) < 1e-9,
                "took slot at aspect \(slots[placed!].aspect), best was \(slots[nearest!].aspect)")
    }

    /// A landscape clip and a portrait clip must not both be sent to the same
    /// end of the shape range.
    @Test func eachClipGoesToTheBlockThatCropsItLeast() {
        let slots = metrics(11)
        let input = [video("tall", aspect: 0.5625), video("wide", aspect: 1.78)]
            + (0..<9).map { photo("p\($0)") }
        let out = PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: slots)
        let tall = out.firstIndex { $0.id.rawValue == "tall" }!
        let wide = out.firstIndex { $0.id.rawValue == "wide" }!
        #expect(slots[tall].aspect < slots[wide].aspect)
    }

    /// Placement must depend only on the absolute slots and the posts handed
    /// over — that is what keeps a page landing an insert rather than a reload.
    @Test func placementIsAPureFunctionOfTheAbsoluteWindow() {
        let slots = metrics(22)
        let tail = mixed(22).suffix(11).map(\.self)
        let first = PostGridSliceArrangement.arranged(tail, startingAt: 11, slotMetrics: slots)
        let again = PostGridSliceArrangement.arranged(tail, startingAt: 11, slotMetrics: slots)
        #expect(ids(first) == ids(again))
        // And it does not agree with the window at a different offset, which is
        // the whole reason the absolute index is passed in.
        let shifted = PostGridSliceArrangement.arranged(tail, startingAt: 0, slotMetrics: slots)
        #expect(ids(first) != ids(shifted) || slots[0..<11] == slots[11..<22])
    }

    // MARK: No-ops

    @Test func anAllStillListIsUntouched() {
        let input = (0..<11).map { photo("p\($0)") }
        #expect(ids(PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: metrics(11)))
            == ids(input))
    }

    @Test func anAllMotionListIsUntouched() {
        let input = (0..<11).map { video("v\($0)") }
        #expect(ids(PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: metrics(11)))
            == ids(input))
    }

    @Test func anEmptyListIsUntouched() {
        #expect(PostGridSliceArrangement.arranged([], startingAt: 0, slotMetrics: metrics(11)).isEmpty)
    }

    /// Before the host has been laid out there are no slot shapes. Reading order
    /// is the fallback, and it must not trap.
    @Test func missingSlotShapesFallBackToReadingOrder() {
        let input = mixed(11)
        #expect(ids(PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: [])) == ids(input))
        // Short metrics, too — a stack cut short by the floor.
        #expect(ids(PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: metrics(4)))
            == ids(input))
    }

    /// A window whose slots are all the same shape has nowhere better to put
    /// anything, so it must not shuffle videos to the front for no gain.
    @Test func uniformSlotsAreLeftAlone() {
        let input = mixed(4)
        let uniform = Array(repeating: SlotMetrics(aspect: 1, relativeArea: 0.25), count: 4)
        #expect(ids(PostGridSliceArrangement.arranged(input, startingAt: 0, slotMetrics: uniform))
            == ids(input))
    }
}
