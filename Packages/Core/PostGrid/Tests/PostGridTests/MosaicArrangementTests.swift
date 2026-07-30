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

    @Test func relativeOrderIsPreservedWithinEachGroup() {
        let input = [
            video("v1"), photo("p1"), video("v2"), photo("p2"),
            video("v3"), photo("p3"), video("v4"), photo("p4")
        ]
        let out = PostGridMosaic.arrangedForMotion(input, startingAt: 0)
        let videoOrder = ids(out.filter(\.autoplaysInGrid))
        let stillOrder = ids(out.filter { !$0.autoplaysInGrid })
        #expect(videoOrder == ["v1", "v2", "v3", "v4"])
        #expect(stillOrder == ["p1", "p2", "p3", "p4"])
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
