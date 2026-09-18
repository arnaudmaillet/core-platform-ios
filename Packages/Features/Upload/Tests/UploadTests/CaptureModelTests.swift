import CoreGraphics
import Foundation
import Testing
@testable import Upload

/// The camera's rules, apart from any camera: the take's budget and undo, what
/// the shutter decides, and the crop a ratio hands the editor.
struct CaptureTakeTests {
    private static func clip(_ seconds: TimeInterval) -> CaptureClip {
        CaptureClip(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"), duration: seconds)
    }

    /// Three minutes is the budget of the WHOLE take, clips together.
    @Test func theBudgetIsTheTakesNotAClips() {
        var take = CaptureTake()
        take.append(Self.clip(100))
        take.append(Self.clip(60))
        #expect(take.total == 160)
        #expect(take.remaining == 20)
        #expect(!take.isFull)
        take.append(Self.clip(20))
        #expect(take.isFull, "180 seconds of clips is a full take")
        #expect(take.remaining == 0)
    }

    /// A hold lifted at once leaves two frames, not a clip.
    @Test func aSlipShorterThanTheShortestClipIsNotKept() {
        var take = CaptureTake()
        let slip = take.append(Self.clip(0.1))
        #expect(!slip)
        #expect(take.isEmpty)
        let kept = take.append(Self.clip(CaptureTake.shortest))
        #expect(kept)
        #expect(take.clips.count == 1)
    }

    /// The first tap only points; the second deletes — and deletes the LAST.
    @Test func undoArmsFirstAndDeletesTheLastClipSecond() {
        var take = CaptureTake()
        let first = Self.clip(2)
        let second = Self.clip(3)
        take.append(first)
        take.append(second)

        #expect(take.undo() == .armed)
        #expect(take.clips.count == 2, "arming deletes nothing")
        #expect(take.isArmedToUndo)
        #expect(take.undo() == .deleted(second))
        #expect(take.clips == [first])
        #expect(!take.isArmedToUndo, "and the next tap starts over")
        #expect(take.undo() == .armed)
    }

    /// Anything else the author does puts the armed undo down — above all a
    /// new clip, which would otherwise be deleted without ever being pointed at.
    @Test func aNewClipDisarmsTheUndo() {
        var take = CaptureTake()
        take.append(Self.clip(2))
        _ = take.undo()
        take.append(Self.clip(2))
        #expect(!take.isArmedToUndo)
        #expect(take.undo() == .armed, "a fresh arm, not a delete")
        #expect(take.clips.count == 2)
    }

    @Test func undoOnAnEmptyTakeDoesNothing() {
        var take = CaptureTake()
        #expect(take.undo() == .nothing)
        #expect(!take.isArmedToUndo)
    }

    /// Each clip is its share of the ring, one after another.
    @Test func segmentsAreEachClipsShareOfTheBudgetInOrder() {
        var take = CaptureTake()
        take.append(Self.clip(18))
        take.append(Self.clip(36))
        let segments = take.segments
        #expect(segments.count == 2)
        #expect(abs(segments[0].lowerBound - 0) < 1e-9)
        #expect(abs(segments[0].upperBound - 0.1) < 1e-9)
        #expect(abs(segments[1].lowerBound - 0.1) < 1e-9)
        #expect(abs(segments[1].upperBound - 0.3) < 1e-9)
    }
}

struct CaptureShutterLogicTests {
    /// A tap on an empty take is a photograph.
    @Test func aTapOnAnEmptyTakeTakesAPhoto() {
        var logic = CaptureShutterLogic()
        #expect(logic.tap(takeIsEmpty: true, takeIsFull: false) == .takePhoto)
        #expect(logic.phase == .idle)
    }

    /// Once the take holds a clip a tap records the next one hands-free, and
    /// the next tap stops it.
    @Test func aTapOnATakeWithClipsRecordsLockedAndTheNextTapStops() {
        var logic = CaptureShutterLogic()
        #expect(logic.tap(takeIsEmpty: false, takeIsFull: false) == .startRecording(locked: true))
        #expect(logic.phase == .locked)
        #expect(logic.tap(takeIsEmpty: false, takeIsFull: false) == .stopRecording)
        #expect(logic.phase == .idle)
    }

