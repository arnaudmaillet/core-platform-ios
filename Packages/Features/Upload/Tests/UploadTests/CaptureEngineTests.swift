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
            var canRecord = true
            /// ⚠️ KEPT, as the movie output's recorder keeps its last
            /// delegate — which is what made the engine's cycle.
            var lastFinished: (@Sendable (Result<CaptureClip, any Error>) -> Void)?
        }

        private let state = Mutex(State())

        var isRecording: Bool { false }
        var canRecord: Bool {
            get { state.withLock { $0.canRecord } }
            set { state.withLock { $0.canRecord = newValue } }
        }
        var recordedSeconds: TimeInterval { 0 }
        var starts: Int { state.withLock { $0.starts } }
        var stops: Int { state.withLock { $0.stops } }

        func start(to url: URL, limit: TimeInterval, finished: @escaping @Sendable (Result<CaptureClip, any Error>) -> Void) {
            state.withLock {
                $0.starts += 1
                $0.finished = finished
                $0.lastFinished = finished
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
        // ⚠️ REQUIRED BEFORE THE AWAIT: broken, the stop never reaches the
        // output, the promise never resolves, and an `#expect` here would let
        // the test wait on it forever instead of failing.
        try #require(recorder.stops == 1, "the stop reached the output although it had not started writing")
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
        try #require(recorder.stops == 1, "required before the await, for the reason above")
        _ = try await promise.value
    }

    /// Once the clip has finished, a stop has nothing to stop.
    @Test func aStopAfterTheClipFinishedDoesNothing() async throws {
        let recorder = NotYetWriting()
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
        let promise = engine.record(to: Self.url, torch: false, limit: 180)
        engine.stopRecording()
        try await settle { recorder.stops > 0 }
        try #require(recorder.stops == 1, "required before the await, for the reason above")
        _ = try await promise.value
        engine.stopRecording()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.stops == 1)
    }

    /// ⚠️ With no camera connected, a photograph fails — it does not reach
    /// `capturePhoto`, which raises an exception and takes the app down.
    @Test func aPhotographWithNoCameraConnectedFailsInsteadOfRaising() async throws {
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: NotYetWriting())
        await #expect(throws: CaptureSourceError.photoFailed) {
            _ = try await engine.photograph(to: Self.url, flash: .off)
        }
    }

    /// ⚠️ With no camera connected, a recording fails without starting the
    /// output — whose `startRecording` would raise.
    @Test func aRecordingWithNoCameraConnectedFailsWithoutStarting() async throws {
        let recorder = NotYetWriting()
        recorder.canRecord = false
        let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
        await #expect(throws: CaptureSourceError.recordingFailed) {
            _ = try await engine.record(to: Self.url, torch: false, limit: 180).value
        }
        #expect(recorder.starts == 0)
    }

    /// ⚠️ A camera that recorded a clip is freed with its screen: the
    /// recorder keeps its last completion, and that completion must not keep
    /// the engine — its session, its feed, the renderer behind the feed.
    @Test func theEngineIsFreedAfterItRecordedAClip() async throws {
        let recorder = NotYetWriting()
        weak var released: AVCaptureEngine?
        do {
            let engine = AVCaptureEngine(feed: CaptureFrameFeed(), recorder: recorder)
            released = engine
            let promise = engine.record(to: Self.url, torch: false, limit: 180)
            engine.stopRecording()
            try await settle { recorder.stops > 0 }
            try #require(recorder.stops == 1)
            _ = try await promise.value
        }
        try await settle { released == nil }
        #expect(released == nil, "the engine outlived its last clip")
    }
}
