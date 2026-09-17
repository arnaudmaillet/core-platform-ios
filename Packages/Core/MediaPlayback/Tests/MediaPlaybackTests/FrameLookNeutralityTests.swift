import CoreGraphics
import Foundation
import Testing
@testable import MediaPlayback

/// **WHAT "NOTHING WAS DONE" MEANS, FOR A LOOK AND A FINISH.**
///
/// Every screen and renderer asks `isNeutral` / `isNone` to skip work and to
/// decide whether an edit exists at all ("absent means untouched", in Upload's
/// `MediaEdits`). Two ways to get that wrong: a field the answer does not look
/// at — so a picture with only that field changed is published undressed — and
/// a near-zero value that is not zero — so a slider dragged back to its middle
/// leaves an edit behind. Field lists are read with `Mirror`, so a new field
/// with no row here fails.
struct FrameLookNeutralityTests {
    private typealias Key = LookAdjustments.Key

    private static func fields(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    // MARK: - Adjustments

    /// ⚠️ **ONE KEY PER FIELD, SAME NAME, SAME ORDER** — a field with no key can
    /// never be reset by a screen that loops over the keys.
    @Test func everyAdjustmentHasAKeyAndEveryKeyAField() {
        #expect(Self.fields(of: LookAdjustments()) == Key.allCases.map(\.rawValue))
    }

    @Test func eachKeyWritesItsOwnFieldAndBreaksNeutrality() {
        for key in Key.allCases {
            var dials = LookAdjustments()
            dials[key] = 0.5
            let moved = Mirror(reflecting: dials).children
                .filter { ($0.value as? Double) != 0 }
                .compactMap(\.label)
            #expect(moved == [key.rawValue], "\(key) wrote \(moved)")
            #expect(dials[key] == 0.5)
            #expect(!dials.isNeutral, "\(key) at 0.5 still reads as neutral")
        }
    }

    /// ⚠️ **THE SNAP, ON BOTH WRITE PATHS.** A slider dragged back to its middle
    /// lands a hair off zero; that is zero.
    @Test func aWriteNearZeroIsZero() {
        for key in Key.allCases {
            var dials = LookAdjustments()
            dials[key] = 0.004
            #expect(dials.isNeutral, "\(key) kept 0.004")
            dials[key] = 0.006
            #expect(!dials.isNeutral, "witness: \(key) must keep a value past the snap")
        }
        var direct = LookAdjustments()
        direct.brightness = -0.004
        #expect(direct.isNeutral, "a direct assignment skipped the snap")
    }

    @Test func aWriteIsClampedIntoItsKeysRange() {
        for key in Key.allCases {
            var dials = LookAdjustments()
            dials[key] = 5
            #expect(dials[key] == key.range.upperBound, "\(key) took 5")
            dials[key] = -5
            #expect(dials[key] == key.range.lowerBound, "\(key) took -5")
            dials[key] = .nan
            #expect(dials[key] == 0, "\(key) took NaN")
        }
        #expect(Key.warmth.range == -1...1)
        #expect(Key.grain.range == 0...1)
    }

    // MARK: - The look

    private static var lookMutations: [(field: String, mutate: (inout FrameLook) -> Void)] {
        [
            ("preset", { $0.preset = .chrome }),
            ("adjustments", { $0.adjustments.shadows = -0.3 }),
            ("effect", { $0.effect = LookEffect(kind: .posterize, intensity: 0.4) })
        ]
    }

    @Test func everyFieldOfALookBreaksNeutrality() {
        #expect(Set(Self.fields(of: FrameLook())) == Set(Self.lookMutations.map(\.field)))
        #expect(FrameLook.neutral.isNeutral, "witness")
        for (field, mutate) in Self.lookMutations {
            var look = FrameLook()
            mutate(&look)
            #expect(!look.isNeutral, "a look with only its \(field) changed reads as neutral")
        }
    }

    /// ⚠️ **AN EFFECT AT ZERO IS SPELLED NIL** — in the initialiser and on a write.
    @Test func anEffectAtZeroIsNoEffect() {
        var look = FrameLook()
        look.effect = LookEffect(kind: .blur, intensity: 0)
        #expect(look.effect == nil)
        #expect(look.isNeutral)
        #expect(FrameLook(effect: LookEffect(kind: .blur, intensity: 0.001)).effect == nil)

        look.effect = LookEffect(kind: .blur, intensity: 0.3)
        #expect(look.effect?.intensity == 0.3, "witness: a real effect is kept")
        #expect(LookEffect(kind: .comic, intensity: 2).intensity == 1)
        var effect = LookEffect(kind: .comic, intensity: 0.5)
        effect.intensity = -1
        #expect(effect.intensity == 0)
    }

    // MARK: - The finish

    private static var finishMutations: [(field: String, mutate: (inout FrameFinish) -> Void)] {
        [
            ("crop", { $0.crop = FrameCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)) }),
            ("look", { $0.look.preset = .mono }),
            ("overlays", { $0.overlays = [FrameOverlay(id: "o", content: .emoji("🎬"))] })
        ]
    }

    @Test func everyFieldOfAFinishBreaksNone() {
        #expect(Set(Self.fields(of: FrameFinish())) == Set(Self.finishMutations.map(\.field)))
        #expect(FrameFinish.none.isNone, "witness")
        for (field, mutate) in Self.finishMutations {
            var finish = FrameFinish()
            mutate(&finish)
            #expect(!finish.isNone, "a finish with only its \(field) changed reads as none")
        }
    }

    @Test func aCropIsUntouchedOnlyWhenEveryFieldIs() {
        #expect(FrameCrop().isUntouched)
        #expect(!FrameCrop(angle: 3).isUntouched)
        #expect(!FrameCrop(isMirrored: true).isUntouched)
        #expect(!FrameCrop(rect: CGRect(x: 0.1, y: 0, width: 0.9, height: 1)).isUntouched)
    }

    // MARK: - The live board

    @Test func aLiveLookHandsBackWhatWasSetLast() {
        let board = VideoLiveLook(.neutral)
        #expect(board.look == .neutral)
        board.set(FrameLook(preset: .noir))
        board.set(FrameLook(preset: .fade))
        #expect(board.look.preset == .fade)
    }
}

