import Testing
import UIKit
@testable import DesignSystem

/// The pill's weight: the visible pill follows the model on a spring and
/// comes to rest exactly on it; anything that is not a travel snaps.
@MainActor
struct PagedTabBarPillMotionTests {
    private func bar() -> PagedTabBar {
        let bar = PagedTabBar(titles: ["Activity", "Gallery", "Short"], style: .floating)
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: PagedTabBar.Style.floating.height)
        bar.layoutIfNeeded()
        bar.debugEndPillLayout()
        return bar
    }

    @Test func thePillArrivesLateAndSettlesOnTheModel() {
        let bar = bar()
        bar.debugLetPillMove(true)
        let before = bar.debugPillBodyFrame
        #expect(abs(before.midX - bar.debugPillInViewport.midX) < 0.5, "guard: at rest the body sits on the model")

        bar.setProgress(2)
        let model = bar.debugPillInViewport
        #expect(bar.debugPillIsMoving, "a travel sets the body off")
        #expect(abs(bar.debugPillBodyFrame.midX - before.midX) < 0.5, "and it has not moved yet: it lags")

        bar.debugAdvancePill(frames: 6)
        let midway = bar.debugPillBodyFrame
        #expect(midway.midX > before.midX + 2 && midway.midX < model.midX - 2, "on its way after 50 ms: \(midway.midX) between \(before.midX) and \(model.midX)")
        #expect(midway.width > bar.debugPillInViewport.width, "stretched along its travel")

        let frames = bar.debugRunPillToRest()
        #expect(frames > 10 && frames < 240, "it takes a beat, not an age: \(frames) frames")
        let landed = bar.debugPillBodyFrame
        #expect(abs(landed.midX - model.midX) < 0.5 && abs(landed.width - model.width) < 0.5, "at rest exactly on the model: \(landed) vs \(model)")
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
