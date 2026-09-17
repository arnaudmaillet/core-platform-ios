import CoreGraphics
import Foundation
import MediaPlayback
import Testing
@testable import Upload

/// **EVERY FIELD OF `MediaEdits` MOVES ITS SIGNATURE — ASKED OF THE TYPE ITSELF.**
///
/// `signature` is written by hand, and it is a thumbnail cache key: a field it
/// forgets is a thumbnail on the next screen that silently keeps the previous
/// edit. The note on `signature` records that happening twice. A list of
/// hand-picked assertions would fall behind in exactly the same way, so the
/// list of fields is read with `Mirror` and compared with the table of
/// mutations below: a new field with no mutation fails the first test, and a
/// field the signature forgets fails the second.
struct MediaEditsSignatureTests {
    /// One change per field, keyed by the field's name as `Mirror` spells it.
    private static var mutations: [(field: String, mutate: (inout MediaEdits) -> Void)] {
        [
            ("fit", { $0.fit = .fit }),
            ("filter", { $0.filter = .mono }),
            ("adjustments", { $0.adjustments.warmth = 0.4 }),
            ("effect", { $0.effect = LookEffect(kind: .vhs, intensity: 0.5) }),
            ("crop", { $0.crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)) }),
            ("timeline", { $0.timeline = MediaTimeline(segments: [MediaSegment(start: 0, end: 1)]) }),
            ("overlays", { $0.overlays = [FrameOverlay(id: "a", content: .emoji("🙂"))] }),
            ("soundtrack", {
                $0.soundtrack = VideoSoundtrack(fileURL: URL(fileURLWithPath: "/tmp/song.m4a"), title: "Song")
            })
        ]
    }

    private static var fields: [String] {
        Mirror(reflecting: MediaEdits()).children.compactMap(\.label)
    }

    @Test func everyFieldHasAMutation() {
        let covered = Set(Self.mutations.map(\.field))
        let declared = Set(Self.fields)
        #expect(declared == covered,
                "fields with no mutation: \(declared.subtracting(covered)); stale rows: \(covered.subtracting(declared))")
        #expect(Self.fields.count == Self.mutations.count, "a field is listed twice")
    }

    @Test func everyFieldMovesTheSignature() {
        let untouched = MediaEdits.untouched.signature
        for (field, mutate) in Self.mutations {
            var edited = MediaEdits()
            mutate(&edited)
            #expect(edited != .untouched, "witness: the \(field) mutation changed nothing")
            #expect(edited.signature != untouched, "the signature does not spell \(field)")
        }
    }

    /// ⚠️ **A MOVE IS AN EDIT, NOT ONLY AN ADDITION.** An overlay dragged
    /// elsewhere, or a dial turned further, must redraw the thumbnail too — the
    /// signature spells each field whole, not a count or a flag.
    @Test func aChangeInsideAFieldMovesTheSignature() {
        var before = MediaEdits()
        before.overlays = [FrameOverlay(id: "a", content: .text(TextOverlay(text: "Hi")))]
        before.adjustments.contrast = 0.2
        var moved = before
        moved.overlays[0].placement.centre = CGPoint(x: 0.2, y: 0.8)
        var turned = before
        turned.adjustments.contrast = 0.3

        #expect(moved.signature != before.signature, "an overlay moved and the key stayed")
        #expect(turned.signature != before.signature, "a dial turned and the key stayed")
    }

    /// ⚠️ **ABSENT STILL MEANS UNTOUCHED.** A dial dragged back almost to its
    /// middle, and an effect dragged to nothing, leave no entry behind.
    @Test func nearNeutralWritesLeaveThePictureUntouched() {
        var edited = MediaEdits()
        edited.adjustments.brightness = 0.003
        edited.effect = LookEffect(kind: .blur, intensity: 0)
        #expect(edited.isUntouched)

        edited.adjustments.brightness = 0.2
        #expect(!edited.isUntouched, "witness: a real value is kept")
    }
}

/// **THE ONE MAPPING FROM AN EDIT TO WHAT A CLIP BECOMES.**
struct MediaEditsPlanTests {
    private final class Art: OverlayArtwork {
        func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage? { nil }
    }

    private static let file = URL(fileURLWithPath: "/tmp/clip.mov")

    private static var edited: MediaEdits {
        var edits = MediaEdits()
        edits.filter = .noir
        edits.adjustments.saturation = -0.5
        edits.crop = MediaCrop(rect: CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        edits.overlays = [FrameOverlay(id: "t", content: .text(TextOverlay(text: "Hello")))]
        edits.soundtrack = VideoSoundtrack(fileURL: URL(fileURLWithPath: "/tmp/song.m4a"), title: "Song")
        return edits
    }

    @Test func publishingCarriesTheWholeFinishTheSongAndTheArt() {
        let art = Art()
        let plan = Self.edited.exportPlan(
            sourceURL: Self.file, fileSeconds: 4, artwork: art, includingOverlays: true
        )

        #expect(plan.sourceURL == Self.file)
        #expect(plan.finish == Self.edited.finish(includingOverlays: true))
        #expect(plan.finish.overlays.count == 1)
        #expect(plan.finish.look.preset == .noir)
        #expect(plan.soundtrack == Self.edited.soundtrack)
        #expect((plan.artwork as? Art) === art)
    }

    /// The editor's canvas draws overlays as views, so its plan leaves them out
    /// — and nothing else.
    @Test func theEditorsPlanLeavesOnlyTheOverlaysOut() {
        let plan = Self.edited.exportPlan(
            sourceURL: Self.file, fileSeconds: 4, artwork: nil, includingOverlays: false
        )

        #expect(plan.finish.overlays.isEmpty)
        #expect(plan.finish.crop == Self.edited.crop)
        #expect(plan.finish.look == Self.edited.look)
        #expect(plan.soundtrack != nil)
        #expect(plan.artwork == nil)
    }

    @Test func aPiecesFilterReachesItsExportSegment() {
        var edits = MediaEdits()
        edits.timeline = MediaTimeline(segments: [
            MediaSegment(start: 0, end: 2, filter: .mono),
            MediaSegment(start: 2, end: 4)
        ])

        let plan = edits.exportPlan(sourceURL: Self.file, fileSeconds: 4, artwork: nil, includingOverlays: true)

        #expect(plan.segments.map(\.look) == [.mono, nil])
    }

    /// ⚠️ **TWO SPELLINGS OF "NO FILTER" WOULD BREAK EVERY TIMELINE EQUALITY.**
    /// `.original` is never stored — by the initialiser or by a write.
    @Test func originalIsNeverStoredOnAPiece() {
        #expect(MediaSegment(start: 0, end: 1, filter: .original).filter == nil)
        var piece = MediaSegment(start: 0, end: 1, filter: .fade)
        #expect(piece.filter == .fade, "witness: a real look is kept")
        piece.filter = .original
        #expect(piece.filter == nil)
        #expect(MediaSegment(start: 0, end: 1, filter: .original) == MediaSegment(start: 0, end: 1))
    }
}
