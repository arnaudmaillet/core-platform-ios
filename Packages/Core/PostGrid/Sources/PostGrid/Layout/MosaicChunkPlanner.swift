import CoreGraphics
import CoreModels
import Foundation

// MARK: - A chunk

/// A piece of the chaotic mosaic set into a list of cards: one BSP tiling of a
/// CLOSED rectangle, 2 to 4 "rows" tall.
///
/// **Why the bottom edge is flush by construction.** `ChaoticSliceEngine.plan`
/// partitions the unit square — every point of it belongs to exactly one block
/// — so the blocks touching its bottom edge cover that edge end to end. A chunk
/// is only ever shown COMPLETE (one post per block; see
/// `MosaicChunkPlanner.segments`), so its tiles' feet all sit on one line, and
/// the card after it starts straight across. The feed's own mosaic can leave a
/// ragged foot because its last slice may be partly filled; a chunk never is.
///
/// "Rows" is a HEIGHT, not a structure: a chaotic tiling has no rows — a tall
/// tile spans what a short one beside it does twice — so `rows` only says how
/// tall the rectangle is, in units of a typical tile's height.
public struct MosaicChunk: Sendable, Equatable {
    /// Which chunk of the list this is, counting skipped ones — the seed of its
    /// tiling, so a chunk looks the same every time the list is built.
    public let ordinal: Int
    /// The rectangle's height in "rows" (`MosaicChunkPlanner.rowRange`).
    public let rows: Int
    /// The tiles in unit space (0…1 on both axes), in READING order — top to
    /// bottom, then leading to trailing — which is the order the chunk's posts
    /// are laid out, played and opened in.
    public let blocks: [CGRect]

    public var tileCount: Int { blocks.count }

    /// Height over width. Fixed per chunk, so the tiling's SHAPES are the same
    /// on every phone and only its scale changes.
    public var heightRatio: CGFloat { CGFloat(rows) * MosaicChunkPlanner.rowHeightRatio }

    /// The chunk's height for a canvas `width`, on the pixel grid — the exact
    /// value `frames` places its bottom edge on.
    public func height(forWidth width: CGFloat, pixelScale: CGFloat) -> CGFloat {
        Self.snap(width * heightRatio, scale: pixelScale)
    }

    /// Each tile's frame in a canvas `width` wide, with `gutter` between tiles
    /// and none on the canvas edges.
    ///
    /// Edges are snapped, not origins and sizes — the same rule as the feed's
    /// slices (`ChaoticSliceEngine.stack`): two neighbours share an edge value,
    /// so rounding the edge rounds both sides of the seam identically. Half the
    /// gutter comes off each SHARED edge; an edge on the canvas boundary keeps
    /// its full extent. That is what puts every bottom tile's foot exactly on
    /// `height(forWidth:)`.
    public func frames(width: CGFloat, gutter: CGFloat, pixelScale: CGFloat) -> [CGRect] {
        guard width > 0 else { return [] }
        let height = height(forWidth: width, pixelScale: pixelScale)
        let half = gutter / 2
        // Unit edges ARE exact (0 and 1 come out of the partition as literals),
        // but a seam is a sum of fractions; a tolerance keeps a seam a hair
        // inside the canvas from reading as a boundary.
        let slack: CGFloat = 1e-6
        return blocks.map { block in
            let minX = Self.snap(block.minX * width, scale: pixelScale)
            let maxX = block.maxX >= 1 - slack ? width : Self.snap(block.maxX * width, scale: pixelScale)
            let minY = Self.snap(block.minY * height, scale: pixelScale)
            let maxY = block.maxY >= 1 - slack ? height : Self.snap(block.maxY * height, scale: pixelScale)
            let leading = block.minX <= slack ? 0 : half
            let trailing = block.maxX >= 1 - slack ? 0 : half
            let top = block.minY <= slack ? 0 : half
            let bottom = block.maxY >= 1 - slack ? 0 : half
            return CGRect(
                x: minX + leading,
                y: minY + top,
                width: max(0, maxX - minX - leading - trailing),
                height: max(0, maxY - minY - top - bottom)
            )
        }
    }

