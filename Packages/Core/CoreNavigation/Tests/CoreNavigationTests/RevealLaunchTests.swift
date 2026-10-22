import Testing
import UIKit
@testable import CoreNavigation

/// ⚠️ A WINDOW OPENS OUT OF THE LIFT THE VIEWER TAPPED (#1543): a long press's
/// preview of a text card or a friend's face, which is not its source's shape.
/// The opening takes the lift's frame, corner, still and fit, aligns nothing
/// and borrows nothing; everything the CLOSE reads stays the source's.
@MainActor
struct RevealLaunchTests {
    private static let row = CGRect(x: 16, y: 400, width: 370, height: 190)
    private static let lift = CGRect(x: 16, y: 78, width: 370, height: 252)

    private func geometry(launch: RevealLaunch?, still: UIView? = nil) -> RevealGeometry {
        RevealGeometry(
            sourceFrame: { _ in Self.row },
            sourceCornerRadius: 26,
            sourceCornerCurve: .circular,
            sourceCaptionEnd: 120,
            sourceCaptionTop: 52,
            makeDismissStandIn: { still },
            matchesAnchor: true,
            pageFit: .clipped,
            launch: { launch }
        )
    }

    @Test func withoutALiftTheOpeningIsTheSources() {
        let opening = geometry(launch: nil).opening()
        #expect(opening.sourceFrame(UIView()) == Self.row)
        #expect(opening.sourceCornerRadius == 26)
        #expect(opening.sourceCaptionEnd == 120)
        #expect(opening.sourceCaptionTop == 52)
        #expect(opening.matchesAnchor)
        #expect(opening.pageFit == .clipped)
    }

    @Test(arguments: [RevealPageFit.clipped, .covering])
    func aLiftIsTheOpeningsSource(fit: RevealPageFit) {
        let still = UIView()
        let launch = RevealLaunch(
            frame: { _ in Self.lift }, cornerRadius: 22, pageFit: fit, makeStandIn: { still }
        )
        let source = geometry(launch: launch, still: UIView())
        let opening = source.opening()
        #expect(opening.sourceFrame(UIView()) == Self.lift, "the window opened out of the card, not the lift")
        #expect(opening.sourceCornerRadius == 22)
        #expect(opening.sourceCornerCurve == .continuous)
        #expect(opening.makePresentStandIn() === still)
        #expect(opening.pageFit == fit)
        // A lift is not the card: nothing is aligned to it, nothing veiled
        // under it, no band borrowed from it.
        #expect(opening.matchesAnchor == false)
        #expect(opening.sourceCaptionEnd == nil)
        #expect(opening.sourceCaptionTop == 0)
        // The close is the source's, and asks no lift.
        #expect(source.sourceFrame(UIView()) == Self.row)
        #expect(opening.makeDismissStandIn() === source.makeDismissStandIn())
        #expect(opening.launch() == nil)
    }

    @Test func aLiftThatHasGoneFallsBackToTheSource() {
        let launch = RevealLaunch(frame: { _ in nil }, cornerRadius: 22, makeStandIn: { nil })
        #expect(geometry(launch: launch).opening().sourceFrame(UIView()) == Self.row)
    }
}
