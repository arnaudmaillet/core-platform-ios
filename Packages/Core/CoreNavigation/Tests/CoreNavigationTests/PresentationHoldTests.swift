import Foundation
import Testing
import UIKit
@testable import CoreNavigation

/// `PresentationHold`: a push waits for its destination's settled first frame,
/// never past a ceiling, and presents exactly once.
///
/// No test here asserts a duration, and only one runs a real timer — the one
/// whose subject IS the timer, and it asserts the outcome alone. The rest use
/// a `.manual` ceiling, so a starved runner cannot reorder anything.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct PresentationHoldTests {
    /// A destination that answers when told to — or never.
    private final class Destination: UIViewController, PresentationReadying {
        var readyAtOnce = false
        private(set) var asked = 0
        private var ready: (@MainActor () -> Void)?

        func prepareForPresentation(ready: @escaping @MainActor () -> Void) {
            asked += 1
            if readyAtOnce { ready() } else { self.ready = ready }
        }

        func becomeReady() { ready?() }
    }

    /// Every screen that does not take part is pushed exactly as before: in
    /// the same turn, unasked.
    @Test func aScreenThatCannotSayIsPresentedAtOnce() {
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(UIViewController()) { release, _ in releases.append(release) }
        #expect(releases == [.ready])
        #expect(!hold.isPending)
    }

    /// A warm destination costs no wait at all: the push starts on the tap.
    @Test func aDestinationReadyAtOnceIsPresentedInTheSameTurn() {
        let destination = Destination()
        destination.readyAtOnce = true
        var releases: [PresentationHold.Release] = []
        PresentationHold.begin(destination) { release, _ in releases.append(release) }
        #expect(releases == [.ready])
        #expect(destination.asked == 1)
    }

    @Test func aDestinationIsPresentedWhenItSaysSo() async {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(destination, ceiling: .manual) { release, _ in releases.append(release) }
        #expect(releases.isEmpty, "presented before the destination was ready")
        #expect(hold.isPending)

        destination.becomeReady()

        #expect(releases == [.ready])
        #expect(!hold.isPending)
    }

    /// ⚠️ THE CEILING IS THE CONTRACT: a destination that never answers is
    /// pushed as it is, and a late answer does not push it a second time.
    @Test func theCeilingPresentsOnceAndALateAnswerIsIgnored() {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(destination, ceiling: .manual) { release, _ in releases.append(release) }

        hold.releaseAtCeiling()
        destination.becomeReady()
        hold.releaseAtCeiling()

        #expect(releases == [.ceiling])
    }

    /// The product's ceiling is a real timer, and it does fire on its own.
    /// Outcome only: how late it fires on a loaded runner is not the question.
    @Test func aTimedCeilingFiresWithoutBeingAsked() async {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        PresentationHold.begin(destination, ceiling: .after(0.01)) { release, _ in releases.append(release) }

        while releases.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(releases == [.ceiling])
    }

    /// Superseded — the viewer asked for something else — means never, by
    /// readiness or by ceiling.
    @Test func aCancelledHoldNeverPresents() {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(destination, ceiling: .manual) { release, _ in releases.append(release) }

        hold.cancel()
        destination.becomeReady()
        hold.releaseAtCeiling()

        #expect(releases.isEmpty)
    }
}
