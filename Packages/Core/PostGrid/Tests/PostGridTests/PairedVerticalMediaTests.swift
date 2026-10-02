import CoreGraphics
import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// Discover's vertical media as half-width cards in pairs (the
/// `-foryou-paired-vertical` experiment, unconditional since 2 October 2026).
/// The planner's rules — the threshold, blocks of 2 to 6, even, consecutive,
/// the odd one's partner, append stability, and a corpus with no vertical
/// media planned exactly as before pairing existed.
struct PairedVerticalMediaPlannerTests {
    // MARK: - Fixtures

    /// A corpus spelled one letter a post: `V` vertical (9:16), `W` 3:4,
    /// `F` 4:5 (stays full width), `P` landscape, `T` text, `C` a 9:16
    /// three-page collection. Ids are the corpus position.
    private func spelled(_ pattern: String) -> [GalleryPost] {
        pattern.enumerated().map { index, letter in
            if letter == "C" { return carousel(index) }
            let aspect: Double = switch letter {
            case "V": 9.0 / 16.0
            case "W": 3.0 / 4.0
            case "F": 4.0 / 5.0
            default: 1.5
            }
            let kind: GalleryPost.Kind = letter == "T" ? .text : (index % 2 == 0 ? .photo : .video)
            return post(index, kind: kind, aspect: aspect)
        }
    }

    private func post(_ index: Int, kind: GalleryPost.Kind, aspect: Double) -> GalleryPost {
        GalleryPost(
            id: PostID("p\(index)"),
            kind: kind,
            isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(index).jpg"),
            videoURL: kind == .video ? URL(string: "https://example.com/\(index).mp4") : nil,
            aspectRatio: aspect,
            caption: "post \(index)",
            publishedAtMS: Int64(1_000 - index)
        )
    }

    /// A collection whose every page is 9:16 — as vertical as media gets.
    private func carousel(_ index: Int) -> GalleryPost {
        GalleryPost(
            id: PostID("p\(index)"), kind: .photo, isRepost: false,
            pages: (0..<3).map { page in
                GalleryPost.MediaPage(
                    thumbnailURL: URL(string: "https://example.com/\(index)-\(page).jpg"),
                    aspectRatio: 9.0 / 16.0
                )
            },
            caption: "post \(index)", publishedAtMS: Int64(1_000 - index)
        )
    }

    /// The feed's mix with a vertical post every few: text every third, the
    /// rest alternating shapes so verticals arrive alone, in twos and in runs.
    private func mixed(_ count: Int, seed: UInt64 = 7) -> [GalleryPost] {
        var random = SplitMix64(seed: seed)
        return (0..<count).map { index in
            let roll = random.next() % 10
            let kind: GalleryPost.Kind = roll < 3 ? .text : (roll % 2 == 0 ? .photo : .video)
            let aspect: Double = roll >= 6 ? 9.0 / 16.0 : (roll == 5 ? 0.8 : 1.5)
            return post(index, kind: kind, aspect: aspect)
        }
    }

    private func ids(_ posts: [GalleryPost]) -> [String] { posts.map(\.id.rawValue) }

    private func paired(_ posts: [GalleryPost]) -> [DiscoverSegment] {
        var planner = MosaicChunkPlanner()
        return planner.segments(for: posts, isComplete: true)
    }

    // MARK: - The threshold

    /// Taller than 4:5 pairs; 4:5 itself (the full card's tallest uncropped
    /// preview), a re-encoded 4:5, square, landscape, text and an unmeasured
    /// post (which reads as square) do not.
    @Test func theThresholdIsTallerThanFourByFive() {
        func eligible(_ aspect: Double, _ kind: GalleryPost.Kind = .photo) -> Bool {
            VerticalMediaPairing.isEligible(post(0, kind: kind, aspect: aspect))
        }
        #expect(eligible(9.0 / 16.0))
        #expect(eligible(2.0 / 3.0))
        #expect(eligible(3.0 / 4.0))
        #expect(eligible(9.0 / 16.0, .video))
        #expect(!eligible(4.0 / 5.0), "4:5 is shown whole by a full card")
        #expect(!eligible(1080.0 / 1352.0), "a re-encoded 4:5 is still 4:5")
        #expect(!eligible(1))
        #expect(!eligible(1.5))
        #expect(!eligible(0), "no dimensions: fail closed")
        #expect(!eligible(0.5, .text))
        #expect(!VerticalMediaPairing.isEligible(carousel(0)), "a collection never pairs")
    }

