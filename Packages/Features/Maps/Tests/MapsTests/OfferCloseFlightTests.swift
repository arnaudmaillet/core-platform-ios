import MapsInterface
import Testing
import UIKit
@testable import Maps

/// Closing a locked country's offer flies the map back to where it was — and
/// the flight starts as the sheet STARTS going down, not once it has gone.
///
/// The bug: `offerDidClose` ran from the sheet's `viewDidDisappear`, so the
/// whole dismissal animation stood between "no thanks" and the first frame of
/// the camera move.
struct OfferCloseFlightTests {

    // MARK: - A dismissal UIKit drives (a tap on the map, an unlock)

    @Test func aProgrammaticDismissalClosesAtItsBeginNotItsEnd() {
        var flight = OfferCloseFlight()
        #expect(flight.dismissalBegan(interactive: false) == .close)
        #expect(flight.dismissalEnded(cancelled: false) == .none, "the completion flew a second time")
    }

    // MARK: - A swipe on the sheet

    /// The first tug below the detent begins an interactive dismissal; most
    /// snap back. The map waits for the finger to let go.
    @Test func aDragClosesWhenTheFingerLetsGoNotWhenTheSheetIsGone() {
        var flight = OfferCloseFlight()
        #expect(flight.dismissalBegan(interactive: true) == .none, "flew out on a tug that may snap back")
        #expect(flight.interactionEnded(cancelled: false) == .close)
        #expect(flight.dismissalEnded(cancelled: false) == .none, "the completion flew a second time")
    }

    @Test func aDragThatSnapsBackNeverFlies() {
        var flight = OfferCloseFlight()
        #expect(flight.dismissalBegan(interactive: true) == .none)
        #expect(flight.interactionEnded(cancelled: true) == .none)
        #expect(flight.dismissalEnded(cancelled: true) == .none, "nothing went out, nothing to restore")
    }

    /// Back up after a cancelled drag, the sheet can be swiped again — and
    /// that second swipe closes it.
    @Test func aSecondSwipeAfterACancelledOneStillCloses() {
        var flight = OfferCloseFlight()
        _ = flight.dismissalBegan(interactive: true)
        _ = flight.interactionEnded(cancelled: true)
        _ = flight.dismissalEnded(cancelled: true)
        #expect(flight.dismissalBegan(interactive: true) == .none)
        #expect(flight.interactionEnded(cancelled: false) == .close)
        #expect(flight.dismissalEnded(cancelled: false) == .none)
    }

    /// A close that went out and was then cancelled is undone: the sheet is
    /// back up, so the country is framed above it again.
    @Test func aCancelAfterTheCloseWentOutRestores() {
        var flight = OfferCloseFlight()
        #expect(flight.dismissalBegan(interactive: false) == .close)
        #expect(flight.dismissalEnded(cancelled: true) == .restore)
        // And the offer is open again: its next close flies.
        #expect(flight.dismissalBegan(interactive: false) == .close)
    }

    /// The release was never reported: close late rather than leave the map
    /// on the country with no sheet over it.
    @Test func aDragWhoseReleaseWasNeverReportedClosesAtTheEnd() {
        var flight = OfferCloseFlight()
        #expect(flight.dismissalBegan(interactive: true) == .none)
        #expect(flight.dismissalEnded(cancelled: false) == .close)
    }

    // MARK: - No double flight

    @Test func everyMomentReportedTwiceStillClosesOnce() {
        var flight = OfferCloseFlight()
        var closes = 0
        for action in [
            flight.dismissalBegan(interactive: true),
            flight.dismissalBegan(interactive: true),
            flight.interactionEnded(cancelled: false),
            flight.interactionEnded(cancelled: false),
            flight.dismissalBegan(interactive: false),
            flight.dismissalEnded(cancelled: false),
            flight.dismissalEnded(cancelled: false),
        ] where action == .close {
            closes += 1
        }
        #expect(closes == 1)
    }

    // MARK: - The sheet's wiring

    @MainActor
    private final class Recorder {
        var events: [String] = []

        func attach(to sheet: CountryUnlockSheetViewController) {
            sheet.onClosing = { [unowned self] in events.append("closing") }
            sheet.onCloseCancelled = { [unowned self] in events.append("cancelled") }
            sheet.onDismissed = { [unowned self] in events.append("dismissed") }
        }
    }

    @MainActor
    private func makeSheet() -> CountryUnlockSheetViewController {
        let spain = CountryAtlas.shared.country(code: "ES")!
        return CountryUnlockSheetViewController(country: spain, access: FakeAccess())
    }

    @MainActor
    @Test func theSheetReportsClosingAtTheReleaseAndOnlyOnce() {
        let sheet = makeSheet()
        let recorder = Recorder()
        recorder.attach(to: sheet)
        sheet.dismissalBegan(interactive: true)
        #expect(recorder.events.isEmpty)
        sheet.dismissalReleased(cancelled: false)
        #expect(recorder.events == ["closing"])
        sheet.dismissalEnded(cancelled: false)
        #expect(recorder.events == ["closing"], "the end of the animation closed again")
    }

    @MainActor
    @Test func theSheetReportsACancelledCloseAsCancelled() {
        let sheet = makeSheet()
        let recorder = Recorder()
        recorder.attach(to: sheet)
        sheet.dismissalBegan(interactive: false)
        sheet.dismissalEnded(cancelled: true)
        #expect(recorder.events == ["closing", "cancelled"])
    }

    private final class FakeAccess: CountryAccess {
        let homeCountry = "FR"
        let gems = 100
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? {
            CountryStanding(code: code, rank: 4, likes: 12_400, posts: 86, price: 50)
        }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unlocked(remainingGems: 50) }
    }
}
