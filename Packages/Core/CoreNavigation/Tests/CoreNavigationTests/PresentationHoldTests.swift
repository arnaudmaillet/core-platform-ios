import Foundation
import Testing
import UIKit
@testable import CoreNavigation

/// `PresentationHold`: a push waits for its destination's settled first frame,
/// never past a ceiling, and presents exactly once.
@MainActor
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
        let hold = PresentationHold.begin(destination, ceiling: 5) { release, _ in releases.append(release) }
        #expect(releases.isEmpty, "presented before the destination was ready")
        #expect(hold.isPending)

        destination.becomeReady()

        #expect(releases == [.ready])
        #expect(!hold.isPending)
    }

    /// ⚠️ THE CEILING IS THE CONTRACT: a destination that never answers is
    /// pushed as it is, and a late answer does not push it a second time.
    @Test func theCeilingPresentsOnceAndALateAnswerIsIgnored() async {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        PresentationHold.begin(destination, ceiling: 0.05) { release, _ in releases.append(release) }

        for _ in 0..<100 where releases.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        destination.becomeReady()

        #expect(releases == [.ceiling])
    }

    /// Superseded — the viewer asked for something else — means never.
    @Test func aCancelledHoldNeverPresents() async {
        let destination = Destination()
        var releases: [PresentationHold.Release] = []
        let hold = PresentationHold.begin(destination, ceiling: 0.05) { release, _ in releases.append(release) }

        hold.cancel()
        destination.becomeReady()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(releases.isEmpty)
    }
}
