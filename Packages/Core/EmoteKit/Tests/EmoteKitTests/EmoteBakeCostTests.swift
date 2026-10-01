import Foundation
import Testing
@testable import EmoteKit

/// What a bake costs the MAIN thread, measured the way a user feels it: how
/// long the main run loop is busy, turn by turn, while a cold emote bakes.
///
/// ⚠️ ALONE (`.measuresMainThread`): the meter books every main-thread turn
/// to the bake, including the turns of the suites running beside it — see
/// `MainThreadAccess`.
@MainActor
@Suite(.serialized, .measuresMainThread)
struct EmoteBakeCostTests {
    /// The numbers for the record: 🥶 (Noto's most expensive frames), 😂 and
    /// 🔥, cold, at the text bucket. Prints, and asserts only a bound ~10×
    /// looser than what is measured.
    @Test func mainThreadCostOfAColdBakeForTheRecord() async throws {
        var lines: [String] = []
        let idle = MainThreadBusyMeter()
        idle.start()
        try await Task.sleep(for: .milliseconds(500))
        let idleReport = idle.stop()
        lines.append("idle 500ms: \(idleReport)")
        // ⚠️ THE MACHINE'S OWN BACKGROUND, measured first and subtracted. On a
        // saturated CI runner the process is descheduled mid-turn and the meter
        // books that as main-thread work: an IDLE main thread read as busy, and
        // a bake that costs ~10 ms of main here (iOS 27 and 26.5 simulators)
        // read 688 and 3350 ms there. The share of an idle second the meter
        // calls busy is charged to the bake's wall time before judging it.
        let backgroundShare = idleReport.wallMS > 0 ? min(idleReport.busyMS / idleReport.wallMS, 1) : 0
        for id in ["noto:1f976", "noto:1f602", "noto:1f525"] {
            let engine = EmoteEngine(diskCache: nil)
            engine.bakeDelay = .zero
            let emote = try #require(engine.catalog.emote(id: id))
            let meter = MainThreadBusyMeter()
            meter.start()
            let art = try #require(await engine.art(for: emote, pixelSide: 64))
            // Work a bake leaves behind (a deferred commit) still counts.
            try await Task.sleep(for: .milliseconds(300))
            let report = meter.stop()
            // Before the bake moved off the main thread the main thread was
            // busy for MORE than the drawing (deferred redraws on top);
            // after, for about 2% of it. A quarter is slack for a slow CI.
            let background = backgroundShare * report.wallMS
            #expect(report.busyMS < engine.stats.lastBakeDrawingMS / 4 + 20 + background,
                    "\(emote.glyph): \(report) background=\(Int(background))ms")
            lines.append(String(
                format: "%@ frames=%d %@ mainPerFrame=%.1fms bakeDrawing=%.0fms (%.1fms/frame)",
                emote.glyph, art.frameCount, report.description, report.busyMS / Double(art.frameCount),
                engine.stats.lastBakeDrawingMS, engine.stats.lastBakeDrawingMS / Double(art.frameCount)
            ))
        }
        print("[emote-main-cost]\n" + lines.joined(separator: "\n"))
    }
}
