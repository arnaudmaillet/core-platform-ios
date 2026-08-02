import CoreGraphics
import Foundation

/// The irregular-tiling generator behind the For You grid: a binary space
/// partition that fills a fixed-height *slice* with N blocks, choosing every cut
/// so the resulting blocks land as close as possible to a small set of pleasant
/// aspect ratios.
///
/// **Why a slice at all.** A BSP fills a closed rectangle exactly — that is what
/// buys full-bleed coverage with no gaps and no leftover strip. But a feed has
/// no closed rectangle: it pages forever. Slicing gives the algorithm the finite
/// canvas it needs while leaving the feed unbounded, and it bounds the work: a
/// slice is generated once and never revisited, so pagination cannot disturb
/// anything already on screen.
///
/// **Pure and deterministic.** No UIKit, no stored state, no clock. The same
/// `(cellCount, sliceSize, seed)` always yields the same blocks, which is what
/// lets the layout cache slices, the arrangement pass agree with the layout
/// about what shape each slot is, and a scroll back up land on the tiling it
/// left.
public struct ChaoticSliceEngine: Sendable {
    /// The shapes a block is scored against. A cut is chosen to put its
    /// offspring near one of these, so the tiling stays irregular without
    /// producing slivers or letterboxes.
    public var allowedRatios: [CGFloat]

    /// Where along a block's long axis the primary cut is tried. The secondary
    /// cut is always at the midpoint, which is what gives the pattern its
    /// characteristic "one large block beside a stacked pair" rhythm.
    public var candidateRatios: [CGFloat]

    /// How far each candidate may be nudged, per slice, by the seeded generator.
    ///
    /// **This is what makes the layout chaotic rather than merely irregular.**
    /// The scoring rule is deterministic and the "always split the largest
    /// block" rule fixes the split *order*, so without a seed every slice in the
    /// feed resolves to the identical tiling — the same picture stacked down the
    /// scroll, repeating on a period the eye finds immediately. Jittering the
    /// candidates varies the proportions per slice while leaving coverage,
    /// determinism and the aspect-ratio discipline untouched.
    public var ratioJitter: CGFloat

    /// The smallest side, in points, a block may be cut down to.
    ///
    /// A tile is not just an image: it carries the view/reaction counters and a
    /// play badge, which need roughly 90pt of width to read. Below that the
    /// furniture collides with itself. The floor is enforced as a scoring
    /// penalty rather than a hard rejection so the search degrades gracefully —
    /// when no cut can respect it, the engine stops splitting and reports the
    /// blocks it did produce.
    public var minimumTileSide: CGFloat

    /// How close two *touching* blocks' aspects may be, in log space, before
    /// they read as a repeated shape rather than a composition.
    ///
    /// Log space because aspect is a ratio: 2:1 and 1:2 are equally far from
    /// square, and a linear comparison would rate the wide one four times
    /// worse.
    ///
    /// **Deliberately narrower than the gap between two `allowedRatios`.** The
    /// closest pairs in that set — 3/4 against 5/6, and 6/5 against 4/3 — are
    /// only 0.105 apart in log space. A tolerance above that marks two blocks
    /// as repeats when they are sitting correctly on *different* targets, which
    /// puts the ratio rule and this one in direct conflict: the tighter the
    /// tiling clusters on the five shapes, the more "twins" it is charged for.
    /// At 0.09 a twin means what it should — the same target twice, adjacent.
    public var adjacentRatioTolerance: CGFloat

    /// Score added per pair of touching blocks that are within
    /// `adjacentRatioTolerance` of each other.
    ///
    /// Deliberately an order of magnitude BELOW what a block pays for missing
    /// its target ratio (see `aspectWeight`). Twin avoidance is a tiebreak
    /// among well-proportioned cuts, not a reason to accept a badly
    /// proportioned one — when it was allowed to outrank shape it dragged the
    /// tiling to 0.23 and 2.67.
    public var twinPenalty: CGFloat

