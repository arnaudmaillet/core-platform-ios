import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The bundled seed set (#971): the most used emotes ship baked, so a cold
/// start shows their art with nothing but the bundle.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteSeedTests {
    private let catalog = EmoteCatalog.shared

    /// THE CRITERION: an install with an empty Caches folder (first launch, or
    /// iOS purged it) and no way to bake — the animation source answers
    /// nothing — still shows the seeded emote's ART, from the bundle alone.
    @Test func aColdStartShowsSeededArtWithNothingButTheBundle() async throws {
        let asked = Counter()
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in
            asked.count += 1
            return nil
        })
        let joy = try #require(catalog.emote(id: "noto:1f602"))
        let art = try #require(await engine.art(for: joy, pixelSide: EmoteSeeds.side))
        #expect(art.frameCount > 20, "a moving loop, not a still")
        #expect(engine.stats.seedHits == 1)
        #expect(engine.stats.bakesStarted == 0)
        #expect(asked.count == 0, "the seed answered before any source was asked")
        // …and it is resident now, for the next label's same layout pass.
        #expect(engine.cachedArt(for: joy, pixelSide: EmoteSeeds.side, motion: .loop) == art)
    }

    /// The same cold start through a label: its emote gets a player at once
    /// the seed lands, with no bake.
    @Test func aColdLabelPlaysASeededEmote() async throws {
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        defer { window.isHidden = true }
        let label = EmoteLabel()
        label.engine = engine
        // 20 pt at the test host's scale draws at the seed's bucket on a 3x
        // screen; force the bucket rather than trust the host's scale.
        let side = EmoteEngine.pixelSide(forPoints: 20.3, scale: 3)
        try #require(side == EmoteSeeds.side)
        label.font = UIFont.systemFont(ofSize: 17)
        label.setEmoteText("so good 🔥")
        window.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 320, height: 40)
        label.layoutIfNeeded()
        let fire = try #require(catalog.emote(id: "noto:1f525"))
        let bucket = EmoteEngine.pixelSide(forPoints: label.emoteFrames.first?.width ?? 0, scale: window.screen.scale)
        if bucket == EmoteSeeds.side {
            try #require(await settle { label.showingEmoteCount == 1 }, "the seeded emote never played")
        }
        // Whatever bucket the host's scale picked, the seed itself loads cold.
        #expect(await engine.art(for: fire, pixelSide: EmoteSeeds.side) != nil)
        #expect(engine.stats.bakesStarted == 0)
        #expect(engine.stats.seedHits >= 1)
    }

    /// Every seed ships, decodes, and is cut exactly as the bake would cut it
    /// TODAY. A change to `EmoteBakePlan` fails here until the set is
    /// regenerated (`EmoteSeedGenerator`).
    @Test(arguments: EmoteSeeds.ids)
    func everySeedShipsAndMatchesTheBakePlan(_ id: String) async throws {
        let emote = try #require(catalog.emote(id: id), "\(id) left the catalogue")
        let data = try #require(EmoteSeeds.bundled.data(for: emote, pixelSide: EmoteSeeds.side, motion: .loop))
        let (meta, _) = try #require(EmoteSheetFile.metadata(in: data))
        let animation = try #require(await EmoteEngine.bundledAnimation(for: emote))
        let plan = EmoteBakePlan.make(seconds: animation.duration, side: EmoteSeeds.side)
        #expect(meta.frameCount == plan.frameCount)
        #expect(meta.columns == plan.columns)
        #expect(meta.gutter == plan.gutter)
        #expect(abs(meta.frameDuration - plan.frameDuration) < 1e-9)
        let art = try #require(EmoteSheetFile.art(from: data))
        guard case .sheet(let sheet) = art else {
            Issue.record("a seed is a sheet")
            return
        }
        let image = try #require(sheet.sheet.cgImage)
        #expect(image.width == plan.pixelWidth)
        #expect(image.height == plan.pixelHeight)
        #expect(TestBitmap.cell(image, plan: plan, frame: 0).inked > 64 * 64 / 8, "\(id)'s first frame is blank")
    }

    /// Only the seeded buckets — 64, and 48 drawn from it (#1504) — and the
    /// loop are seeded; anything else bakes.
    @Test func onlyTheSeededBucketAndTheLoopAreSeeded() throws {
        let joy = try #require(catalog.emote(id: "noto:1f602"))
        let seeds = EmoteSeeds.bundled
        #expect(seeds.covers(joy, pixelSide: 64, motion: .loop))
        #expect(seeds.covers(joy, pixelSide: 48, motion: .loop), "a footnote caption's bucket missed the seeds")
        #expect(!seeds.covers(joy, pixelSide: 96, motion: .loop))
        #expect(!seeds.covers(joy, pixelSide: 64, motion: .still))
        let unseeded = try #require(catalog.emote(id: "noto:1f976"))
        #expect(!seeds.covers(unseeded, pixelSide: 64, motion: .loop))
        #expect(seeds.data(for: unseeded, pixelSide: 64, motion: .loop) == nil)
    }

    /// About twenty, and small in the bundle.
    @Test func theSeedSetIsSmall() throws {
        #expect((18...24).contains(EmoteSeeds.ids.count))
        #expect(Set(EmoteSeeds.ids).count == EmoteSeeds.ids.count)
        var total = 0
        for id in EmoteSeeds.ids {
            let emote = try #require(catalog.emote(id: id))
            total += try #require(EmoteSeeds.bundled.data(for: emote, pixelSide: EmoteSeeds.side, motion: .loop)).count
        }
        #expect(total < EmoteSeedTests.bundleBudget, "the seed set is \(total) bytes")
    }

    /// The bundle budget for the whole set: 1.8 MB measured, lossless WebP.
    static let bundleBudget = 2_000_000

    /// The set is the manifest's head: Unicode's frequency ranking.
    @Test func theSeedsAreTheMostUsedEmotes() {
        let head = catalog.all.filter(\.isUnicodeEmoji).prefix(EmoteSeeds.ids.count).map(\.id)
        #expect(Array(head) == EmoteSeeds.ids)
    }
}

