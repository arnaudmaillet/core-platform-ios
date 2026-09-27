import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The schedule a leading renderer keeps (`LeadingFrameQueue`): how far ahead
/// it pulls, when each frame it holds is due, and which one a refresh shows.
struct LeadingFrameQueueTests {
    private static func buffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    /// One refresh ahead at 60 Hz; two on a ProMotion refresh, so the companion
    /// never has less than ~16 ms to get ready.
    @Test func theLeadIsARefreshOrTwoShortOnes() {
        #expect(LeadingFrameQueue.lead(refreshInterval: 1.0 / 60) == 1.0 / 60)
        #expect(LeadingFrameQueue.lead(refreshInterval: 1.0 / 120) == 2.0 / 120)
    }

    /// A frame is due when the player's clock reaches it — the refresh a
    /// just-in-time pull would have enqueued it at.
    @Test func aFrameIsDueWhenThePlayersClockReachesIt() {
        let now = 100.0
        // 60 Hz, one refresh ahead: a frame a few ms of film behind what was
        // asked is still the next refresh's.
        let refresh = 1.0 / 60
        #expect(LeadingFrameQueue.due(hostTime: now, refreshInterval: refresh,
                                      requestedHostTime: now + refresh, behind: 0.005, rate: 1) == now + refresh)
        // 120 Hz, two refreshes ahead: 2 ms behind is the SECOND refresh's
        // (the first would not have had it yet)…
        let short = 1.0 / 120
        let late = LeadingFrameQueue.due(hostTime: now, refreshInterval: short,
                                         requestedHostTime: now + 2 * short, behind: 0.002, rate: 1)
        #expect(late > now + short && late <= now + 2 * short)
        // …and 10 ms behind is the first's.
        let early = LeadingFrameQueue.due(hostTime: now, refreshInterval: short,
                                          requestedHostTime: now + 2 * short, behind: 0.010, rate: 1)
        #expect(early <= now + short + 1e-9)
    }

    /// Never before the next refresh — the one being drawn is already gone —
    /// and at the next refresh on a clock that is not moving: a paused clip's
    /// scrub is one refresh behind the finger, not lost.
    @Test func aFrameIsNeverDueBeforeTheNextRefresh() {
        let now = 100.0
        let refresh = 1.0 / 60
        #expect(LeadingFrameQueue.due(hostTime: now, refreshInterval: refresh,
                                      requestedHostTime: now + refresh, behind: 0.4, rate: 1) == now + refresh)
        #expect(LeadingFrameQueue.due(hostTime: now, refreshInterval: refresh,
                                      requestedHostTime: now + refresh, behind: 0, rate: 0) == now + refresh)
    }

    /// A refresh shows the latest frame due by then and drops the ones before
    /// it; a frame not yet due stays held.
    @Test func aRefreshTakesTheLatestDueFrame() {
        var queue = LeadingFrameQueue()
        let first = queue.hold(Self.buffer(), itemTime: .zero, due: 10)
        let second = queue.hold(Self.buffer(), itemTime: .zero, due: 10.01)
        let third = queue.hold(Self.buffer(), itemTime: .zero, due: 10.05)
        #expect(first < second && second < third)
        #expect(queue.isFull)
        #expect(queue.takeDue(at: 9.9) == nil)
        #expect(queue.takeDue(at: 10.02)?.id == second)
        #expect(queue.entries.map(\.id) == [third])
        #expect(queue.takeAll()?.id == third)
        #expect(queue.isEmpty)
    }
}

