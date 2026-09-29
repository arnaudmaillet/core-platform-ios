import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import PostGrid

/// The Discover list's chunk planner: where the chunks go, what they hold, and
/// the one geometric promise a chunk makes — its bottom edge is flush.
struct MosaicChunkPlannerTests {
    // MARK: - Fixtures

    /// A corpus with the feed's usual mix: every third post is text, the rest
    /// photos and clips. Ids are the corpus position, so order is readable.
    private func corpus(_ count: Int, textEvery: Int = 3) -> [GalleryPost] {
        (0..<count).map { index in
            let kind: GalleryPost.Kind = index % textEvery == textEvery - 1
                ? .text
                : (index % 2 == 0 ? .photo : .video)
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: kind,
                isRepost: false,
                thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(index).jpg"),
                videoURL: kind == .video ? URL(string: "https://example.com/\(index).mp4") : nil,
                aspectRatio: index % 4 == 0 ? 0.5625 : 1.5,
                caption: "post \(index)",
                publishedAtMS: Int64(1_000 - index)
            )
        }
    }

    private func ids(_ posts: [GalleryPost]) -> [String] { posts.map(\.id.rawValue) }

    // MARK: - Placement

    /// "First chunk after 3 posts, then every 3 to 6" — read off a real plan,
    /// not off the gap function alone, so a planner that ignored its own gaps
    /// would fail here.
    @Test func theFirstChunkFollowsThreeCardsAndTheRestComeEveryThreeToSix() {
        var planner = MosaicChunkPlanner()
        let segments = planner.segments(for: corpus(400), isComplete: true)
        guard case .rows(let first)? = segments.first else {
            Issue.record("the list must open on cards")
            return
        }
        #expect(first.count == MosaicChunkPlanner.firstGap)
        #expect(segments.dropFirst().first?.chunk != nil, "the first chunk comes straight after")
        // Every run BETWEEN two chunks (the tail run may be short).
        var chunks = 0
        for (index, segment) in segments.enumerated() {
            guard case .rows(let run) = segment, index > 0, index < segments.count - 1 else {
                if segment.chunk != nil { chunks += 1 }
                continue
            }
            #expect(MosaicChunkPlanner.gapRange.contains(run.count),
                    "run \(index) holds \(run.count) cards")
        }
        #expect(chunks > 20, "a media-rich corpus places a chunk at every slot")
    }

    /// The gaps actually VARY — a constant 3 would pass the range check above.
    @Test func theGapsAreNotConstant() {
        let gaps = Set((1..<40).map(MosaicChunkPlanner.gap(beforeChunk:)))
        #expect(gaps.count >= 3, "gaps \(gaps.sorted())")
        #expect(gaps.isSubset(of: Set(MosaicChunkPlanner.gapRange)))
        let heights = Set((0..<40).map(MosaicChunkPlanner.preferredRows(forChunk:)))
        #expect(heights == Set(MosaicChunkPlanner.rowRange), "rows \(heights.sorted())")
    }

    /// Deterministic: the same corpus lays out the same list, planner to
    /// planner — which is what "does not reshuffle on reload" means.
    @Test func theSameCorpusLaysOutTheSameList() {
        var one = MosaicChunkPlanner()
        var two = MosaicChunkPlanner()
        let posts = corpus(160)
        #expect(one.segments(for: posts, isComplete: true) == two.segments(for: posts, isComplete: true))
        // And the cache does not change an answer.
        #expect(one.segments(for: posts, isComplete: true) == two.segments(for: posts, isComplete: true))
    }

    // MARK: - The partition

    /// Every post exactly once; tiles are media; cards keep corpus order.
    @Test func everyPostIsPlacedOnceAndTheCardsKeepTheirOrder() {
        for textEvery in [2, 3, 5, 50] {
            var planner = MosaicChunkPlanner()
            let posts = corpus(211, textEvery: textEvery)
            let segments = planner.segments(for: posts, isComplete: true)
            let placed = segments.flatMap { ids($0.posts) }
            #expect(placed.count == posts.count, "textEvery \(textEvery): placed \(placed.count)")
            #expect(Set(placed) == Set(ids(posts)), "nothing lost, nothing twice")

            let cards = segments.flatMap { segment -> [GalleryPost] in
                if case .rows(let run) = segment { return run }
                return []
            }
            let rank = Dictionary(uniqueKeysWithValues: posts.enumerated().map { ($1.id, $0) })
            let ranks = cards.compactMap { rank[$0.id] }
            #expect(ranks == ranks.sorted(), "cards are the corpus in order, minus what the chunks took")

            for case .chunk(let chunk, let tiles) in segments {
                #expect(tiles.count == chunk.tileCount, "a chunk is shown complete")
                #expect(tiles.allSatisfy(MosaicChunkPlanner.isTileEligible), "tiles are media")
            }
        }
    }

    /// A lens with no media at all: no chunk can be filled, so there are none —
    /// never a ragged one — and every post is still a card.
    @Test func aCorpusWithoutMediaIsOneRunOfCards() {
        var planner = MosaicChunkPlanner()
        let posts = corpus(40, textEvery: 1)
        let segments = planner.segments(for: posts, isComplete: true)
        #expect(segments.count == 1)
        #expect(segments.first.map { ids($0.posts) } == ids(posts))
    }

    // MARK: - Append stability

    /// A page landing extends the list; it never moves what was shown. Walked
    /// page by page, at several page sizes, with the corpus incomplete until
    /// the last one.
    @Test func aPageLandingOnlyExtendsTheList() {
        let posts = corpus(180)
        for pageSize in [7, 20, 33] {
            var planner = MosaicChunkPlanner()
            var shown: [DiscoverSegment] = []
            var loaded = 0
            while loaded < posts.count {
                loaded = min(posts.count, loaded + pageSize)
                let complete = loaded == posts.count
                let next = planner.segments(for: Array(posts[..<loaded]), isComplete: complete)
                let change = MosaicChunkPlanner.change(from: shown, to: next)
                #expect(shown.isEmpty || change != .incompatible,
                        "page size \(pageSize), loaded \(loaded): the list was re-planned")
                shown = next
            }
            // And the end state is exactly the whole corpus planned at once.
            var fresh = MosaicChunkPlanner()
            #expect(shown == fresh.segments(for: posts, isComplete: true))
        }
    }

    /// What a pending chunk holds back is bounded: fewer than `lookahead`
    /// posts, all at the very end of what is loaded.
    @Test func anUndecidedChunkHoldsBackLessThanTheLookahead() {
        let posts = corpus(300, textEvery: 2)
        for loaded in stride(from: 4, through: 300, by: 11) {
            var planner = MosaicChunkPlanner()
            let shown = planner.segments(for: Array(posts[..<loaded]), isComplete: false)
                .reduce(0) { $0 + $1.posts.count }
            #expect(loaded - shown < MosaicChunkPlanner.lookahead,
                    "loaded \(loaded), shown \(shown)")
        }
    }

    @Test func theChangeBetweenListsIsNamedCorrectly() {
        var planner = MosaicChunkPlanner()
        let posts = corpus(60)
        let whole = planner.segments(for: posts, isComplete: true)
        let head = planner.segments(for: Array(posts[..<20]), isComplete: false)
        #expect(MosaicChunkPlanner.change(from: whole, to: whole) == .identical)
        guard case .extended(let grown, let appended) = MosaicChunkPlanner.change(from: head, to: whole)
        else {
            Issue.record("a longer corpus must extend the shorter one's list")
            return
        }
        #expect(appended.lowerBound == head.count && appended.upperBound == whole.count)
        #expect(grown.lowerBound == head.last?.posts.count)
        // A different ranking is not an extension.
        let reranked = planner.segments(for: posts.reversed(), isComplete: true)
        #expect(MosaicChunkPlanner.change(from: whole, to: reranked) == .incompatible)
    }

    // MARK: - The flush bottom

    /// THE promise: whatever the seed, the height, the phone or the scale, the
    /// tiles resting on the chunk's foot cover it end to end — separated only
    /// by gutters — and every one of them ends exactly on the chunk's height.
    /// A chaotic tiling has no rows, so this is the only "alignment" it owes.
    @Test func everyChunkHasAFlushBottomEdge() {
        var planner = MosaicChunkPlanner()
        let gutter: CGFloat = 8
        for ordinal in 0..<120 {
            for rows in MosaicChunkPlanner.rowRange {
                let chunk = planner.chunk(ordinal: ordinal, rows: rows)
                #expect(chunk.tileCount >= 3, "chunk \(ordinal)/\(rows) is barely a mosaic")
                for width in [288.0, 343.0, 361.0, 398.0] as [CGFloat] {
                    for scale in [2.0, 3.0] as [CGFloat] {
                        let height = chunk.height(forWidth: width, pixelScale: scale)
                        let frames = chunk.frames(width: width, gutter: gutter, pixelScale: scale)
                        #expect(frames.allSatisfy { $0.maxY <= height + 1e-9 },
                                "chunk \(ordinal)/\(rows) overflows its foot")
                        let feet = frames.filter { abs($0.maxY - height) < 1e-9 }
                            .sorted { $0.minX < $1.minX }
                        #expect(feet.first.map { abs($0.minX) < 1e-9 } == true,
                                "chunk \(ordinal)/\(rows) @\(width)x\(scale): foot starts late")
                        #expect(feet.last.map { abs($0.maxX - width) < 1e-9 } == true,
                                "chunk \(ordinal)/\(rows) @\(width)x\(scale): foot ends early")
                        for (left, right) in zip(feet, feet.dropFirst()) {
                            #expect(abs(right.minX - left.maxX - gutter) < 1e-6,
                                    "chunk \(ordinal)/\(rows) @\(width)x\(scale): a hole in the foot")
                        }
                    }
                }
            }
        }
    }

    /// The unit plan is a PARTITION — the premise the flush foot rests on.
    @Test func everyChunkPartitionsItsRectangle() {
        var planner = MosaicChunkPlanner()
        for ordinal in 0..<60 {
            for rows in MosaicChunkPlanner.rowRange {
                let blocks = planner.chunk(ordinal: ordinal, rows: rows).blocks
                let area = blocks.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
                #expect(abs(area - 1) < 1e-9, "chunk \(ordinal)/\(rows) covers \(area)")
                for (index, block) in blocks.enumerated() {
                    for other in blocks[(index + 1)...] {
                        let overlap = block.intersection(other)
                        #expect(overlap.isNull || overlap.width * overlap.height < 1e-9)
                    }
                }
                // Reading order: what the chunk's posts are laid out in.
                for (earlier, later) in zip(blocks, blocks.dropFirst()) {
                    let inOrder = earlier.minY < later.minY
                        || (earlier.minY == later.minY && earlier.minX < later.minX)
                    #expect(inOrder, "chunk \(ordinal)/\(rows) is not in reading order")
                }
            }
        }
    }

    /// Gutters between tiles, none at the canvas edges — the margins are the
    /// list's own, so the chunk lines up with the cards above and below it.
    @Test func tilesTouchTheCanvasEdgesAndKeepAGutterBetween() {
        var planner = MosaicChunkPlanner()
        let chunk = planner.chunk(ordinal: 5, rows: 3)
        let frames = chunk.frames(width: 361, gutter: 8, pixelScale: 3)
        #expect(frames.contains { $0.minX == 0 } && frames.contains { $0.maxX == 361 })
        #expect(frames.contains { $0.minY == 0 })
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other), "tiles overlap")
            }
        }
    }
}
