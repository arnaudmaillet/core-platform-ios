import Testing
import UIKit
@testable import Profile

/// Which touches the floating header keeps, and which it lets past.
///
/// The header sits OVER the pages, so this decision is the difference between a
/// profile that scrolls from anywhere and one that scrolls from everywhere
/// except the part of the screen a thumb naturally rests on. Both failures are
/// invisible in a screenshot and neither breaks a build: too greedy and drags
/// die silently on the avatar, too generous and the buttons stop working.
@MainActor
struct ScrollPassthroughTests {
    /// A header-shaped hierarchy: a passthrough host, a plain container inside
    /// it, and one button and one label inside that.
    private func makeHost() -> (host: ScrollPassthroughView, button: UIButton, label: UILabel) {
        let host = ScrollPassthroughView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let container = UIView(frame: host.bounds)
        host.addSubview(container)

        let button = UIButton(frame: CGRect(x: 10, y: 10, width: 100, height: 44))
        container.addSubview(button)

        let label = UILabel(frame: CGRect(x: 10, y: 100, width: 300, height: 40))
        label.text = "Street photography, mostly Lyon."
        container.addSubview(label)

        return (host, button, label)
    }

    /// ⚠️ The bug, stated: a drag starting on the bio has to reach the scroll
    /// view underneath. A label carries no interaction of its own, so UIKit
    /// hands the touch to its container — and a container that keeps it is a
    /// container that eats the gesture.
    @Test func aTouchOnPlainTextFallsThrough() {
        let (host, _, label) = makeHost()
        #expect(host.hitTest(CGPoint(x: label.frame.midX, y: label.frame.midY), with: nil) == nil)
    }

    /// The same for the empty space around everything — most of this header is
    /// margin, and margin is where a thumb lands.
    @Test func aTouchOnEmptySpaceFallsThrough() {
        let (host, _, _) = makeHost()
        #expect(host.hitTest(CGPoint(x: 350, y: 250), with: nil) == nil)
    }

    /// ⚠️ And the other half: the controls keep working. Passing everything
    /// through is as wrong as keeping everything, and it is the failure a
    /// scroll-through fix invites.
    @Test func aTouchOnAButtonIsKept() {
        let (host, button, _) = makeHost()
        let hit = host.hitTest(CGPoint(x: button.frame.midX, y: button.frame.midY), with: nil)
        #expect(hit === button)
    }

    /// A control nested deeper than one level is still a control — the counters
    /// sit inside a row inside a column inside the header.
    @Test func aDeeplyNestedControlIsKept() {
        let host = ScrollPassthroughView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let column = UIView(frame: host.bounds)
        host.addSubview(column)
        let row = UIView(frame: host.bounds)
        column.addSubview(row)
        let stat = UIControl(frame: CGRect(x: 20, y: 20, width: 60, height: 50))
        row.addSubview(stat)

        #expect(host.hitTest(CGPoint(x: 40, y: 40), with: nil) === stat)
    }

    /// A subview that reads touches through a gesture recognizer rather than by
    /// being a control keeps them too — the selector's capsule is grabbable that
    /// way, and it lives in this same host.
    @Test func aViewWithAGestureRecognizerIsKept() {
        let host = ScrollPassthroughView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let grabbable = UIView(frame: CGRect(x: 0, y: 200, width: 400, height: 60))
        grabbable.addGestureRecognizer(UIPanGestureRecognizer())
        host.addSubview(grabbable)

        #expect(host.hitTest(CGPoint(x: 200, y: 230), with: nil) === grabbable)
    }

    /// Outside its bounds it was never in the running, and must not start
    /// answering for touches that were not its to judge.
    @Test func aTouchOutsideTheHostIsNotItsToJudge() {
        let (host, _, _) = makeHost()
        #expect(host.hitTest(CGPoint(x: 500, y: 500), with: nil) == nil)
    }

    /// A hidden or fully faded control is not a control a viewer can reach, and
    /// UIKit skips it — so the touch belongs to the scroll beneath, which is
    /// what the fade relies on once the header is on its way out.
    @Test func aFadedControlDoesNotHoldOntoTouches() {
        let (host, button, _) = makeHost()
        button.alpha = 0
        #expect(host.hitTest(CGPoint(x: button.frame.midX, y: button.frame.midY), with: nil) == nil)
    }
}