    /// How hard a block is pulled toward the nearest `allowedRatios` entry.
    ///
    /// The raw distance is small — the five targets span 0.75…1.333, so nothing
    /// inside the band is ever more than ~0.1 from one of them — which left it
    /// losing to a couple of twin charges. Multiplying restores the intended
    /// precedence: shape first, repetition second.
    public var aspectWeight: CGFloat

    /// The shapes a block may take at all, as opposed to the shapes it is
    /// scored toward.
    ///
    /// `allowedRatios` is a target the search minimises distance to; on its own
    /// nothing stops a block ending up far from all of them when the
    /// alternatives are worse. The row limit and twin avoidance both push in
    /// that direction, and together they produced blocks at 0.23 and 2.67 — a
    /// 1:4 sliver and a 2.7:1 letterbox — while the MEAN stayed a healthy 0.87.
    /// This is the guard rail the mean hides: outliers, not averages, are what
    /// reads as broken.
    ///
    /// Held just outside the five targets' own span (0.75…1.333) rather than
    /// generously wide: the slack is for the rounding either side of a snapped
    /// edge, not for shapes that were never wanted.
    ///
    /// Enforced by a penalty an order of magnitude above any aspect score but
    /// well below `floorPenalty`, so it outranks every ordinary preference
    /// while still yielding to "produce the requested count at all".
    public var aspectBounds: ClosedRange<CGFloat>

    /// The most blocks any horizontal cross-section of a slice may contain.
    ///
    /// Three is the width limit the grid reads well at: a 393pt phone divided
    /// four ways leaves ~98pt tiles, which is where covers stop being legible
    /// and the counters start colliding with the play badge. Enforced as a hard
    /// rejection against the *whole* candidate block set at every split, so the
    /// finished slice satisfies it rather than merely tending toward it.
    public var maximumBlocksPerRow: Int

    public init(
        allowedRatios: [CGFloat] = [4.0 / 3.0, 5.0 / 6.0, 3.0 / 4.0, 6.0 / 5.0, 1.0],
        candidateRatios: [CGFloat] = [0.4, 0.45, 0.5, 0.55, 0.6],
        ratioJitter: CGFloat = 0.07,
        minimumTileSide: CGFloat = 88,
        adjacentRatioTolerance: CGFloat = 0.09,
        twinPenalty: CGFloat = 0.25,
        aspectWeight: CGFloat = 12,
        aspectBounds: ClosedRange<CGFloat> = 0.72...1.4,
        maximumBlocksPerRow: Int = 3
    ) {
        self.allowedRatios = allowedRatios
        self.candidateRatios = candidateRatios
        self.ratioJitter = ratioJitter
        self.minimumTileSide = minimumTileSide
        self.adjacentRatioTolerance = adjacentRatioTolerance
        self.twinPenalty = twinPenalty
        self.aspectWeight = aspectWeight
        self.aspectBounds = aspectBounds
        self.maximumBlocksPerRow = maximumBlocksPerRow
    }

    public static let standard = ChaoticSliceEngine()

    /// Added to a cut's score for every block it would produce below
    /// `minimumTileSide`. Large enough that no aspect-ratio gain can ever buy an
    /// undersized tile, and used as the sentinel that means "every cut here is
    /// unacceptable".
    static let floorPenalty: CGFloat = 1000

    /// Added per block falling outside `aspectBounds`. Above any aspect score
    /// or stack of twin charges, below `floorPenalty`.
    static let outOfBandPenalty: CGFloat = 10

    /// The clamp on a jittered candidate.
    ///
    /// Wide on purpose. A narrow clamp is not a safety rail here — it is what
    /// stops the search finding an in-band cut at all: a tall parent needs an
    /// off-centre seam to yield square-ish children, and clamping to 0.3…0.7
    /// left the engine no way to make one, so it produced out-of-band blocks
    /// instead. The `aspectBounds` penalty is what keeps extreme cuts out; this
    /// only has to keep a seam off the very edge of a block.
    public var candidateBounds: ClosedRange<CGFloat> = 0.18...0.82