/// **A FINISH, A LOOK OR A SONG IS SOMETHING TO DRAW — ON AN UNCUT CLIP TOO.**
///
/// ⚠️ An uncut clip leaves by `timeRange` or passthrough, and both draw nothing:
/// a plan that forgot to ask for a composition would publish a filtered video
/// as shot, with no error anywhere.
struct ExportPlanCompositionTests {
    private static let file = URL(fileURLWithPath: "/tmp/clip.mov")

    @Test func anUntouchedPlanNeedsNoComposition() {
        #expect(!VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: Self.file)))
        #expect(!VideoExporter.needsComposition(
            for: VideoExportPlan(sourceURL: Self.file, segments: [VideoExportSegment(start: 1, end: 3)])
        ), "one piece at 1x is a time range")
    }

    @Test func aFinishOrASongOnAnUncutClipNeedsOne() {
        let look = FrameFinish(look: FrameLook(preset: .mono))
        let crop = FrameFinish(crop: FrameCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        let song = VideoSoundtrack(fileURL: URL(fileURLWithPath: "/tmp/song.m4a"), title: "Song")

        #expect(VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: Self.file, finish: look)))
        #expect(VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: Self.file, finish: crop)))
        #expect(VideoExporter.needsComposition(for: VideoExportPlan(sourceURL: Self.file, soundtrack: song)))
    }

    @Test func aPieceWithALookNeedsOne() {
        #expect(VideoExporter.needsComposition(
            for: VideoExportPlan(sourceURL: Self.file, segments: [VideoExportSegment(start: 1, end: 3, look: .tonal)])
        ))
    }

    /// ⚠️ **`.original` IS NO LOOK** — stored as one, it would build a
    /// compositor to draw nothing.
    @Test func anOriginalLookIsNoLook() {
        let piece = VideoExportSegment(start: 1, end: 3, look: .original)
        #expect(piece.look == nil)
        #expect(piece == VideoExportSegment(start: 1, end: 3))
        #expect(!VideoExporter.needsComposition(for: [piece]))
    }

    @Test func aCropsOutputIsEvenAndFollowsTheTurn() {
        let half = FrameCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(half.outputSize(forUpright: CGSize(width: 1920, height: 1080)) == CGSize(width: 960, height: 540))
        #expect(half.outputSize(forUpright: CGSize(width: 1001, height: 999)) == CGSize(width: 500, height: 500),
                "sides are rounded to even")
        let quarterTurn = FrameCrop(angle: 90)
        let turned = quarterTurn.outputSize(forUpright: CGSize(width: 1920, height: 1080))
        #expect(turned == CGSize(width: 1080, height: 1920), "a quarter turn swaps the sides: \(turned)")
        let sliver = FrameCrop(rect: CGRect(x: 0, y: 0, width: 0.0001, height: 1))
        #expect(sliver.outputSize(forUpright: CGSize(width: 100, height: 100)).width == 2, "never under two")
    }
}