    /// Each slot's shape, for `PostGridSliceArrangement` to steer each post
    /// into the tile that crops it least.
    public var slotMetrics: [SlotMetrics] {
        let aspect = 1 / heightRatio
        return blocks.map { block in
            SlotMetrics(
                aspect: block.height > 0 ? (block.width * aspect) / block.height : 1,
                relativeArea: block.width * block.height
            )
        }
    }

    static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = scale > 0 ? scale : 3
        return (value * scale).rounded() / scale
    }
}

// MARK: - Segments

/// One stretch of the Discover list: a run of full-width cards, or a chunk of
/// mosaic. The list is these, in order, and nothing else.
public enum DiscoverSegment: Sendable, Equatable {
    case rows([GalleryPost])
    /// The chunk and its posts, one per block, in the chunk's reading order.
    case chunk(MosaicChunk, [GalleryPost])

    public var posts: [GalleryPost] {
        switch self {
        case .rows(let posts): posts
        case .chunk(_, let posts): posts
        }
    }

    public var chunk: MosaicChunk? {
        if case .chunk(let chunk, _) = self { return chunk }
        return nil
    }

    /// The STRUCTURE only — which posts, in which shape. What an update is
    /// judged on: a post whose counters moved is the same post in the same
    /// place, and must not turn a page landing into a reload.
    fileprivate var shape: [String] {
        switch self {
        case .rows(let posts): ["rows"] + posts.map(\.id.rawValue)
        case .chunk(let chunk, let posts):
            ["chunk \(chunk.ordinal)/\(chunk.rows)"] + posts.map(\.id.rawValue)
        }
    }
}

/// How a new set of segments relates to the one on screen.
public enum DiscoverSegmentsChange: Equatable, Sendable {
    /// Nothing structural moved.
    case identical
    /// The old list is a prefix of the new one: `grownItems` more posts at the
    /// end of the old LAST section (a run of cards still filling), then
    /// `appendedSections` new sections after it. What a page landing is, and
    /// what lets it be an insert rather than a reload.
    case extended(grownItems: Range<Int>, appendedSections: Range<Int>)
    /// Anything else — a re-derived corpus. Reload.
    case incompatible
}

// MARK: - The planner