    // MARK: - Generation

    /// Partitions the unit square into `cellCount` blocks.
    ///
    /// Returns blocks in **unit space** (0…1 on both axes), so one plan serves
    /// every device: the caller scales it by the real slice size. `sliceSize` is
    /// still required because both scoring inputs depend on it — the aspect of a
    /// block is its unit shape times the slice's own aspect, and the minimum-side
    /// floor is expressed in points.
    ///
    /// **The count is a request, not a promise.** When the floor bites, fewer
    /// blocks come back than were asked for; the caller must lay out what it is
    /// given and carry the remainder into the next slice rather than assume the
    /// count it passed in.
    public func plan(cellCount: Int, sliceSize: CGSize, seed: UInt64) -> SlicePlan {
        guard cellCount > 0, sliceSize.width > 0, sliceSize.height > 0 else {
            return SlicePlan(blocks: [])
        }
        let sliceAspect = sliceSize.width / sliceSize.height
        // The floor in unit terms. Capped at half so a pathologically small
        // slice cannot make even the first cut illegal and return a single
        // block where a tiling was wanted.
        let floorWidth = min(0.5, minimumTileSide / sliceSize.width)
        let floorHeight = min(0.5, minimumTileSide / sliceSize.height)

        func score(_ width: CGFloat, _ height: CGFloat) -> CGFloat {
            guard width > 0, height > 0 else { return .infinity }
            var penalty: CGFloat = (width < floorWidth || height < floorHeight) ? Self.floorPenalty : 0
            let aspect = (width * sliceAspect) / height
            // Out of band costs a flat charge PLUS a term that grows with how
            // far out it is.
            //
            // A BSP cannot choose every shape it produces: the last child of a
            // cut is whatever area the parent has left, so roughly one block per
            // slice is a complement rather than a choice and lands just outside
            // the band. That is tolerable. What is not is that a flat charge
            // prices a near miss at 1.52 exactly the same as a 2.52 letterbox,
            // leaving the search no reason to prefer the near miss when it is
            // cornered. The excess term is what makes "miss narrowly" cheaper
            // than "miss badly".
            if !aspectBounds.contains(aspect) {
                let excess = aspect < aspectBounds.lowerBound
                    ? log(aspectBounds.lowerBound / aspect)
                    : log(aspect / aspectBounds.upperBound)
                penalty += Self.outOfBandPenalty * (1 + excess * 10)
            }
            // Distance in LOG space. Aspect is a ratio, so 2:1 and 1:2 are
            // equally wrong and must cost the same — linear distance rates the
            // tall one four times cheaper and quietly prefers slivers.
            //
            // It also steepens where it matters. Against the flat out-of-band
            // charge, a linear term barely separates a 1.45 from a 0.21 once
            // both are outside the band (4.6x); in log space that gap is 15x, so
            // when the search is cornered it takes the near miss instead of the
            // sliver.
            return aspectWeight * abs(log(aspect) - log(nearestAllowedRatio(to: aspect))) + penalty
        }

        var random = SplitMix64(seed: seed)
        var blocks = [CGRect(x: 0, y: 0, width: 1, height: 1)]

        while blocks.count < cellCount {
            // A three-way cut nets +2 blocks, a bisect +1. Preferring three-way
            // gives the pattern its rhythm; the bisect exists so *every* count
            // is reachable. Without it the block count can only ever be odd
            // (1, 3, 5, …), which cannot express a feed's tail or a gallery of
            // eight posts.
            let allowsThreeWay = blocks.count + 2 <= cellCount

            // Two jittered sets per cut — one for each axis of the search — so
            // blocks within a slice differ from each other as well as from the
            // neighbouring slice's. Drawn once per SPLIT, before any target is
            // considered, and unconditionally: the draw COUNT must not depend on
            // which branch is taken or on how many targets get tried, or the
            // sequence stops being reproducible.
            let primaries = jitteredCandidates(&random)
            let secondaries = jitteredCandidates(&random)

            // Prefer the largest block, but do not insist on it.
            //
            // Splitting the largest is what keeps tile areas in the same order
            // of magnitude — a depth-first BSP shreds one corner and leaves the
            // rest untouched. But insisting on it is what manufactured the
            // letterboxes: once a row holds `maximumBlocksPerRow` blocks, a
            // vertical cut through any of them is illegal, so the only legal
            // move on a wide block is a horizontal bisect — and bisecting a
            // 377x294 block gives two 377x147 strips at aspect 2.56. Measured,
            // that single mechanism produced most of the out-of-band blocks.
            //
            // Trying the next-largest instead costs a little area balance and
            // removes the whole failure mode: some other block almost always
            // has a well-proportioned cut available.
            //
            // **Badly shaped blocks are offered first, ahead of area.** A block
            // that is already out of band can only be *fixed* by splitting it —
            // halving a 2:1 letterbox gives two squares — and ordering targets
            // by area alone means a small out-of-band block is never picked
            // again, so it survives to the finished slice. That, not the choice
            // of cut, is where the stubborn 10% of outliers came from: they were
            // not created badly so much as abandoned.
            func isOutOfBand(_ block: CGRect) -> Bool {
                guard block.height > 0 else { return true }
                return !aspectBounds.contains((block.width * sliceAspect) / block.height)
            }
            let candidateTargets = blocks.indices.sorted { lhs, rhs in
                let leftOut = isOutOfBand(blocks[lhs])
                let rightOut = isOutOfBand(blocks[rhs])
                if leftOut != rightOut { return leftOut }
                let leftArea = blocks[lhs].width * blocks[lhs].height
                let rightArea = blocks[rhs].width * blocks[rhs].height
                if leftArea != rightArea { return leftArea > rightArea }
                if blocks[lhs].minY != blocks[rhs].minY { return blocks[lhs].minY < blocks[rhs].minY }
                return blocks[lhs].minX < blocks[rhs].minX
            }

            // Ordered preferences, best first. The search takes the earliest
            // stage that yields a usable cut and never compares across stages.
            //
            // **Why a bisect has to be offered even when a three-way fits.**
            // Once a row holds `maximumBlocksPerRow` blocks, none of them can
            // take a three-way cut at all: both orientations put another block
            // across that row. Only a horizontal bisect — whose children stack
            // in the same column — stays legal. Reaching for the bisect solely
            // when a three-way was unaffordable stalls the whole slice there;
            // measured, it capped an 11-cell slice at 9 blocks.
            //
            // **And why stages rather than one pooled search.** The score is a
            // SUM over children, so a two-child split is systematically cheaper
            // than a three-child one. Pooling them would make the bisect win on
            // arithmetic rather than on merit and flatten the pattern into
            // stripes. Comparisons stay inside a stage, where every candidate
            // has the same number of children.
            //
            // **Twin avoidance is a penalty only — deliberately not a stage.**
            // Ranking twin-free cuts ahead of everything else made repetition
            // outrank shape, and the search bought its way out of a repeat with
            // whatever proportions were left: measured, that widened the tiling
            // to 0.23…2.80. It belongs *inside* the score, an order of
            // magnitude under `aspectWeight`, so it only ever separates cuts
            // that are already well proportioned.
            var arities: [Bool] = []
            if allowsThreeWay { arities.append(true) }
            arities.append(false)

            var pick: (targetIndex: Int, split: [CGRect])?

            // The row limit is relaxed only after EVERY block has been tried
            // under it — it is a hard rule about how the grid reads, and buying
            // a better aspect with a fourth tile across is not a trade worth
            // making. Nesting it outside the target loop is what makes that
            // true: with the relaxed stages merely ranked lower per target, a
            // single block with no in-band legal cut was enough to widen a row
            // to four.
            levels: for enforcesRowLimit in [true, false] {
                var levelFallback: (targetIndex: Int, split: [CGRect])?

                for targetIndex in candidateTargets {
                    let target = blocks[targetIndex]
                    var others = blocks
                    others.remove(at: targetIndex)

                    // Best candidate per arity, kept rather than taken, because
                    // preference order alone is not enough to choose between
                    // them: an arity that can only offer a sliver must LOSE to
                    // one that offers a well-proportioned block, or
                    // `aspectBounds` is a suggestion.
                    var results: [(score: CGFloat, split: [CGRect])] = []
                    for threeWay in arities {
                        var best: [CGRect]?
                        var bestScore = CGFloat.infinity
                        for primary in primaries {
                            // The secondary cut only exists on a three-way
                            // split; a bisect has one seam. Searching it anyway
                            // would just evaluate the same two candidates five
                            // times over.
                            let splits = threeWay
                                ? secondaries.flatMap {
                                    Self.threeWayCuts(of: target, primary: primary, secondary: $0)
                                }
                                : Self.bisections(of: target, at: primary)
                            for split in splits {
                                if enforcesRowLimit,
                                   exceedsRowLimit(split, within: target, among: others) {
                                    continue
                                }
                                let total = split.reduce(CGFloat.zero) { $0 + score($1.width, $1.height) }
                                    + twinCost(of: split, among: others, sliceAspect: sliceAspect)
                                if total < bestScore {
                                    bestScore = total
                                    best = split
                                }
                            }
                        }
                        guard let best else { continue }
                        results.append((bestScore, best))
                        // Nothing later can beat an in-band result from an
                        // earlier arity, so stop as soon as one appears.
                        if bestScore < Self.outOfBandPenalty { break }
                    }

                    if let inBand = results.first(where: { $0.score < Self.outOfBandPenalty }) {
                        pick = (targetIndex, inBand.split)
                        break levels
                    }
                    // Remember the first (largest) block that could be split at
                    // all, in case no block at this level has an in-band cut.
                    if levelFallback == nil,
                       let legal = results.first(where: { $0.score < Self.floorPenalty }) {
                        levelFallback = (targetIndex, legal.split)
                    }
                }

                if let levelFallback {
                    pick = levelFallback
                    break levels
                }
            }

            // No block anywhere can be cut without producing a tile too small to
            // carry its own furniture. Stop: a short slice of legible tiles
            // beats a full one of unusable ones.
            guard let pick else { break }
            blocks.remove(at: pick.targetIndex)
            blocks.append(contentsOf: pick.split)
        }
        return SlicePlan(blocks: blocks)
    }