/// A companion on a REAL playing surface: every frame it is told about was
/// handed to it a refresh or more before, and is the very frame the surface is
/// given in the turn it is told.
///
/// ⚠️ SAMPLE-BUFFER BACKING ONLY: under `-avplayer-render` there is no renderer
/// to lead, and nothing is ever prepared.
@MainActor
@Suite(.serialized, .enabled(if: VideoRenderFlags.usesSampleBufferLayer), .exclusiveMediaWork)
struct VideoFrameCompanionTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    @MainActor
    private final class Recorder: VideoFrameCompanion {
        weak var surface: VideoRenderView?
        var wantsFramesAhead = true
        var prepared: [VideoFrameID: (buffer: CVPixelBuffer, at: CFTimeInterval)] = [:]
        var presented: [VideoFrameID] = []
        /// Presents whose frame was not what the surface was just given.
        var mismatches: [String] = []
        /// Host time between a frame's `prepare` and its `present`.
        var leads: [CFTimeInterval] = []
        var prepareCount = 0

        func prepare(_ buffer: CVPixelBuffer, as frame: VideoFrameID) {
            prepareCount += 1
            prepared[frame] = (buffer, CACurrentMediaTime())
        }

        func present(_ frame: VideoFrameID) {
            presented.append(frame)
            guard let entry = prepared.removeValue(forKey: frame) else {
                mismatches.append("\(frame) was never prepared")
                return
            }
            leads.append(CACurrentMediaTime() - entry.at)
            if surface?.currentFrameBuffer !== entry.buffer {
                mismatches.append("\(frame) is not the frame on the surface")
            }
        }
    }

    private func clip(seconds: Double = 3) async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: seconds)
            .playableURL(for: URL(string: "mock://video/companion?w=240&h=240")!)
    }

    private func waitFor(within limit: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + limit
        while !condition(), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aPlayingSurfaceTellsItsCompanionEachFrameAheadAndThenWithTheFrame() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let surface = VideoRenderView()
        surface.frame = window.bounds
        window.addSubview(surface)
        let recorder = Recorder()
        recorder.surface = surface
        surface.frameCompanion = recorder
        defer { controller.stop(surface) }
        await controller.play(try await clip(), in: surface)

        try await waitFor { recorder.presented.count >= 30 }
        #expect(recorder.presented.count >= 30,
                "guard: \(recorder.presented.count) frames presented, \(surface.enqueuedFrameCount) enqueued")
        #expect(recorder.mismatches.isEmpty, "\(recorder.mismatches.prefix(5))")
        // Ahead by at least most of a refresh: never made in the turn it shows.
        let lead = recorder.leads.sorted()
        let median = lead.isEmpty ? 0 : lead[lead.count / 2]
        #expect((lead.first ?? 0) > 0.004, "shortest lead \(lead.first ?? 0)s, median \(median)s")
        #expect(recorder.presented == recorder.presented.sorted(), "frames presented out of order")
    }

    /// A paused clip that is scrubbed keeps its companion in step: the frame a
    /// seek lands on is prepared and presented like any other.
    @Test func aScrubbedPausedClipStaysInStep() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let surface = VideoRenderView()
        surface.frame = window.bounds
        window.addSubview(surface)
        let recorder = Recorder()
        recorder.surface = surface
        surface.frameCompanion = recorder
        defer { controller.stop(surface) }
        await controller.play(try await clip(), in: surface)
        try await waitFor { recorder.presented.count >= 5 && controller.playhead(in: surface) != nil }
        try #require(controller.playhead(in: surface) != nil, "guard: the item never reported a length")

        controller.setPaused(true, in: surface)
        try await Task.sleep(for: .milliseconds(200))
        let before = recorder.presented.count
        for fraction in [0.2, 0.5, 0.8] {
            controller.seek(toFraction: fraction, in: surface)
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(recorder.presented.count > before, "no scrubbed frame reached the companion")
        #expect(recorder.mismatches.isEmpty, "\(recorder.mismatches.prefix(5))")
    }

    /// A companion that stops asking costs the surface nothing: frames go on
    /// being drawn, just in time, and none is prepared any more.
    @Test func aCompanionThatStopsAskingLeavesTheSurfacePlaying() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let surface = VideoRenderView()
        surface.frame = window.bounds
        window.addSubview(surface)
        let recorder = Recorder()
        recorder.surface = surface
        surface.frameCompanion = recorder
        defer { controller.stop(surface) }
        await controller.play(try await clip(), in: surface)
        try await waitFor { recorder.presented.count >= 5 }

        recorder.wantsFramesAhead = false
        try await Task.sleep(for: .milliseconds(100))
        let presented = recorder.presented.count
        let prepared = recorder.prepareCount
        let enqueued = surface.enqueuedFrameCount
        try await waitFor(within: 10) { surface.enqueuedFrameCount >= enqueued + 10 }
        #expect(surface.enqueuedFrameCount >= enqueued + 10, "the surface stopped drawing")
        #expect(recorder.presented.count == presented, "frames were still presented")
        #expect(recorder.prepareCount == prepared, "frames were still prepared")
    }
}