/// Regenerates the bundled seed set (`EmoteSeeds`) with the engine's own bake.
/// Off unless asked for; then compress the PNGs it writes:
///
///     cd Packages/Core/EmoteKit
///     TEST_RUNNER_EMOTE_SEED_OUT="$PWD/Sources/EmoteKit/Resources/Seeds" \
///       xcodebuild test -scheme EmoteKit -destination "platform=iOS Simulator,name=…" \
///       -only-testing:EmoteKitTests/EmoteSeedGenerator
///     ../../../Scripts/compress-emote-seeds.py
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteSeedGenerator {
    nonisolated static let output = ProcessInfo.processInfo.environment["EMOTE_SEED_OUT"]

    @Test(.enabled(if: EmoteSeedGenerator.output != nil))
    func writeTheSeedSet() async throws {
        let folder = URL(fileURLWithPath: try #require(Self.output), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = EmoteEngine(diskCache: nil)
        engine.bakeDelay = .zero
        for id in EmoteSeeds.ids {
            let emote = try #require(EmoteCatalog.shared.emote(id: id))
            let art = try #require(await engine.art(for: emote, pixelSide: EmoteSeeds.side), "\(id) did not bake")
            guard case .sheet(let sheet) = art else {
                Issue.record("\(id) baked to something other than a sheet")
                continue
            }
            let data = try #require(EmoteSheetFile.data(for: sheet, gutter: EmoteBakePlan.defaultGutter))
            let file = folder.appendingPathComponent(EmoteSeeds.resourceName(emoteID: id))
                .appendingPathExtension(EmoteSeeds.fileExtension)
            try data.write(to: file, options: .atomic)
        }
    }
}

@MainActor
private final class Counter {
    var count = 0
}
