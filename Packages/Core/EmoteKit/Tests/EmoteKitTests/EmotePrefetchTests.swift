import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The emotes of text about to be shown are warmed before it is (#1504).
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmotePrefetchTests {
    /// Art that never arrives until the gate opens, so a request stays
    /// pending for the test to read.
    private func gatedEngine(_ gate: ArtGate) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return EmoteLabelTests.syntheticArt(side: side)
        }
        return engine
    }

    @Test func itAsksForTheTextsEmotesAndLetsGoOfWhatLeaves() throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        let prefetch = EmotePrefetch(engine: engine)

        prefetch.warm(["Golden hour 🔥", "no emote here", "🔥 again 😂"], pixelSide: 64)
        let keys = prefetch.pendingKeys
        #expect(keys.count == 2, "not one request per distinct emote: \(keys)")
        #expect(keys.allSatisfy { $0.contains("|64|") })

        prefetch.warm(["just 😂"], pixelSide: 64)
        #expect(prefetch.pendingKeys.count == 1, "a request no longer wanted stayed: \(prefetch.pendingKeys)")

        prefetch.cancelAll()
        #expect(prefetch.pendingKeys.isEmpty)
        withExtendedLifetime(engine) {}
    }

    /// Resident art is not asked for again.
    @Test func residentArtIsNotAskedFor() throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        let fire = try #require(engine.catalog.emote(id: "noto:1f525"))
        let motion: EmoteEngine.Motion = EmoteMotion.policy == .still ? .still : .loop
        engine.insert(EmoteLabelTests.syntheticArt(side: 64), for: fire, pixelSide: 64, motion: motion)
        let prefetch = EmotePrefetch(engine: engine)
        prefetch.warm(["🔥"], pixelSide: 64)
        #expect(prefetch.pendingKeys.isEmpty)
        withExtendedLifetime(engine) {}
    }
}
