import Testing
@testable import Maps

/// The map's previews come back with a COMMITTED close of the screen over
/// it, never while a grab is under the finger nor after one springs back
/// (#1594).
@MainActor
struct MapPreviewResumeTests {
    @Test func anOrdinaryAppearanceResumesAtOnce() {
        var resumed = 0
        MapPreviewResume.whenSettled(
            isInteractive: false,
            notifyWhenInteractionEnds: { _ in Issue.record("asked to wait for an interaction") },
            resume: { resumed += 1 }
        )
        #expect(resumed == 1)
    }

    @Test func aGrabResumesOnlyOnACommittedRelease() {
        var resumed = 0
        var ended: ((Bool) -> Void)?
        MapPreviewResume.whenSettled(
            isInteractive: true, notifyWhenInteractionEnds: { ended = $0 }, resume: { resumed += 1 }
        )
        #expect(resumed == 0, "the previews came back under the finger")
        ended?(false)
        #expect(resumed == 1)
    }

    @Test func aGrabLetGoShortResumesNothing() {
        var resumed = 0
        var ended: ((Bool) -> Void)?
        MapPreviewResume.whenSettled(
            isInteractive: true, notifyWhenInteractionEnds: { ended = $0 }, resume: { resumed += 1 }
        )
        ended?(true)
        #expect(resumed == 0, "a cancelled grab brought the previews back")
    }
}
