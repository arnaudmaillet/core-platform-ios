import Testing
import UIKit
@testable import DesignSystem

/// The sound pill's word and its tap.
///
/// ⚠️ **THE WORD IS READ IN TWO PLACES, AND BOTH ARE ASSERTED.** What is drawn
/// (`debugTitle`) and what VoiceOver says (`accessibilityLabel`) are set by two
/// separate statements; a `setTitle` that forgot one would show "Song: Intro"
/// and speak "Add a song".
@MainActor
struct SoundPillViewTests {
    @Test func setTitleChangesTheWordAndTheLabel() {
        let pill = SoundPillView(title: "Add a song", neverTruncates: true)
        #expect(pill.debugTitle == "Add a song", "witness: the word it was built with")

        pill.setTitle("Song: A much longer title")

        #expect(pill.debugTitle == "Song: A much longer title")
        #expect(pill.accessibilityLabel == "Song: A much longer title")
    }

    /// ⚠️ **A LONGER WORD UNDER THE OLD FLOOR IS THE TRUNCATION `neverTruncates`
    /// EXISTS TO REFUSE.** The floor is measured from the word, so it has to be
    /// measured again when the word changes — and grow with it.
    @Test func setTitleRaisesTheFloorForALongerWord() throws {
        let pill = SoundPillView(title: "Add a song", neverTruncates: true)
        let before = try #require(pill.debugFloorWidth, "a pill that never truncates has a floor")

        pill.setTitle("Song: A much longer title")

        let after = try #require(pill.debugFloorWidth)
        #expect(after > before, "the floor stayed at \(before) for a longer word")
    }

    @Test func aPillThatMayTruncateHasNoFloor() {
        let pill = SoundPillView()
        pill.setTitle("A sound with a long name")
        #expect(pill.debugFloorWidth == nil)
    }

    @Test func aTapReachesTheHost() {
        let pill = SoundPillView(title: "Add a song")
        var taps = 0
        pill.onTap = { taps += 1 }

        pill.sendActions(for: .touchUpInside)
        #expect(taps == 1)
        #expect(pill.accessibilityActivate(), "VoiceOver's double tap is taken")
        #expect(taps == 2)
    }

    /// The text-post composer sets no action, and its pill has to stay inert —
    /// including for VoiceOver, which must not be told the tap was handled.
    @Test func withoutAnActionATapReachesNothing() {
        let pill = SoundPillView()
        pill.sendActions(for: .touchUpInside)
        #expect(pill.accessibilityActivate() == false)
    }
}