/// Decides where the Discover list's mosaic chunks go and which posts they
/// hold — a pure function of the ranked corpus.
///
/// **The rule.** The list reads `rows(3) · chunk · rows(3…6) · chunk · …`:
/// the first chunk after three cards, then one every three to six. A run of
/// cards takes the next posts IN CORPUS ORDER, of any kind; a chunk takes the
/// next MEDIA posts (`isTileEligible`), pulled forward from wherever they sit
/// further down. Every post is placed exactly once, so nothing is shown both as
/// a card and as a tile, and the cards stay in the order the corpus ranked them
/// — they only skip the media a chunk has already shown.
///
/// **Deterministic, seeded by position.** The gap before a chunk and the
/// chunk's height and tiling are drawn from SplitMix64 seeded by the chunk's
/// ORDINAL (plus a salt, so a chunk never repeats a feed slice's tiling). Not by
/// the session and not by the corpus: the same corpus always lays out the same
/// list — a refresh that returns the same posts changes nothing, and a relaunch
/// lands on the same shapes — while a different corpus fills the same shapes
/// with different posts. A per-session seed would reshuffle a list the viewer
/// had already read every time the app came back.
///
/// **Append-stable.** A page landing must never move what is on screen, so
/// every decision is taken only when the loaded corpus makes it FINAL:
/// - a run of cards may end short (the corpus ran out) and grow later — the
///   growth lands after its last card;
/// - a chunk is placed only when it can be filled completely: `k` media found
///   in the loaded posts, where `k` is its preferred size — or, once
///   `lookahead` posts have been scanned (or the corpus is complete), the
///   largest smaller chunk that fits, or no chunk at all (a lens that leaves
///   few media skips chunks rather than showing a ragged one).
/// Until a chunk is decided, nothing after it is shown. That hold-back is at
/// most `lookahead` posts at the very end of the loaded corpus, a screen and a
/// half past the viewport where pagination has already asked for more.
public struct MosaicChunkPlanner: Sendable {
    /// Cards before the first chunk.
    public static let firstGap = 3
    /// Cards between two chunks after the first.
    public static let gapRange: ClosedRange<Int> = 3...6
    /// A chunk's height, in rows.
    public static let rowRange: ClosedRange<Int> = 2...4
    /// A row's height as a fraction of the canvas width — ~155pt on a 361pt
    /// canvas, which is the feed mosaic's typical tile side, so a chunk reads
    /// as a window onto the same wall rather than as a different grid.
    public static let rowHeightRatio: CGFloat = 0.43
    /// How many unplaced posts a chunk may reach past its position for media
    /// before it settles for a smaller size or none. See the type's note.
    public static let lookahead = 24
    /// The canvas the tilings are generated against: a 393pt phone less the
    /// list's 16pt margins. The engine scores shapes and enforces its tile
    /// floor in points, so it needs a size; the chunk keeps its aspect on every
    /// phone, so the unit plan it produces holds everywhere.
    static let referenceWidth: CGFloat = 361
    /// Keeps a chunk's seed off the feed slices' (which are seeded by their
    /// bare index), so chunk 3 is not slice 3's tiling cut down.
    static let seedSalt: UInt64 = 0xD15C_0C4E_5EED

    public var engine: ChaoticSliceEngine

    /// Tilings already generated. The planner re-runs on every delivery over
    /// the whole corpus; the engine's search is the only part that costs.
    private var tilings: [TilingKey: MosaicChunk] = [:]

    private struct TilingKey: Hashable {
        let ordinal: Int
        let rows: Int
    }

    public init(engine: ChaoticSliceEngine = .standard) {
        self.engine = engine
    }

    /// Whether a post can be a tile: anything with a picture. A text post has
    /// nothing a tile could show, so it stays a card.
    public static func isTileEligible(_ post: GalleryPost) -> Bool {
        post.kind != .text
    }

    /// How many cards precede chunk `ordinal`.
    public static func gap(beforeChunk ordinal: Int) -> Int {
        guard ordinal > 0 else { return firstGap }
        var random = SplitMix64(seed: seedSalt &+ UInt64(ordinal))
        let span = UInt64(gapRange.count)
        return gapRange.lowerBound + Int(random.next() % span)
    }

    /// How tall chunk `ordinal` wants to be, in rows — before availability has
    /// its say.
    public static func preferredRows(forChunk ordinal: Int) -> Int {
        var random = SplitMix64(seed: seedSalt &+ UInt64(ordinal))
        _ = random.next() // the gap's draw
        let span = UInt64(rowRange.count)
        return rowRange.lowerBound + Int(random.next() % span)
    }

    /// Tiles asked of the engine for a chunk of `rows`: the feed mosaic's
    /// density (a tile of ~25k pt²) at this height.
    public static func requestedTiles(rows: Int) -> Int {
        rows * 2 + 1
    }

    /// Chunk `ordinal`'s tiling at `rows` tall.
    public mutating func chunk(ordinal: Int, rows: Int) -> MosaicChunk {
        let key = TilingKey(ordinal: ordinal, rows: rows)
        if let cached = tilings[key] { return cached }
        let size = CGSize(
            width: Self.referenceWidth,
            height: Self.referenceWidth * CGFloat(rows) * Self.rowHeightRatio
        )
        let plan = engine.plan(
            cellCount: Self.requestedTiles(rows: rows),
            sliceSize: size,
            seed: Self.seedSalt ^ (UInt64(ordinal) << 8 | UInt64(rows))
        )
        let made = MosaicChunk(
            ordinal: ordinal,
            rows: rows,
            blocks: plan.blocks.sorted {
                $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX
            }
        )
        tilings[key] = made
        return made
    }

