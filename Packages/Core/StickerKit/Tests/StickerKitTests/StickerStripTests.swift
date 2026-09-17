import CoreGraphics
import MediaPlayback
import Testing
@testable import StickerKit

/// Reading a strip: the loop's clock, the one-frame cache, and the artwork a
/// renderer asks — all on synthetic strips whose frames are known colours.
struct StickerStripTests {
    private static let red: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)
    private static let green: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)
    private static let blue: (CGFloat, CGFloat, CGFloat) = (0, 0, 1)

    @Test func theLoopWrapsBothWays() {
        let strip = TestPictures.strip(Array(repeating: Self.red, count: 90), framesPerSecond: 30)
        #expect(strip.frameIndex(atSeconds: 0) == 0)
        #expect(strip.frameIndex(atSeconds: 1) == 30)
        #expect(strip.frameIndex(atSeconds: 2.999) == 89)
        #expect(strip.frameIndex(atSeconds: 3.5) == 15)
        #expect(strip.frameIndex(atSeconds: 7) == 30)
        #expect(strip.frameIndex(atSeconds: -0.5) == 75)
        #expect(strip.frameIndex(atSeconds: .nan) == 0)
    }

    @Test func aFrameIsChosenByTime() throws {
        let strip = TestPictures.strip([Self.red, Self.green, Self.blue])
        #expect(TestPictures.centre(of: try #require(strip.frame(atSeconds: 0.5))) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestPictures.centre(of: try #require(strip.frame(atSeconds: 1.5))) == .init(r: 0, g: 255, b: 0, a: 255))
        #expect(TestPictures.centre(of: try #require(strip.frame(atSeconds: 5.2))) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    /// A 30fps loop under a 60fps film asks for each frame twice in a row.
    @Test func aRepeatedFrameIsDecodedOnce() throws {
        let strip = TestPictures.strip([Self.red, Self.green])
        let first = try #require(strip.frame(atSeconds: 0.1))
        let again = try #require(strip.frame(atSeconds: 0.9))
        #expect(again === first)
        #expect(strip.decodes == 1)

        let next = try #require(strip.frame(atSeconds: 1.1))
        #expect(strip.decodes == 2)
        #expect(TestPictures.centre(of: next) == .init(r: 0, g: 255, b: 0, a: 255))

        // Only ONE decoded frame is held: going back decodes again.
        _ = strip.frame(atSeconds: 0.2)
        #expect(strip.decodes == 3)
    }

    /// `OverlayArtwork` promises `side` pixels square; a strip baked at 16 is
    /// resampled for a renderer that wants 40 — at two sides, so a size that
    /// merely matches one request cannot pass.
    @Test func theArtworkHandsTheSideAskedFor() throws {
        let artwork: any OverlayArtwork = StickerArtwork(strips: ["dot": TestPictures.strip([Self.red, Self.blue])])
        let big = try #require(artwork.sticker("dot", atSeconds: 1.5, side: 40))
        #expect(big.width == 40 && big.height == 40)
        #expect(TestPictures.centre(of: big) == .init(r: 0, g: 0, b: 255, a: 255))

        let small = try #require(artwork.sticker("dot", atSeconds: 0.5, side: 10))
        #expect(small.width == 10 && small.height == 10)
        #expect(TestPictures.centre(of: small) == .init(r: 255, g: 0, b: 0, a: 255))

        let baked = try #require(artwork.sticker("dot", atSeconds: 2.5, side: 16))
        #expect(baked.width == 16)
        #expect(TestPictures.centre(of: baked) == .init(r: 255, g: 0, b: 0, a: 255))

        #expect(artwork.sticker("other", atSeconds: 0, side: 16) == nil)
    }

    /// The artwork is read from a compositor's queue, many threads at once.
    @Test func readersOnManyThreadsAgree() async throws {
        let strip = TestPictures.strip([Self.red, Self.green, Self.blue])
        let artwork = StickerArtwork(strips: ["dot": strip])
        let centres = await withTaskGroup(of: (Int, TestPictures.RGBA?).self) { group in
            for index in 0..<60 {
                group.addTask {
                    let image = artwork.sticker("dot", atSeconds: Double(index % 3) + 0.5, side: 16)
                    return (index % 3, image.map(TestPictures.centre(of:)))
                }
            }
            return await group.reduce(into: [(Int, TestPictures.RGBA?)]()) { $0.append($1) }
        }
        let expected: [TestPictures.RGBA] = [
            .init(r: 255, g: 0, b: 0, a: 255), .init(r: 0, g: 255, b: 0, a: 255), .init(r: 0, g: 0, b: 255, a: 255)
        ]
        #expect(centres.count == 60)
        for (slot, centre) in centres {
            #expect(centre == expected[slot])
        }
    }
}