    /// The three-way cut, in both orientations.
    ///
    /// Option A cuts vertically at `primary` and splits the trailing column at
    /// `secondary`; option B cuts horizontally at `primary` and splits the lower
    /// band at `secondary`. Both are exact complements of the target, which is
    /// where gap-free coverage comes from — no cut ever invents or discards
    /// area.
    ///
    /// **The secondary cut is searched, not fixed at the midpoint.** Halving it
    /// makes the two offspring exact twins — same width, same height — every
    /// time, which is what produced the prototype's row of four identical
    /// tiles. `twinCost` can only steer away from that if the search has
    /// somewhere else to go.
    private static func threeWayCuts(
        of target: CGRect, primary: CGFloat, secondary: CGFloat
    ) -> [[CGRect]] {
        let leadingWidth = target.width * primary
        let trailingWidth = target.width - leadingWidth
        let upperHeight = target.height * primary
        let lowerHeight = target.height - upperHeight
        let splitWidth = target.width * secondary
        let splitHeight = target.height * secondary
        return [
            [
                CGRect(x: target.minX, y: target.minY, width: leadingWidth, height: target.height),
                CGRect(x: target.minX + leadingWidth, y: target.minY, width: trailingWidth, height: splitHeight),
                CGRect(
                    x: target.minX + leadingWidth, y: target.minY + splitHeight,
                    width: trailingWidth, height: target.height - splitHeight
                )
            ],
            [
                CGRect(x: target.minX, y: target.minY, width: target.width, height: upperHeight),
                CGRect(x: target.minX, y: target.minY + upperHeight, width: splitWidth, height: lowerHeight),
                CGRect(
                    x: target.minX + splitWidth, y: target.minY + upperHeight,
                    width: target.width - splitWidth, height: lowerHeight
                )
            ]
        ]
    }