    /// The list for `corpus`, in display order.
    ///
    /// `isComplete` says no further page is coming, which is what lets the
    /// tail's undecided chunk be decided (smaller, or skipped) and everything
    /// behind it shown.
    public mutating func segments(for corpus: [GalleryPost], isComplete: Bool) -> [DiscoverSegment] {
        var placed = [Bool](repeating: false, count: corpus.count)
        var cursor = 0
        var segments: [DiscoverSegment] = []
        var ordinal = 0

        func nextUnplaced() -> Int? {
            while cursor < corpus.count, placed[cursor] { cursor += 1 }
            return cursor < corpus.count ? cursor : nil
        }

        while true {
            // The run of cards before chunk `ordinal`.
            let gap = Self.gap(beforeChunk: ordinal)
            var run: [GalleryPost] = []
            while run.count < gap, let index = nextUnplaced() {
                placed[index] = true
                run.append(corpus[index])
            }
            if !run.isEmpty {
                // A skipped chunk leaves two runs back to back: they are one run.
                if case .rows(let previous)? = segments.last {
                    segments[segments.count - 1] = .rows(previous + run)
                } else {
                    segments.append(.rows(run))
                }
            }
            // Short: the corpus ran out mid-run, and the next page extends it.
            guard run.count == gap else { break }

            // The chunk: its media, from the unplaced posts ahead.
            var media: [Int] = []
            var scanned = 0
            var index = cursor
            while index < corpus.count, scanned < Self.lookahead {
                if !placed[index] {
                    scanned += 1
                    if Self.isTileEligible(corpus[index]) { media.append(index) }
                }
                index += 1
            }
            let isFinal = scanned >= Self.lookahead || isComplete
            let preferred = Self.preferredRows(forChunk: ordinal)
            var chosen: MosaicChunk?
            let wanted = chunk(ordinal: ordinal, rows: preferred)
            if media.count >= wanted.tileCount {
                chosen = wanted
            } else if isFinal {
                for rows in stride(from: preferred - 1, through: Self.rowRange.lowerBound, by: -1) {
                    let smaller = chunk(ordinal: ordinal, rows: rows)
                    if media.count >= smaller.tileCount {
                        chosen = smaller
                        break
                    }
                }
            } else {
                // Undecided: the next page may bring the media this chunk
                // wants. Nothing after it may be shown until it knows.
                break
            }
            if let chosen {
                let picked = media.prefix(chosen.tileCount)
                picked.forEach { placed[$0] = true }
                let arranged = PostGridSliceArrangement.arranged(
                    picked.map { corpus[$0] }, startingAt: 0, slotMetrics: chosen.slotMetrics
                )
                segments.append(.chunk(chosen, arranged))
            }
            ordinal += 1
        }
        return segments
    }

    /// How `new` relates to `old` — see `DiscoverSegmentsChange`.
    public static func change(
        from old: [DiscoverSegment], to new: [DiscoverSegment]
    ) -> DiscoverSegmentsChange {
        let oldShapes = old.map(\.shape)
        let newShapes = new.map(\.shape)
        if oldShapes == newShapes { return .identical }
        guard let last = old.indices.last, new.count >= old.count,
              Array(newShapes[..<last]) == Array(oldShapes[..<last])
        else { return .incompatible }
        // The old last section may only have GROWN, and only if it is a run of
        // cards: a chunk is placed complete and never changes.
        let before = oldShapes[last]
        let after = newShapes[last]
        guard after.count >= before.count, Array(after.prefix(before.count)) == before,
              after.count == before.count || old[last].chunk == nil
        else { return .incompatible }
        // Shapes carry a leading tag, hence the minus one for item counts.
        return .extended(
            grownItems: (before.count - 1)..<(after.count - 1),
            appendedSections: old.count..<new.count
        )
    }
}
