import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The haptic map (#1881, #1882): the roles, the player's switch and pacing,
/// and the components that play them.
@MainActor
@Suite(.serialized)
struct HapticRolesTests {
    /// A recorder whose clock the test drives.
    private final class Clock {
        var now: TimeInterval = 100
    }

    private func recording(_ body: (Clock) -> Void) -> [Haptic] {
        let clock = Clock()
        let recorder = HapticRecorder()
        recorder.clock = { clock.now }
        Haptics.$recorder.withValue(recorder) { body(clock) }
        return recorder.played
    }

    // MARK: - The map

    /// Every recipe starts at today's dominant choice (#1882).
    @Test func theTableIsTheMap() {
        let expected: [Haptic: HapticRecipe] = [
            .tick: .selection,
            .step: .impact(.light, intensity: 1),
            .held: .impact(.medium, intensity: 1),
            .armed: .selection,
            .grab: .impact(.light, intensity: 1),
            .drop: .impact(.soft, intensity: 1),
            .boundary: .impact(.rigid, intensity: 0.5),
            .toggleOn: .impact(.light, intensity: 1),
            .commit: .impact(.medium, intensity: 1),
            .success: .notification(.success),
            .warning: .notification(.warning),
            .error: .notification(.error),
        ]
        #expect(Haptic.allCases.count == expected.count)
        for role in Haptic.allCases {
            #expect(role.recipe == expected[role], "\(role) plays \(role.recipe)")
        }
    }

    // MARK: - The switch

    /// Off, nothing records and nothing warms.
    @Test func offNothingPlaysAndNothingWarms() {
        let previous = HapticPreference.defaults
        defer { HapticPreference.defaults = previous }
        HapticPreference.defaults = UserDefaults(suiteName: "haptics-\(UUID().uuidString)")!
        HapticPreference.isOn = false
        let recorder = HapticRecorder()
        Haptics.$recorder.withValue(recorder) {
            for role in Haptic.allCases {
                Haptics.prepare(role)
                Haptics.play(role)
            }
        }
        #expect(recorder.played.isEmpty)
        #expect(recorder.prepared.isEmpty)
    }

    // MARK: - Pacing

    /// `step` three times 10 ms apart plays once; 70 ms apart, three times.
    @Test func stepsArePaced() {
        let close = recording { clock in
            for _ in 0..<3 {
                Haptics.play(.step)
                clock.now += 0.010
            }
        }
        #expect(close == [.step])
        let apart = recording { clock in
            for _ in 0..<3 {
                Haptics.play(.step)
                clock.now += 0.070
            }
        }
        #expect(apart == [.step, .step, .step])
    }

    /// The same role twice within 100 ms plays once; past it, twice. Two
    /// roles never pace each other.
    @Test func theSameRoleTwiceInAMomentPlaysOnce() {
        let played = recording { clock in
            Haptics.play(.commit)
            clock.now += 0.050
            Haptics.play(.commit)
            Haptics.play(.success)
            clock.now += 0.100
            Haptics.play(.commit)
        }
        #expect(played == [.commit, .success, .commit])
    }

    // MARK: - DetentFeedback

    /// One role per detent crossed by the viewer.
    @Test func aDetentPlaysPerIndexChange() {
        let played = recording { clock in
            let detents = DetentFeedback(role: .step)
            detents.update(index: 0, in: 0...9, isDriven: true)
            for index in 1...3 {
                clock.now += 0.1
                detents.update(index: index, in: 0...9, isDriven: true)
            }
            // The same detent again: nothing.
            clock.now += 0.1
            detents.update(index: 3, in: 0...9, isDriven: true)
        }
        #expect(played == [.step, .step, .step])
    }

    /// Silent when the viewer does not drive it, on a settle onto the same
    /// detent, and past either end — and it follows the index meanwhile.
    @Test func aDetentIsSilentWithoutTheViewerAndPastTheEnds() {
        let played = recording { clock in
            let detents = DetentFeedback(role: .tick)
            detents.update(index: 2, in: 0...4, isDriven: false)
            // A programmatic move.
            clock.now += 0.1
            detents.update(index: 3, in: 0...4, isDriven: false)
            #expect(detents.index == 3)
            // A rubber band past the end.
            clock.now += 0.1
            detents.update(index: 5, in: 0...4, isDriven: true)
            clock.now += 0.1
            detents.update(index: -1, in: 0...4, isDriven: true)
            #expect(detents.index == 3)
            // Back from the band onto the detent it sat on.
            clock.now += 0.1
            detents.update(index: 3, in: 0...4, isDriven: true)
            // A reset is a reload: silent.
            detents.reset(to: 0)
            clock.now += 0.1
            detents.update(index: 0, in: 0...4, isDriven: true)
        }
        #expect(played.isEmpty, "played \(played)")
    }

    /// A position on an axis of detents: the nearest one counts.
    @Test func aDetentReadsAPosition() {
        let played = recording { clock in
            let detents = DetentFeedback()
            detents.update(position: 0, spacing: 40, count: 5, isDriven: true)
            clock.now += 0.1
            detents.update(position: 19, spacing: 40, count: 5, isDriven: true)
            clock.now += 0.1
            detents.update(position: 21, spacing: 40, count: 5, isDriven: true)
            clock.now += 0.1
            detents.update(position: 400, spacing: 40, count: 5, isDriven: true)
        }
        #expect(played == [.step])
    }

    /// A fast fling crosses more detents than it plays.
    @Test func aFlingPlaysFewerStepsThanItCrosses() {
        let played = recording { clock in
            let detents = DetentFeedback()
            detents.update(index: 0, isDriven: true)
            for index in 1...10 {
                clock.now += 0.030
                detents.update(index: index, isDriven: true)
            }
        }
        #expect(!played.isEmpty && played.count < 10, "a fling played \(played.count) steps")
    }

    // MARK: - PullThresholdFeedback

    /// `armed` once per crossing: holding past says nothing, going back
    /// under re-arms, and a pull with no finger says nothing.
    @Test func aPullArmsOncePerCrossing() {
        let played = recording { clock in
            let pull = PullThresholdFeedback()
            pull.update(pulled: 80, threshold: 60, isTracking: true)
            clock.now += 0.2
            pull.update(pulled: 90, threshold: 60, isTracking: true)
            pull.update(pulled: 30, threshold: 60, isTracking: true)
            clock.now += 0.2
            pull.update(pulled: 70, threshold: 60, isTracking: true)
            pull.update(pulled: 10, threshold: 60, isTracking: false)
            clock.now += 0.2
            pull.update(pulled: 70, threshold: 60, isTracking: false)
        }
        #expect(played == [.armed, .armed])
    }

    // MARK: - AppControl

    /// A tap plays the control's role; a plain control plays nothing.
    @Test func aControlsTapPlaysItsRole() {
        let played = recording { _ in
            let button = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
            button.haptic = .toggleOn
            button.debugTap()
            AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow")).debugTap()
        }
        #expect(played == [.toggleOn])
    }

    /// A hold plays `held` — and nothing when a menu answers it with the
    /// system's own.
    @Test func aHoldPlaysHeldUnlessAMenuAnswers() {
        let played = recording { clock in
            let button = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
            button.holdFreezesScrolling = true
            button.debugHold(liftInside: false)
            clock.now += 0.2
            let menu = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
            menu.holdFreezesScrolling = true
            menu.menuProvider = { UIMenu(children: []) }
            menu.debugHold(liftInside: false)
        }
        #expect(played == [.held])
    }
}
