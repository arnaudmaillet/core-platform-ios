import Testing
import UIKit
@testable import Upload

/// The ring round the shutter: where each clip of the take is drawn.
@MainActor
struct CaptureShutterTests {
    private static let gap = CaptureShutterView.segmentGap

    /// ⚠️ Between two clips there is a clear 3° gap — the boundary reads — and
    /// the last clip runs to its end.
    @Test func clipsAreSeparatedByAClearGap() {
        let segments: [ClosedRange<Double>] = [0...0.1, 0.1...0.25, 0.25...0.4]
        let strokes = CaptureShutterView.strokes(for: segments)
        #expect(strokes.count == 3)
        for (drawn, next) in zip(strokes, strokes.dropFirst()) {
            #expect(next.lowerBound - drawn.upperBound >= Self.gap - 1e-9, "\(drawn) then \(next)")
        }
        #expect(Self.gap >= 3.0 / 360 - 1e-9, "at least 3°")
        #expect(strokes.last?.upperBound == 0.4, "the last clip to its end")
    }

    /// A clip shorter than the gap is still drawn, never under 1°.
    @Test func aShortClipIsStillDrawn() throws {
        let strokes = CaptureShutterView.strokes(for: [0...0.004, 0.004...0.2])
        let first = try #require(strokes.first)
        #expect(first.upperBound - first.lowerBound >= CaptureShutterView.shortestDrawn - 1e-9)
    }

    /// The ring draws what `strokes(for:)` says, and the clip being recorded
    /// starts one gap after the last one.
    @Test func theRingDrawsTheGapsAndTheLiveClipKeepsItsDistance() throws {
        let shutter = CaptureShutterView()
        shutter.layoutIfNeeded()
        let segments: [ClosedRange<Double>] = [0...0.1, 0.1...0.25]
        shutter.setSegments(segments, armedLast: false)
        let drawn = shutter.debugSegmentStrokes
        let expected = CaptureShutterView.strokes(for: segments)
        #expect(drawn.count == expected.count)
        for (a, b) in zip(drawn, expected) {
            #expect(abs(a.lowerBound - b.lowerBound) < 1e-4 && abs(a.upperBound - b.upperBound) < 1e-4, "\(a) vs \(b)")
        }
        shutter.setLive(from: 0.25, to: 0.3)
        let live = try #require(shutter.debugLiveStroke)
        #expect(abs(live.lowerBound - (0.25 + Self.gap)) < 1e-4, "the live clip starts a gap after the last: \(live)")
    }
}
