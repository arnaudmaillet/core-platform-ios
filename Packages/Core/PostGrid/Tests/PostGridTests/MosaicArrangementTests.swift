import CoreModels
import Foundation
import Testing
@testable import PostGrid

struct MosaicArrangementTests {
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

    // MARK: - Slot shapes

    /// Half the pattern is square, which is the whole reason arrangement is
    /// needed: videos land on all eight slots equally without it.
    @Test func thePatternIsHalfSquare() {
        let shapes = (0..<PostGridMosaic.patternLength).map(PostGridMosaic.slotShape(at:))
        #expect(shapes.filter { $0 == .square }.count == 4)
        #expect(shapes.filter { $0 == .portrait }.count == 2)
        #expect(shapes.filter { $0 == .landscape }.count == 2)
    }

    @Test func slotShapeRepeatsEveryPattern() {
        for index in 0..<PostGridMosaic.patternLength {
            #expect(PostGridMosaic.slotShape(at: index) == PostGridMosaic.slotShape(at: index + 8))
            #expect(PostGridMosaic.slotShape(at: index) == PostGridMosaic.slotShape(at: index + 800))
        }
    }

    @Test func onlySquaresAreUnsuitedToMotion() {
        #expect(PostGridMosaic.SlotShape.portrait.suitsMotion)
        #expect(PostGridMosaic.SlotShape.landscape.suitsMotion)
        #expect(!PostGridMosaic.SlotShape.square.suitsMotion)
    }

    // MARK: - Arrangement

    /// The headline: with enough stills to fill the squares, every video ends
    /// up in a brick that autoplays.
    @Test func videosTakeTheNonSquareBricks() {
        let input = [
            photo("p1"), photo("p2"), video("v1"), photo("p3"),
            video("v2"), photo("p4"), photo("p5"), video("v3")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        for (offset, post) in out.enumerated() where post.autoplaysInGrid {
            #expect(PostGridMosaic.slotShape(at: offset).suitsMotion,
                    "video landed in a square at slot \(offset)")
        }
    }