    /// Hold to record, release to stop.
    @Test func aHoldRecordsUntilReleased() {
        var logic = CaptureShutterLogic()
        #expect(logic.beginHold(takeIsFull: false) == .startRecording(locked: false))
        #expect(logic.phase == .holding)
        #expect(logic.moveHold(by: CGPoint(x: -20, y: 0)) == .none, "short of the padlock")
        #expect(logic.endHold() == .stopRecording)
        #expect(logic.phase == .idle)
    }

    /// Sliding onto the padlock locks; the lifted finger then stops nothing,
    /// and only a tap ends the clip.
    @Test func slidingOntoThePadlockLocksAndReleaseNoLongerStops() {
        var logic = CaptureShutterLogic()
        _ = logic.beginHold(takeIsFull: false)
        #expect(logic.moveHold(by: CGPoint(x: -CaptureShutterLogic.lockDistance, y: 4)) == .lock)
        #expect(logic.phase == .locked)
        #expect(logic.endHold() == .none, "the finger is free once locked")
        #expect(logic.phase == .locked)
        #expect(logic.tap(takeIsEmpty: false, takeIsFull: false) == .stopRecording)
    }

    /// Sliding up zooms; it never locks, however far it goes sideways on the way.
    @Test func aSlideUpwardsZoomsAndDoesNotLock() {
        var logic = CaptureShutterLogic()
        _ = logic.beginHold(takeIsFull: false)
        #expect(logic.moveHold(by: CGPoint(x: -80, y: -200)) == .none)
        #expect(logic.phase == .holding)
        let zoom = CaptureShutterLogic.zoom(from: 1, translation: CGPoint(x: 0, y: -CaptureShutterLogic.zoomTravel))
        #expect(abs(zoom - 2) < 1e-9, "one doubling per zoomTravel points up")
        #expect(CaptureShutterLogic.zoom(from: 1.5, translation: CGPoint(x: 0, y: 40)) == 1.5, "never below where it began")
    }

    /// A full take refuses to record, by hold or by tap.
    @Test func aFullTakeRefusesToRecord() {
        var logic = CaptureShutterLogic()
        #expect(logic.beginHold(takeIsFull: true) == .none)
        #expect(logic.tap(takeIsEmpty: false, takeIsFull: true) == .none)
        #expect(logic.phase == .idle)
    }
}

struct CaptureRatioTests {
    /// 3:4 of a 9:16 frame keeps the full width and the middle of the height.
    @Test func aClassicRatioOfATallFrameKeepsTheMiddleBand() {
        let crop = CaptureRatio.classic.crop(forUpright: CGSize(width: 1080, height: 1920))
        #expect(abs(crop.rect.width - 1) < 1e-9)
        #expect(abs(crop.rect.height - 0.75) < 1e-9, "1080 / (3/4) = 1440 of 1920")
        #expect(abs(crop.rect.minY - 0.125) < 1e-9, "centred")
        #expect(crop.angle == 0)
        #expect(!crop.isMirrored)
    }

    /// Square of a landscape frame cuts the sides.
    @Test func aSquareOfAWideFrameCutsTheSides() {
        let crop = CaptureRatio.square.crop(forUpright: CGSize(width: 1920, height: 1080))
        #expect(abs(crop.rect.height - 1) < 1e-9)
        #expect(abs(crop.rect.width - 0.5625) < 1e-9)
        #expect(abs(crop.rect.midX - 0.5) < 1e-9)
    }

    /// A frame already in the shape hands the editor NOTHING — absent means
    /// untouched, and an edit that keeps it all says nothing.
    @Test func aFrameAlreadyInTheShapeIsLeftUntouched() {
        #expect(CaptureRatio.tall.crop(forUpright: CGSize(width: 1080, height: 1920)).isUntouched)
        #expect(CaptureRatio.tall.crop(forUpright: CGSize(width: 720, height: 1281)).isUntouched, "within half a percent")
        #expect(CaptureRatio.square.crop(forUpright: .zero).isUntouched, "an unreadable size cuts nothing")
    }

    /// The preview's window is the same shape, centred.
    @Test func theWindowIsTheLargestCentredRectangleOfTheShape() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 711)
        let square = CaptureRatio.square.window(in: bounds)
        #expect(square.width == 400)
        #expect(square.height == 400)
        #expect(abs(square.midY - bounds.midY) < 1e-9)
    }
}
