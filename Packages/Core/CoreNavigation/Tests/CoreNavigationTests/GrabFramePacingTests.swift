import QuartzCore
import Testing
@testable import CoreNavigation

/// A grab's frame pacing (#1915): the summary the `-grab-frames` log prints.
struct GrabFramePacingTests {
    private let frame: CFTimeInterval = 1.0 / 120

    @Test func aSteadyGrabHasNoHitch() throws {
        let pacing = try #require(GrabFramePacing(intervals: Array(repeating: frame, count: 60), expected: frame))
        #expect(pacing.frames == 60)
        #expect(pacing.hitches == 0)
        #expect(abs(pacing.median - frame) < 1e-9)
        #expect(abs(pacing.worst - frame) < 1e-9)
    }

    /// A frame over one and a half intervals missed a refresh; the worst and
    /// the 95th percentile say how bad.
    @Test func aMissedRefreshIsAHitch() throws {
        let intervals = Array(repeating: frame, count: 95) + Array(repeating: frame * 3, count: 5)
        let pacing = try #require(GrabFramePacing(intervals: intervals, expected: frame))
        #expect(pacing.hitches == 5)
        #expect(abs(pacing.worst - frame * 3) < 1e-9)
        #expect(abs(pacing.median - frame) < 1e-9)
        #expect(pacing.line.contains("5 hitches"))
    }

    @Test func nothingToMeasureIsNil() {
        #expect(GrabFramePacing(intervals: [], expected: frame) == nil)
        #expect(GrabFramePacing(intervals: [frame], expected: 0) == nil)
    }
}
