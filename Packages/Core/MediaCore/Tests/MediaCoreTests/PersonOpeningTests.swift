import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// What a tap and a hold on a person beside content do (#2145): a tap opens
/// the card, a hold the profile with `held`; nothing at all without a person.
@MainActor
struct PersonOpeningTests {
    private final class Opened {
        var cards = 0
        var profiles = 0
    }

    private func opening(person: @escaping () -> Bool = { true }) -> (PersonOpening, Opened, UIView) {
        let view = UIView()
        let opened = Opened()
        let opening = PersonOpening(on: view)
        opening.hasPerson = person
        opening.openCard = { opened.cards += 1 }
        opening.openProfile = { opened.profiles += 1 }
        return (opening, opened, view)
    }

    @Test func aTapOpensTheCardAndAHoldTheProfile() {
        let (opening, opened, _) = opening()
        opening.debugTap()
        #expect(opened.cards == 1 && opened.profiles == 0)
        opening.debugHold()
        #expect(opened.cards == 1 && opened.profiles == 1, "the hold opened the card as well")
    }

    @Test func theHoldPlaysHeldOnce() {
        let (opening, _, _) = opening()
        let played = HapticRecorder.recording { opening.debugHold() }
        #expect(played == [.held])
    }

    /// A group, or an id not known yet: no action, no haptic.
    @Test func noPersonNoActionAndNoHaptic() {
        var known = false
        let (opening, opened, _) = opening(person: { known })
        let played = HapticRecorder.recording {
            opening.debugTap()
            opening.debugHold()
        }
        #expect(opened.cards == 0 && opened.profiles == 0)
        #expect(played.isEmpty)
        // The id lands: it works at once.
        known = true
        opening.debugHold()
        #expect(opened.profiles == 1)
    }

    /// The tap waits for the hold to fail, so a recognised hold is never also
    /// a tap; the hold takes 0.4 s.
    @Test func theTapWaitsForTheHold() throws {
        let (_, _, view) = opening()
        let recognizers = view.gestureRecognizers ?? []
        let hold = try #require(recognizers.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        #expect(hold.minimumPressDuration == PersonOpening.holdDuration)
        #expect(hold.isEnabled)
        #expect(recognizers.contains { $0 is UITapGestureRecognizer })
    }

    /// No profile route, no hold, and no "Open profile" for VoiceOver.
    @Test func withoutAProfileRouteThereIsNoHold() {
        let (opening, _, view) = opening()
        opening.openProfile = nil
        #expect(!opening.debugTakesHold)
        #expect(view.accessibilityCustomActions == nil)
    }

    /// The host keeps the opening (a stored property): the view's actions
    /// and recognisers point at it weakly.
    @Test func voiceOverOffersOpenProfile() throws {
        let (opening, opened, view) = opening()
        let action = try #require(view.accessibilityCustomActions?.first)
        #expect(action.name == PersonOpening.openProfileActionName)
        _ = action.actionHandler?(action)
        #expect(opened.profiles == 1)
        withExtendedLifetime(opening) {}
    }
}