    /// A collection is never paired, however vertical its pages — it stays a
    /// full-width card and ENDS a run of verticals as a landscape post does;
    /// it is never pulled forward as an odd run's partner either.
    @Test func aCarouselNeverEntersABlockAndBreaksARun() {
        let segments = paired(spelled("VVCVV" + String(repeating: "PT", count: 15)))
        #expect(ids(segments[0].posts) == ["p0", "p1"])
        #expect(segments[0].isPairs)
        guard case .rows(let cards) = segments[1] else {
            Issue.record("the carousel is a card")
            return
        }
        #expect(cards.first?.id == PostID("p2"))
        #expect(ids(segments[2].posts) == ["p3", "p4"])
        // Odd run, carousels ahead: the partner is the next SINGLE vertical.
        let odd = paired(spelled("VCCPV" + String(repeating: "PT", count: 15)))
        #expect(ids(odd[0].posts) == ["p0", "p4"])
        #expect(odd[0].isPairs)
        // Across a whole corpus: no block holds a collection.
        let mixed = (0..<120).map { index in
            index % 3 == 0 ? carousel(index) : post(index, kind: .photo, aspect: 9.0 / 16.0)
        }
        for case .pairs(let members) in paired(mixed) {
            #expect(!members.contains(where: { $0.isCollection }))
        }
    }

    // MARK: - No vertical media

