import Testing
import UIKit
@testable import CoreNavigation

/// The clip time a source's picture shows, handed to the page about to start
/// that clip (#625).
///
/// A map marker flies a baked preview sheet: a clip played back as pictures.
/// The page it opens starts its own video, and the live picture takes over
/// from the sheet near the landing. Started at zero, it took over with a
/// different moment of the clip than the one the card had flown — two poses of
/// one subject, ghosting through the cross-fade.
@MainActor
struct ZoomFlightMediaTimeTests {
    @Test("A presenting flight tells the page where the card's picture is, right after willBegin")
    func thePageHearsTheTime() {
        let page = RecordingPage()
        _ = ZoomTransitionController(source: TimedSource(time: 3.25), destination: page)
        #expect(page.calls == ["willBegin", "startMedia 3.25"])
    }

    @Test("A source with no clip time says nothing, and the page starts as it always has")
    func noTimeNoCall() {
        let page = RecordingPage()
        _ = ZoomTransitionController(source: TimedSource(time: nil), destination: page)
        #expect(page.calls == ["willBegin"])
    }

    @Test("A controller that only ever dismisses starts nothing")
    func aDismissOnlyControllerStartsNothing() {
        let page = RecordingPage()
        _ = ZoomTransitionController(source: TimedSource(time: 3.25), destination: page, presents: false)
        #expect(page.calls.isEmpty)
    }
}

private final class TimedSource: NSObject, ZoomTransitionSource {
    let time: TimeInterval?
    init(time: TimeInterval?) { self.time = time }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { CGRect(x: 10, y: 10, width: 80, height: 80) }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { PlainCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
    var zoomFlightMediaTime: TimeInterval? { time }
}

private final class PlainCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class RecordingPage: UIViewController, ZoomTransitionDestination {
    private(set) var calls: [String] = []
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
    func zoomTransitionWillBegin(flyingLivePlayer: Bool) { calls.append("willBegin") }
    func zoomTransitionWillStartMedia(at seconds: TimeInterval) {
        calls.append(String(format: "startMedia %.2f", seconds))
    }
}
