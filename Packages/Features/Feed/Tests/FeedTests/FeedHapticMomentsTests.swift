import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Feed

/// THE MOMENTS FEED WAS MISSING (#1885): the emote wheel's detents and the
/// Shots author row's hold.
@MainActor
struct FeedHapticMomentsTests {
    private static let width: CGFloat = 45

    private func makeWheel() -> SnapShortcutRailView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let rail = SnapShortcutRailView(frame: CGRect(x: 200, y: 100, width: Self.width, height: 400))
        host.addSubview(rail)
        rail.setEmotes(Array(SnapShortcutRailView.reactionPool().prefix(12)))
        rail.bottomReservedInset = Self.width
        rail.layoutIfNeeded()
        return rail
    }

    /// What `body` played, the clock moving `spacing` seconds between two
    /// offsets.
    private func recorded(spacing: TimeInterval, _ body: (_ next: () -> Void) -> Void) -> [Haptic] {
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) { body { now += spacing } }
        return recorder.played
    }

    private func range(of rail: SnapShortcutRailView) -> (rest: CGFloat, max: CGFloat) {
        let rest = -rail.contentInset.top
        return (rest, max(rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom, rest))
    }

    /// One `step` per emote crossing the detent line under the finger.
    @Test func theWheelStepsOncePerDetentDragged() throws {
        let rail = makeWheel()
        let (rest, top) = range(of: rail)
        let step = SnapShortcutRailView.step
        try #require(top - rest >= step * 3, "guard: the wheel scrolls three detents")
        rail.debugIsDriven = true
        let played = recorded(spacing: 1) { next in
            for travel in [step * 0.3, step * 0.8, step * 1.2, step * 2, step * 2.1, step * 3] {
                rail.contentOffset.y = rest + travel
                next()
            }
        }
        #expect(played == [.step, .step, .step])
    }

    /// Silent without the viewer — the chevron's return, a reset — and past
    /// either end.
    @Test func theWheelIsSilentWhenTheViewerDoesNotMoveItAndPastItsEnds() throws {
        let rail = makeWheel()
        let (rest, top) = range(of: rail)
        let step = SnapShortcutRailView.step
        try #require(top - rest >= step * 3, "guard: the wheel scrolls three detents")
        let played = recorded(spacing: 1) { next in
            // The chevron's return and a reset.
            rail.debugIsDriven = false
            rail.contentOffset.y = rest + step * 3
            next()
            rail.contentOffset.y = rest
            next()
            rail.setEmotes(Array(SnapShortcutRailView.reactionPool().prefix(12)))
            rail.layoutIfNeeded()
            next()
            // A rubber band past either end, under the finger.
            rail.debugIsDriven = true
            rail.contentOffset.y = rest - step * 1.5
            next()
            rail.contentOffset.y = rest
            next()
            rail.contentOffset.y = top
            next()
            rail.contentOffset.y = top + step * 1.5
            next()
        }
        // Rest → top under the finger is a real crossing; nothing else is.
        #expect(played == [.step], "\(played)")
    }

    /// A fast flick plays fewer steps than the detents it crosses.
    @Test func aFastGlidePlaysFewerStepsThanItCrosses() throws {
        let rail = makeWheel()
        let (rest, top) = range(of: rail)
        let step = SnapShortcutRailView.step
        let crossed = Int((top - rest) / step)
        try #require(crossed >= 4, "guard: the wheel scrolls four detents")
        rail.debugIsDriven = true
        let played = recorded(spacing: 0.016) { next in
            for detent in 1...crossed {
                rail.contentOffset.y = rest + CGFloat(detent) * step
                next()
            }
        }
        #expect(!played.isEmpty)
        #expect(played.count < crossed, "a flick across \(crossed) detents played \(played.count)")
    }

    /// The Shots author row's hold is `held`, once.
    @Test func theShotsAuthorRowsHoldIsHeldOnce() {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        var opened = 0
        chrome.onAuthorLongPressed = { opened += 1 }
        let played = HapticRecorder.recording { chrome.debugHoldAuthorRow() }
        #expect(played == [.held])
        #expect(opened == 1)
    }
}