    @Test func squareBricksReceiveStills() {
        let input = [
            photo("p1"), photo("p2"), video("v1"), photo("p3"),
            video("v2"), photo("p4"), photo("p5"), video("v3")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        for (offset, post) in out.enumerated() where !PostGridMosaic.slotShape(at: offset).suitsMotion {
            #expect(!post.autoplaysInGrid, "square slot \(offset) got a video")
        }
    }

    /// Placement keys off the ABSOLUTE slot, so a page landing mid-list is
    /// arranged against the bricks it will actually occupy.
    @Test func arrangementRespectsTheAbsoluteStartIndex() {
        // Slots 2..5 are all squares, so a block starting there has nowhere
        // suitable and must leave order alone rather than shuffle pointlessly.
        let input = [video("v1"), photo("p1"), photo("p2"), video("v2")]
        #expect(ids(PostGridMosaic.arrangedForMotion(input, startingAt: 2)) == ["v1", "p1", "p2", "v2"])
    }

    // MARK: - Invariants

    @Test func nothingIsDroppedOrDuplicated() {
        let input = (0..<20).map { $0 % 3 == 0 ? video("v\($0)") : photo("p\($0)") }
        for start in 0..<8 {
            let out = PostGridMosaic.arrangedForMotion(input, startingAt: start)
            #expect(out.count == input.count)
            #expect(Set(ids(out)) == Set(ids(input)))
        }
    }

    /// Stills keep their order outright. Motion does NOT, and that is the
    /// deliberate cost of shape matching: portrait bricks are filled from the
    /// portrait videos first, so a later portrait clip can precede an earlier
    /// landscape one in reading order. What survives is order *within a shape*
    /// — which is what recency means once the mosaic is permuting anyway.
    @Test func relativeOrderIsPreservedWithinEachShape() {
        let input = [
            video("v1"), photo("p1"), video("v2"), photo("p2"),
            video("v3"), photo("p3"), video("v4"), photo("p4")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        #expect(ids(out.filter { !$0.autoplaysInGrid }) == ["p1", "p2", "p3", "p4"])
        // All four videos share one shape here, so they must stay in order
        // relative to each other within the bricks of that shape.
        let portraitSlots = (0..<8).filter { PostGridMosaic.slotShape(at: $0) == .portrait }
        #expect(ids(portraitSlots.map { out[$0] }) == ["v1", "v2"])
        #expect(Set(ids(out)) == Set(ids(input)))
    }

    /// Mixed shapes: each shape's own sequence is respected.
    @Test func eachShapeKeepsItsOwnSequence() {
        let input = [
            video("tall1", aspect: 0.5625), video("wide1", aspect: 1.78),
            video("tall2", aspect: 0.5625), video("wide2", aspect: 1.78),
            photo("p1"), photo("p2"), photo("p3"), photo("p4")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        let portraitSlots = (0..<8).filter { PostGridMosaic.slotShape(at: $0) == .portrait }
        let landscapeSlots = (0..<8).filter { PostGridMosaic.slotShape(at: $0) == .landscape }
        #expect(ids(portraitSlots.map { out[$0] }) == ["tall1", "tall2"])
        #expect(ids(landscapeSlots.map { out[$0] }) == ["wide1", "wide2"])
    }

    /// More videos than motion bricks: the surplus has to go somewhere, and
    /// squares are it. Nothing may be lost.
    @Test func surplusVideosSpillIntoSquares() {
        let input = (0..<8).map { video("v\($0)") }
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        #expect(out.count == 8)
        #expect(Set(ids(out)) == Set(ids(input)))
    }

    @Test func anAllStillListIsUntouched() {
        let input = (0..<8).map { photo("p\($0)") }
        #expect(ids(PostGridMosaic.arrangedForMotion(input, startingAt: 0)) == ids(input))
    }

    @Test func anEmptyListIsUntouched() {
        #expect(PostGridMosaic.arrangedForMotion([], startingAt: 0).isEmpty)
    }

    /// Square-media videos never autoplay, so the grid treats them as stills
    /// and they compete for the square bricks — which is also where they render
    /// without being cropped.
    ///
    /// Note what is NOT claimed: with one autoplaying post and four motion
    /// bricks, three of those bricks must hold stills. The invariant is about
    /// where *motion* goes, not about keeping stills out of large slots.
    @Test func squareMediaVideosAreTreatedAsStills() {
        let input = [
            video("sq1", aspect: 1), photo("p1"), video("tall", aspect: 0.5), photo("p2"),
            photo("p3"), photo("p4"), photo("p5"), video("sq2", aspect: 1)
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)

        // The one autoplaying post is in a brick that suits motion...
        let motionSlots = (0..<8).filter { PostGridMosaic.slotShape(at: $0).suitsMotion }
        #expect(motionSlots.contains { out[$0].id.rawValue == "tall" })
        // ...and no square brick holds anything that would move.
        for slot in 0..<8 where !PostGridMosaic.slotShape(at: slot).suitsMotion {
            #expect(!out[slot].autoplaysInGrid)
        }
    }
}

// MARK: - Shape matching

extension MosaicArrangementTests {
    /// The reason shape matching exists: aspect-fill crops by the difference
    /// between media and container, so a 9:16 clip in a 2:1 brick is a hard
    /// crop that the zoom then has to unwind.
    @Test func verticalVideoPrefersPortraitBricks() {
        let input = [
            photo("p1"), video("v9x16", aspect: 1080.0 / 1920), photo("p2"), photo("p3"),
            photo("p4"), photo("p5"), photo("p6"), photo("p7")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        let slot = out.firstIndex { $0.id.rawValue == "v9x16" }
        #expect(slot != nil)
        #expect(PostGridMosaic.slotShape(at: slot!) == .portrait)
    }

    @Test func landscapeVideoPrefersLandscapeBricks() {
        let input = [
            photo("p1"), video("v16x9", aspect: 1920.0 / 1080), photo("p2"), photo("p3"),
            photo("p4"), photo("p5"), photo("p6"), photo("p7")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        let slot = out.firstIndex { $0.id.rawValue == "v16x9" }
        #expect(slot != nil)
        #expect(PostGridMosaic.slotShape(at: slot!) == .landscape)
    }

    /// A mismatched motion brick still beats a square: more videos than
    /// matching bricks must not push any of them into a still slot.
    @Test func surplusVerticalVideosStillAvoidSquares() {
        let input = (0..<4).map { video("v\($0)", aspect: 0.5625) }
            + (0..<4).map { photo("p\($0)") }
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        for slot in 0..<8 where !PostGridMosaic.slotShape(at: slot).suitsMotion {
            #expect(!out[slot].autoplaysInGrid, "square brick \(slot) got a video")
        }
    }
}