    /// One jittered pass over `candidateRatios`.
    private func jitteredCandidates(_ random: inout SplitMix64) -> [CGFloat] {
        candidateRatios.map { candidate in
            (candidate + (random.unit() - 0.5) * 2 * ratioJitter)
                .clamped(to: candidateBounds)
        }
    }

    /// The two-way cut, in both orientations — the tail case that makes every
    /// block count reachable.
    private static func bisections(of target: CGRect, at ratio: CGFloat) -> [[CGRect]] {
        let leadingWidth = target.width * ratio
        let upperHeight = target.height * ratio
        return [
            [
                CGRect(x: target.minX, y: target.minY, width: leadingWidth, height: target.height),
                CGRect(
                    x: target.minX + leadingWidth, y: target.minY,
                    width: target.width - leadingWidth, height: target.height
                )
            ],
            [
                CGRect(x: target.minX, y: target.minY, width: target.width, height: upperHeight),
                CGRect(
                    x: target.minX, y: target.minY + upperHeight,
                    width: target.width, height: target.height - upperHeight
                )
            ]
        ]
    }

    // MARK: - Harmony rules

    /// Tolerance for "these two edges are the same edge". Blocks are exact
    /// complements in unit space, but the arithmetic that produces a shared
    /// edge differs on each side of it, so the values agree only to within
    /// floating-point noise.
    private static let edgeEpsilon: CGFloat = 1e-9

