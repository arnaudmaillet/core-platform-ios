import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Upload

/// The device camera's engine, where it can be wrong without a device: what a
/// stop does before the movie output has written its first sample.
@MainActor
struct CaptureEngineTests {
    /// A movie output that has been asked to start and has not written a
    /// sample yet — `isRecording` stays false, exactly as the real one does in
    /// that moment.
    final class NotYetWriting: CaptureMovieRecording, @unchecked Sendable {
        private struct State {
            var starts = 0
            var stops = 0
            var finished: (@Sendable (Result<CaptureClip, any Error>) -> Void)?
            var url: URL?
        }

        private let state = Mutex(State())

        var isRecording: Bool { false }
        var recordedSeconds: TimeInterval { 0 }
        var starts: Int { state.withLock { $0.starts } }
        var stops: Int { state.withLock { $0.stops } }

        func start(to url: URL, limit: TimeInterval, finished: @escaping @Sendable (Result<CaptureClip, any Error>) -> Void) {
            state.withLock {
                $0.starts += 1
                $0.finished = finished
                $0.url = url
            }
        }

        /// ⚠️ A STOP FINISHES THE FILE, as the output's delegate would.
        func stop() {
            let (finished, url) = state.withLock { state -> ((@Sendable (Result<CaptureClip, any Error>) -> Void)?, URL?) in
                state.stops += 1
                defer { state.finished = nil }
                return (state.finished, state.url)
            }
            finished?(.success(CaptureClip(url: url ?? URL(fileURLWithPath: "/dev/null"), duration: 0)))
        }
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).mov")
    }

    /// ⚠️ A hold released at once, or a quick second tap on a locked clip,
    /// asks for the stop before the first sample: it must still stop — or the
    /// output records on until the take's budget runs out.
    @Test func aStopBeforeTheFirstSampleIsHonoured() async throws {
        let recorder = NotYetWriting()
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
        let promise = engine.record(to: Self.url, torch: false, limit: 180)
        engine.stopRecording()
        try await settle { recorder.stops > 0 }
        #expect(recorder.starts == 1)
        #expect(recorder.stops == 1, "the stop reached the output although it had not started writing")
        let clip = try await promise.value
        #expect(clip.duration == 0)
    }

    /// Closing the camera stops a recording that has been asked for, too.
    @Test func closingTheCameraStopsARequestedRecording() async throws {
        let recorder = NotYetWriting()
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
        let promise = engine.record(to: Self.url, torch: false, limit: 180)
        engine.stop()
        try await settle { recorder.stops > 0 }
        #expect(recorder.stops == 1)
        _ = try await promise.value
    }

    /// Once the clip has finished, a stop has nothing to stop.
    @Test func aStopAfterTheClipFinishedDoesNothing() async throws {
        let recorder = NotYetWriting()
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
        let promise = engine.record(to: Self.url, torch: false, limit: 180)
        engine.stopRecording()
        _ = try await promise.value
        engine.stopRecording()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.stops == 1)
    }
}