    /// With nothing to pair, the list is EXACTLY the one the planner drew
    /// before pairing existed — pinned against a frozen copy of that loop, so
    /// a regression in the shared loop cannot hide behind the pairs.
    @Test func aCorpusWithoutVerticalMediaIsPlannedAsBeforePairing() {
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            for count in [5, 40, 211] {
                // The same mix, every vertical turned landscape.
                let posts = mixed(count, seed: seed).map { post in
                    VerticalMediaPairing.isEligible(post)
                        ? self.post(Int(post.id.rawValue.dropFirst())!, kind: post.kind, aspect: 1.5)
                        : post
                }
                for complete in [false, true] {
                    var planner = MosaicChunkPlanner()
                    var legacy = MosaicChunkPlanner()
                    let expected = Self.legacySegments(posts, isComplete: complete, planner: &legacy)
                    let planned = planner.segments(for: posts, isComplete: complete)
                    #expect(planned == expected, "seed \(seed) count \(count) complete \(complete)")
                    #expect(!planned.contains(where: { $0.isPairs }))
                }
            }
        }
    }

    // MARK: - Blocks

    /// Every block is even, 2 to 6, of eligible posts — and no post is lost
    /// or shown twice; the full-width cards keep corpus order.
    @Test func blocksAreEvenTwoToSixAndEveryPostIsPlacedOnce() {
        for seed in [1, 2, 3, 4, 5, 6] as [UInt64] {
            let posts = mixed(240, seed: seed)
            let segments = paired(posts)
            let placed = segments.flatMap { ids($0.posts) }
            #expect(placed.count == posts.count && Set(placed) == Set(ids(posts)), "seed \(seed)")
            var blocks = 0
            for case .pairs(let members) in segments {
                blocks += 1
                #expect(members.count.isMultiple(of: 2), "an odd block: \(ids(members))")
                #expect(VerticalMediaPairing.blockSizes.contains(members.count))
                #expect(members.allSatisfy(VerticalMediaPairing.isEligible))
            }
            #expect(blocks > 5, "seed \(seed): a vertical-rich corpus pairs")
            let rank = Dictionary(uniqueKeysWithValues: posts.enumerated().map { ($1.id, $0) })
            let cards = segments.flatMap { segment -> [GalleryPost] in
                if case .rows(let run) = segment { return run }
                return []
            }
            let ranks = cards.compactMap { rank[$0.id] }
            #expect(ranks == ranks.sorted(), "cards are the corpus in order")
            // A vertical post is a full card only when nothing could pair it:
            // here, at most the very last one.
            #expect(cards.filter(VerticalMediaPairing.isEligible).count <= 1,
                    "seed \(seed): \(ids(cards.filter(VerticalMediaPairing.isEligible)))")
        }
    }

    /// Consecutive verticals are one block, in corpus order.
    @Test func consecutiveVerticalsAreOneBlock() {
        let segments = paired(spelled("VWVV" + String(repeating: "PT", count: 15)))
        #expect(segments.first?.isPairs == true)
        #expect(ids(segments.first?.posts ?? []) == ["p0", "p1", "p2", "p3"])
    }

    /// A run longer than three rows is cut at six; the rest opens the next
    /// block straight after.
    @Test func aRunLongerThanSixIsCutAtSix() {
        let segments = paired(spelled(String(repeating: "V", count: 8) + String(repeating: "PT", count: 15)))
        #expect(ids(segments[0].posts) == ["p0", "p1", "p2", "p3", "p4", "p5"])
        #expect(segments[0].isPairs)
        #expect(ids(segments[1].posts) == ["p6", "p7"])
        #expect(segments[1].isPairs)
    }

    /// 4:5 is NOT vertical: it breaks a run and stays a full card.
    @Test func fourByFiveBreaksARun() {
        let segments = paired(spelled("VVFVV" + String(repeating: "PT", count: 15)))
        #expect(ids(segments[0].posts) == ["p0", "p1"])
        #expect(segments[0].isPairs)
        guard case .rows(let cards) = segments[1] else {
            Issue.record("the 4:5 post is a card")
            return
        }
        #expect(cards.first?.id == PostID("p2"))
        #expect(ids(segments[2].posts) == ["p3", "p4"])
    }

    /// An odd run pulls the next vertical forward to complete its last pair;
    /// what it jumped over follows, in order.
    @Test func anOddRunPullsItsPartnerForward() {
        let segments = paired(spelled("VTPV" + String(repeating: "PT", count: 15)))
        #expect(ids(segments[0].posts) == ["p0", "p3"])
        #expect(segments[0].isPairs)
        #expect(ids(Array(segments[1].posts.prefix(2))) == ["p1", "p2"])
    }

    /// Three in a row and nothing to pair the third with: a block of two,
    /// and the third is a full-width card.
    @Test func anOddLeftoverWithNoPartnerIsAFullCard() {
        let segments = paired(spelled("VVV" + String(repeating: "T", count: 40)))
        #expect(ids(segments[0].posts) == ["p0", "p1"])
        #expect(segments[0].isPairs)
        guard case .rows(let cards) = segments[1] else {
            Issue.record("the leftover is a card")
            return
        }
        #expect(cards.first?.id == PostID("p2"))
        // And a lone vertical with nothing within reach is a card too.
        let alone = paired(spelled("V" + String(repeating: "T", count: 40)))
        #expect(alone.count == 1)
        #expect(alone.first?.isPairs == false)
    }

    /// The partner must be within the lookahead: one further away is not
    /// pulled across a whole screen of posts.
    @Test func aPartnerBeyondTheLookaheadIsNotPulled() {
        let far = String(repeating: "T", count: MosaicChunkPlanner.lookahead)
        let segments = paired(spelled("V" + far + "V"))
        #expect(segments.first?.isPairs == false, "p0 stays a card")
        #expect(segments.contains { !$0.isPairs && $0.posts.first?.id == PostID("p0") })
    }

    // MARK: - Stability

    /// The same corpus lays out the same list — reload and relaunch alike.
    @Test func theSameCorpusPairsTheSameWay() {
        let posts = mixed(160)
        #expect(paired(posts) == paired(posts))
    }

    /// A page landing extends the list and never re-cuts a block on screen —
    /// walked page by page at several page sizes; the end state is the whole
    /// corpus planned at once.
    @Test func aPageLandingNeverReshufflesPairs() {
        for seed in [1, 2, 3] as [UInt64] {
            let posts = mixed(200, seed: seed)
            for pageSize in [3, 7, 20, 33] {
                var planner = MosaicChunkPlanner()
                var shown: [DiscoverSegment] = []
                var loaded = 0
                while loaded < posts.count {
                    loaded = min(posts.count, loaded + pageSize)
                    let complete = loaded == posts.count
                    let next = planner.segments(for: Array(posts[..<loaded]), isComplete: complete)
                    let change = MosaicChunkPlanner.change(from: shown, to: next)
                    #expect(shown.isEmpty || change != .incompatible,
                            "seed \(seed) page \(pageSize) loaded \(loaded): re-planned")
                    shown = next
                }
                #expect(shown == paired(posts), "seed \(seed) page \(pageSize)")
            }
        }
    }

    /// Chunks leave pairable posts to the runs BY DEFAULT: no chunk holds
    /// one, more blocks form than when chunks take every medium (the old
    /// rule, still a switch), and a landing still only extends — both ways.
    @Test func chunksLeaveVerticalsToPairsByDefaultAndStayStable() {
        let posts = mixed(200, seed: 4)
        #expect(MosaicChunkPlanner().chunksLeavePairableMedia)
        let planned = paired(posts)
        for case .chunk(_, let tiles) in planned {
            #expect(!tiles.contains(where: { VerticalMediaPairing.isEligible($0) }))
        }
        var greedy = MosaicChunkPlanner()
        greedy.chunksLeavePairableMedia = false
        let old = greedy.segments(for: posts, isComplete: true)
        #expect(old.contains { $0.chunk != nil && $0.posts.contains(where: VerticalMediaPairing.isEligible) },
                "the old rule lets chunks take verticals")
        #expect(planned.filter(\.isPairs).count > old.filter(\.isPairs).count)
        for leaves in [true, false] {
            var walker = MosaicChunkPlanner()
            walker.chunksLeavePairableMedia = leaves
            var shown: [DiscoverSegment] = []
            for loaded in stride(from: 7, through: 200, by: 7) + [200] {
                let next = walker.segments(for: Array(posts[..<loaded]), isComplete: loaded == 200)
                #expect(shown.isEmpty || MosaicChunkPlanner.change(from: shown, to: next) != .incompatible,
                        "leaves \(leaves) loaded \(loaded)")
                shown = next
            }
            #expect(shown == (leaves ? planned : old))
        }
    }

    /// An undecided block holds back at most its run and the partner search:
    /// always less than a lookahead plus a block at the very end of what is
    /// loaded — and a run reaching the end of an INCOMPLETE corpus is not
    /// shown until the next page says where it ends.
    @Test func anUndecidedBlockHoldsBackOnlyTheTail() {
        let posts = mixed(300, seed: 9)
        for loaded in stride(from: 4, through: 300, by: 11) {
            var planner = MosaicChunkPlanner()
            let shown = planner.segments(for: Array(posts[..<loaded]), isComplete: false)
                .reduce(0) { $0 + $1.posts.count }
            #expect(loaded - shown < MosaicChunkPlanner.lookahead + VerticalMediaPairing.blockSizes.upperBound,
                    "loaded \(loaded), shown \(shown)")
        }
        var planner = MosaicChunkPlanner()
        #expect(planner.segments(for: spelled("VVV"), isComplete: false).isEmpty)
        #expect(planner.segments(for: spelled("VT"), isComplete: false).isEmpty)
        #expect(planner.segments(for: spelled("VVV"), isComplete: true).first?.isPairs == true)
    }

    /// A block, like a chunk, never grows once shown: a landing that would
    /// add to the old LAST stretch is only an extension when that stretch is
    /// a run of cards.
    @Test func aShownBlockNeverGrows() {
        let block = DiscoverSegment.pairs(spelled("VV"))
        let grown = DiscoverSegment.pairs(spelled("VVVV"))
        #expect(MosaicChunkPlanner.change(from: [block], to: [grown]) == .incompatible)
        let run = DiscoverSegment.rows(spelled("PP"))
        let longer = DiscoverSegment.rows(spelled("PPT"))
        #expect(MosaicChunkPlanner.change(from: [block, run], to: [block, longer])
                == .extended(grownItems: 2..<3, appendedSections: 2..<2))
    }

    // MARK: - Today's planner, frozen

    /// The planner's loop exactly as it was before pairing (develop @ #363),
    /// built from the same public pieces, so
    /// `aCorpusWithoutVerticalMediaIsPlannedAsBeforePairing` compares against
    /// behaviour rather than against itself.
    private static func legacySegments(
        _ corpus: [GalleryPost], isComplete: Bool, planner: inout MosaicChunkPlanner
    ) -> [DiscoverSegment] {
        var placed = [Bool](repeating: false, count: corpus.count)
        var cursor = 0
        var segments: [DiscoverSegment] = []
        var ordinal = 0
        func nextUnplaced() -> Int? {
            while cursor < corpus.count, placed[cursor] { cursor += 1 }
            return cursor < corpus.count ? cursor : nil
        }
        while true {
            let gap = MosaicChunkPlanner.gap(beforeChunk: ordinal)
            var run: [GalleryPost] = []
            while run.count < gap, let index = nextUnplaced() {
                placed[index] = true
                run.append(corpus[index])
            }
            if !run.isEmpty {
                if case .rows(let previous)? = segments.last {
                    segments[segments.count - 1] = .rows(previous + run)
                } else {
                    segments.append(.rows(run))
                }
            }
            guard run.count == gap else { break }
            var media: [Int] = []
            var scanned = 0
            var index = cursor
            while index < corpus.count, scanned < MosaicChunkPlanner.lookahead {
                if !placed[index] {
                    scanned += 1
                    if MosaicChunkPlanner.isTileEligible(corpus[index]) { media.append(index) }
                }
                index += 1
            }
            let isFinal = scanned >= MosaicChunkPlanner.lookahead || isComplete
            let preferred = MosaicChunkPlanner.preferredRows(forChunk: ordinal)
            var chosen: MosaicChunk?
            let wanted = planner.chunk(ordinal: ordinal, rows: preferred)
            if media.count >= wanted.tileCount {
                chosen = wanted
            } else if isFinal {
                for rows in stride(from: preferred - 1, through: MosaicChunkPlanner.rowRange.lowerBound, by: -1) {
                    let smaller = planner.chunk(ordinal: ordinal, rows: rows)
                    if media.count >= smaller.tileCount {
                        chosen = smaller
                        break
                    }
                }
            } else {
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
}

// MARK: - The block's geometry

/// A block's cards: two to a row, half the list's width less the gutter, at
/// the Following card's 3:4 — one fixed size, so a row is one line.
@MainActor
struct PairedCardSizeTests {
    @Test func aPairedCardIsHalfTheListAtThreeByFour() {
        for screen in [375.0, 402.0, 440.0] as [CGFloat] {
            let size = DiscoverListLayout.pairCardSize(containerWidth: screen)
            let expected = (screen - PostGridListLayout.sideMargin * 2 - DiscoverListLayout.pairGutter) / 2
            #expect(abs(size.width - expected) < 0.01, "\(screen): \(size)")
            #expect(abs(size.height - (size.width * 4 / 3).rounded()) < 0.01)
            #expect(size.height == size.height.rounded(), "whole points")
        }
    }
}
