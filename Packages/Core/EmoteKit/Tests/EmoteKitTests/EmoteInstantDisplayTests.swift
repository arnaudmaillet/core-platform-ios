import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The first display, made instant where it can be (#1504): a 64 px seed
/// serves the 48 px box, a visible label's bake does not wait out the bake
/// delay, and the emotes shown last are warmed into memory at launch.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteInstantDisplayTests {
    private let catalog = EmoteCatalog.shared

    /// ⚠️ A FOOTNOTE CAPTION'S BUCKET IS SEEDED (#1504): For You's card
    /// caption draws at 48 px, which used to miss the 64 px seeds and bake.
    @Test func the48BucketReadsTheSeedAndBakesNothing() async throws {
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        let joy = try #require(catalog.emote(id: "noto:1f602"))
        #expect(engine.isLocal(joy, pixelSide: 48, motion: .loop), "the 48 px box is not a read away")
        #expect(await engine.art(for: joy, pixelSide: 48) != nil)
        #expect(engine.stats.seedHits == 1)
        #expect(engine.stats.bakesStarted == 0)
    }

    /// ⚠️ AN EMOTE ON SCREEN DOES NOT WAIT OUT THE BAKE DELAY (#1504): the
    /// delay spares work for a place flicked past, and a label only asks for
    /// what is visible. A request that is not urgent still waits.
    @Test func anUrgentRequestSkipsTheBakeDelay() async throws {
        let asked = Box()
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in
            asked.count += 1
            return nil
        })
        // ⚠️ A DELAY NO RUN OUTLASTS (#1948). At 30 s, a starved CI runner
        // took 59 s over this test: the lazy request, kept alive to the end,
        // baked too, and `asked` counted 2. An hour keeps it waiting however
        // slow the run, so the count below is the urgent request's alone.
        engine.bakeDelay = .seconds(3600)
        let cold = try #require(catalog.emote(id: "noto:1f976"))

        let lazy = engine.requestArt(for: cold, pixelSide: 96, motion: .loop) { _ in }
        defer { lazy.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked.count == 0, "a request that is not urgent skipped the delay")

        var answered = false
        let urgent = engine.requestArt(for: cold, pixelSide: 128, motion: .loop, urgent: true) { _ in answered = true }
        defer { urgent.cancel() }
        for _ in 0..<500 where !answered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(answered, "an urgent request waited out the bake delay")
        #expect(asked.count == 1)
    }

    /// The emotes shown last are kept across launches — written when the set
    /// changes, capped — and a launch makes them resident before anything
    /// asks, from a seed or the disk, with no bake.
    @Test func theHotSetIsWarmedIntoMemoryAtLaunch() async throws {
        let defaults = try #require(UserDefaults(suiteName: "emote-hot-set-\(UUID().uuidString)"))
        let joy = try #require(catalog.emote(id: "noto:1f602"))

        let before = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        before.hotSet = EmoteHotSet(defaults: defaults)
        before.noteShown(joy, pixelSide: 64, motion: .loop)
        #expect(defaults.stringArray(forKey: EmoteHotSet.key) == ["noto:1f602|64|0"])

        // The next launch.
        let after = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        after.hotSet = EmoteHotSet(defaults: defaults)
        #expect(after.cachedArt(for: joy, pixelSide: 64, motion: .loop) == nil, "the premise: a cold engine")
        await after.warmHotSet()
        #expect(after.cachedArt(for: joy, pixelSide: 64, motion: .loop) != nil, "the hot set was not warmed")
        #expect(after.stats.bakesStarted == 0)
    }

    @Test func theHotSetIsCappedAndWrittenOnlyWhenItChanges() throws {
        let defaults = try #require(UserDefaults(suiteName: "emote-hot-set-\(UUID().uuidString)"))
        let set = EmoteHotSet(defaults: defaults)
        for index in 0..<(EmoteHotSet.capacity + 4) {
            set.note("e\(index)", pixelSide: 64, still: false)
        }
        #expect(set.entries.count == EmoteHotSet.capacity)
        #expect(set.entries.first?.id == "e\(EmoteHotSet.capacity + 3)", "the newest is not first")
        let written = defaults.stringArray(forKey: EmoteHotSet.key)
        // Shown again: to the front in memory, no write.
        defaults.set(["sentinel"], forKey: EmoteHotSet.key)
        set.note("e\(EmoteHotSet.capacity + 1)", pixelSide: 64, still: false)
        #expect(defaults.stringArray(forKey: EmoteHotSet.key) == ["sentinel"], "a re-view rewrote the set")
        #expect(written?.count == EmoteHotSet.capacity)
        #expect(EmoteHotSet(defaults: UserDefaults(suiteName: "x-\(UUID().uuidString)")!).entries.isEmpty)
    }
}

@MainActor
private final class Box {
    var count = 0
}