    /// Whether two blocks touch along a shared edge with real overlap.
    ///
    /// Corner-to-corner contact does not count: two blocks meeting at a single
    /// point share no visible seam, so their shapes rhyming is not what the eye
    /// picks up. The overlap test is what excludes it.
    static func areAdjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps = edgeEpsilon
        let sharesVerticalEdge = abs(a.maxX - b.minX) < eps || abs(b.maxX - a.minX) < eps
        if sharesVerticalEdge, min(a.maxY, b.maxY) - max(a.minY, b.minY) > eps { return true }
        let sharesHorizontalEdge = abs(a.maxY - b.minY) < eps || abs(b.maxY - a.minY) < eps
        return sharesHorizontalEdge && min(a.maxX, b.maxX) - max(a.minX, b.minX) > eps
    }

    /// The penalty for a candidate split placing near-identical shapes side by
    /// side.
    ///
    /// Checked against the split's own children *and* against the blocks
    /// already in the slice: a child that rhymes with the neighbour it was cut
    /// next to reads exactly as badly as two siblings rhyming with each other,
    /// and only the second of those is visible from inside the split.
    private func twinCost(of split: [CGRect], among others: [CGRect], sliceAspect: CGFloat) -> CGFloat {
        func logAspect(_ rect: CGRect) -> CGFloat {
            guard rect.width > 0, rect.height > 0 else { return 0 }
            return log((rect.width * sliceAspect) / rect.height)
        }
        var cost: CGFloat = 0
        for (index, child) in split.enumerated() {
            let childLogAspect = logAspect(child)
            func chargeIfTwin(_ other: CGRect) {
                guard Self.areAdjacent(child, other),
                      abs(childLogAspect - logAspect(other)) < adjacentRatioTolerance
                else { return }
                cost += twinPenalty
            }
            for sibling in split[(index + 1)...] { chargeIfTwin(sibling) }
            for other in others { chargeIfTwin(other) }
        }
        return cost
    }

    /// Whether a candidate split would put more than `maximumBlocksPerRow`
    /// blocks across any horizontal cross-section.
    ///
    /// **Only the target's own vertical span has to be re-checked.** A split
    /// adds blocks strictly inside the target, so no cross-section outside it
    /// changes — and every one inside was legal before, or the split that made
    /// it would have been rejected. That reduces the test from the whole slice
    /// to the handful of blocks level with the target.
    ///
    /// The count is piecewise constant in y and can only change at a block's
    /// top edge, so probing each block's `minY` samples every distinct row.
    private func exceedsRowLimit(_ split: [CGRect], within target: CGRect, among others: [CGRect]) -> Bool {
        let eps = Self.edgeEpsilon
        var band = others.filter { $0.maxY > target.minY + eps && $0.minY < target.maxY - eps }
        band.append(contentsOf: split)
        for probe in band {
            let row = probe.minY + eps
            var count = 0
            for block in band where block.minY <= row && block.maxY > row { count += 1 }
            if count > maximumBlocksPerRow { return true }
        }
        return false
    }

    /// Largest by area, ties broken top-to-bottom then leading-to-trailing.
    ///
    /// The total order is deliberate: `Array.sort` is not stable, so leaving
    /// equal-area blocks to compare equal would make the split order an artefact
    /// of the sort implementation. Determinism is the whole contract here.
    private func indexOfLargestBlock(in blocks: [CGRect]) -> Int {
        var best = 0
        for index in blocks.indices.dropFirst() {
            let candidate = blocks[index]
            let incumbent = blocks[best]
            let candidateArea = candidate.width * candidate.height
            let incumbentArea = incumbent.width * incumbent.height
            if candidateArea != incumbentArea {
                if candidateArea > incumbentArea { best = index }
            } else if candidate.minY != incumbent.minY {
                if candidate.minY < incumbent.minY { best = index }
            } else if candidate.minX < incumbent.minX {
                best = index
            }
        }
        return best
    }

    /// Nearest by log distance, matching how `score` measures the gap — picking
    /// the target linearly and then measuring the error logarithmically would
    /// let a block be scored against a ratio that is not actually its closest.
    func nearestAllowedRatio(to aspect: CGFloat) -> CGFloat {
        guard aspect > 0 else { return allowedRatios.first ?? 1 }
        let logAspect = log(aspect)
        return allowedRatios.min {
            abs(log($0) - logAspect) < abs(log($1) - logAspect)
        } ?? aspect
    }
}

