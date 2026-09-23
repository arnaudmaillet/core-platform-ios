import Testing
import UIKit
@testable import DesignSystem

/// The pill's give: the visible pill sits on the model, stretched by the
/// model's speed while it moves and plain again once it stops; anything
/// that is not a travel snaps.
@MainActor
struct PagedTabBarPillMotionTests {
    private func bar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.layoutIfNeeded()
        bar.debugEndPillLayout()
        return bar
    }

    @Test func thePillGoesWithTheModelAndStretchesByItsSpeed() {
        let bar = bar()
        bar.debugLetPillMove(true)
        let before = bar.debugPillBodyFrame
        #expect(abs(before.midX - bar.debugPillInViewport.midX) < 0.5, "guard: at rest the body sits on the model")

        // A fast sweep: the model moves 60pt within a few frames.
        bar.setProgress(0.1)
        bar.debugAdvancePill(frames: 1)
        bar.setProgress(0.5)
        let model = bar.debugPillInViewport
        let moving = bar.debugPillBodyFrame
        #expect(abs(moving.midX - model.midX) < 0.5, "no lag: the body is on the model at once, \(moving.midX) vs \(model.midX)")
        #expect(moving.width > model.width + 1, "stretched along its travel: \(moving.width) vs \(model.width)")
        #expect(bar.debugPillIsMoving, "the stretch is easing back")

        let frames = bar.debugRunPillToRest()
        #expect(frames > 2 && frames < 120, "it eases back within a few frames: \(frames)")
        let plain = bar.debugPillBodyFrame
        #expect(abs(plain.width - model.width) < 0.5 && abs(plain.midX - model.midX) < 0.5, "plain again, on the model: \(plain) vs \(model)")
        #expect(!bar.debugPillIsMoving)
    }

    @Test func aMoveThatIsNotATravelSnaps() {
        let bar = bar()
        bar.debugLetPillMove(true)
        bar.setProgress(1)
        bar.debugRunPillToRest()

        // A wider bar re-lays the segments out: the pill lands, no spring.
        bar.frame.size.width = 390
        bar.layoutIfNeeded()
        #expect(!bar.debugPillIsMoving, "a size change is not a travel")
        #expect(abs(bar.debugPillBodyFrame.midX - bar.debugPillInViewport.midX) < 0.5)

        bar.setTitles(["Activity", "Gallery", "Short", "Extra"])
        bar.layoutIfNeeded()
        #expect(!bar.debugPillIsMoving, "new titles are not a travel")
        #expect(abs(bar.debugPillBodyFrame.midX - bar.debugPillInViewport.midX) < 0.5)
    }

    @Test func reduceMotionSnapsEveryMove() {
        let bar = bar()
        bar.debugLetPillMove(false)
        bar.setProgress(2)
        #expect(!bar.debugPillIsMoving)
        #expect(abs(bar.debugPillBodyFrame.midX - bar.debugPillInViewport.midX) < 0.5, "the body is on the model at once")
    }

    @Test func thePillClicksLightlyOntoTheNearestItem() {
        let bar = bar()
        bar.debugLetPillMove(true)
        let home = bar.debugPillInViewport.midX

        // A little past the first item: the pill is drawn back towards it,
        // part of the way, never all of it.
        bar.setProgress(0.06)
        bar.debugRunPillToRest()
        let model = bar.debugPillInViewport.midX
        let body = bar.debugPillBodyFrame.midX
        #expect(model - home > 4, "guard: the model has left the item, by \(model - home)")
        #expect(body < model - 1 && body > home + 1, "the body sits between the item (\(home)) and the model (\(model)): \(body)")

        // Far from any item, the magnet lets go.
        bar.setProgress(0.5)
        bar.debugRunPillToRest()
        #expect(abs(bar.debugPillBodyFrame.midX - bar.debugPillInViewport.midX) < 0.5, "midway, the body is on the model")
    }
}
