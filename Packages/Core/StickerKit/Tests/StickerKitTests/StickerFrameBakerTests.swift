import CoreGraphics
import Foundation
import Testing
@testable import StickerKit

/// Baking: 30 frames a second of real, moving, compressed pictures, made once.
@MainActor
struct StickerFrameBakerTests {
    private func sticker(_ id: String) throws -> Sticker {
        try #require(StickerCatalog.sticker(id: id))
    }

    /// Two lengths, so a count that only happens to be 90 cannot pass: Idea
    /// lasts 3s (180 frames at 60fps), Temperature 2.267s (136 frames).
    @Test func aStripHas90FramesAt30fps() async throws {
        let baker = StickerFrameBaker()
        let idea = try #require(await baker.strip(for: sticker("Idea"), side: 48))
        #expect(idea.frames.count == 90)
        #expect(idea.framesPerSecond == 30)
        #expect(abs(idea.seconds - 3) < 0.001)
        #expect(idea.side == 48)

        let temperature = try #require(await baker.strip(for: sticker("Temperature"), side: 48))
        #expect(temperature.frames.count == 68)
        #expect(abs(temperature.seconds - 136.0 / 60) < 0.001)
    }

    /// 179 frames at 60fps last 2.983s: the 90th baked frame is needed to cover
    /// the last 17ms, and an exact 3s must not grow a 91st.
    @Test func theFrameCountCoversAPartialLastFrame() {
        #expect(StickerFrameBaker.frameCount(forSeconds: 179.0 / 60) == 90)
        #expect(StickerFrameBaker.frameCount(forSeconds: 180.0 / 60) == 90)
        #expect(StickerFrameBaker.frameCount(forSeconds: 139.0 / 60) == 70)
        #expect(StickerFrameBaker.frameCount(forSeconds: 0.001) == 1)
    }

    @Test func framesDiffer() async throws {
        let strip = try #require(await StickerFrameBaker().strip(for: sticker("Idea"), side: 48))
        let first = try #require(strip.frame(atSeconds: 0))
        #expect(TestPictures.inkedPixels(in: first) > 48 * 48 / 10)

        let distinct = Set(strip.frames.indices.map { index in
            TestPictures.pixels(of: strip.frame(atSeconds: Double(index) / 30)!)
                .map { "\($0.r),\($0.g),\($0.b),\($0.a)" }
        })
        #expect(distinct.count > strip.frames.count / 3, "only \(distinct.count) distinct pictures")
    }

    /// A raw loop at 256px is 256 × 256 × 4 × 90 bytes, about 23.6 MB.
    @Test func stripsAreCompressed() async throws {
        let strip = try #require(await StickerFrameBaker().strip(for: sticker("Money"), side: 256))
        let raw = 256 * 256 * 4 * strip.frames.count
        #expect(strip.byteCount < raw / 4, "\(strip.byteCount) bytes against \(raw) raw")
        #expect(strip.byteCount < 6_000_000)
        #expect(TestPictures.inkedPixels(in: try #require(strip.frame(atSeconds: 1))) > 256 * 256 / 10)
    }

    @Test func theBakerCaches() async throws {
        let baker = StickerFrameBaker()
        let noEntry = try sticker("NoEntry")
        async let first = baker.strip(for: noEntry, side: 32)
        async let second = baker.strip(for: noEntry, side: 32)
        let pair = await (first, second)
        let strip = try #require(pair.0)
        #expect(pair.1 === strip)
        #expect(baker.bakes == 1)

        #expect(await baker.strip(for: noEntry, side: 32) === strip)
        #expect(baker.bakes == 1)

        let bigger = await baker.strip(for: noEntry, side: 40)
        #expect(bigger !== strip)
        #expect(baker.bakes == 2)
    }

    /// The main actor runs between frames, not only before and after a bake:
    /// a watcher on it sees the bake part-way through several times.
    @Test func theMainActorRunsBetweenFrames() async throws {
        let baker = StickerFrameBaker()
        let watcher = Watcher()
        let watching = Task { @MainActor in
            while !watcher.done {
                watcher.seen.insert(baker.framesDrawn)
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let strip = try #require(await baker.strip(for: sticker("Idea"), side: 64))
        watcher.done = true
        await watching.value
        let partWay = watcher.seen.filter { $0 > 0 && $0 < strip.frames.count }
        #expect(partWay.count >= 3, "seen at \(watcher.seen.sorted())")
    }

    @MainActor
    private final class Watcher {
        var seen = Set<Int>()
        var done = false
    }

    @Test func aStillIsTheFirstFrameAlone() async throws {
        let baker = StickerFrameBaker()
        let still = try #require(await baker.strip(for: sticker("NoEntry"), side: 40, motion: .still))
        #expect(still.frames.count == 1)
        #expect(still.seconds == 0)
        let loop = try #require(await baker.strip(for: sticker("NoEntry"), side: 40))
        #expect(still.frames[0] == loop.frames[0])
        #expect(still.frame(atSeconds: 7.3) != nil)
    }

    @Test func aSideIsClampedToTheExportSide() async throws {
        let strip = try #require(await StickerFrameBaker().strip(for: sticker("NoEntry"), side: 4096, motion: .still))
        #expect(strip.side == StickerFrameBaker.exportSide)
        #expect(strip.frame(atSeconds: 0)?.width == StickerFrameBaker.exportSide)
    }

    /// The artwork a publish hands the exporter: known stickers only, each
    /// drawing real ink at the side asked.
    @Test func artworkCarriesTheNamedStickers() async throws {
        let artwork = await StickerFrameBaker().artwork(for: ["Book", "Unknown", "Book"], side: 32)
        #expect(Set(artwork.strips.keys) == ["Book"])
        let frame = try #require(artwork.sticker("Book", atSeconds: 1.2, side: 32))
        #expect(frame.width == 32)
        #expect(TestPictures.inkedPixels(in: frame) > 32 * 32 / 10)
        #expect(artwork.sticker("Unknown", atSeconds: 0, side: 32) == nil)
    }
}