// MARK: - Plan

/// One slice's tiling, in unit space.
public struct SlicePlan: Sendable, Equatable {
    /// Blocks in generation order — largest-first splits, so *not* reading
    /// order. The layout maps them onto consecutive item indices as they come,
    /// which is what makes a block's index a pure function of its slice.
    public let blocks: [CGRect]

    public var count: Int { blocks.count }

    /// What each block looks like once the slice has real dimensions: its
    /// on-screen aspect and its share of the slice's area. This is the whole
    /// interface the arrangement pass needs — it decides which post belongs in
    /// which slot without ever seeing a frame.
    public func metrics(sliceAspect: CGFloat) -> [SlotMetrics] {
        blocks.map { block in
            SlotMetrics(
                aspect: block.height > 0 ? (block.width * sliceAspect) / block.height : 1,
                relativeArea: block.width * block.height
            )
        }
    }
}

/// What a layout slot *is*, stripped of position — the shape a post will be
/// cropped to and how much of the slice it occupies.
public struct SlotMetrics: Sendable, Equatable {
    /// On-screen width ÷ height.
    public let aspect: CGFloat
    /// Block area as a fraction of the slice, 0…1.
    public let relativeArea: CGFloat

    public init(aspect: CGFloat, relativeArea: CGFloat) {
        self.aspect = aspect
        self.relativeArea = relativeArea
    }
}

// MARK: - Deterministic randomness

/// SplitMix64 — a seeded generator, used instead of `SystemRandomNumberGenerator`
/// because the tiling must be reproducible: the same slice index must yield the
/// same blocks on every relayout, in every process, or a rotation or a page
/// landing would re-tile content the viewer is already looking at.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<1, from the 53 bits a `Double` can hold exactly.
    mutating func unit() -> CGFloat {
        CGFloat(Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0))
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
