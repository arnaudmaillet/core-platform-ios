import MapKit
import Testing
@testable import Maps

/// The unlock offer's camera bookkeeping: where closing flies the map, and
/// when a close that came back up frames the country again.
///
/// These rules sat inside `MapsViewController`, between a sheet and a live
/// camera. Getting one wrong is a map that ends up somewhere the viewer did
/// not put it: back on the first country after a switch, or flown home after
/// the viewer panned away.
@MainActor
struct MapCountryOfferStateTests {
    private static func camera(_ distance: CLLocationDistance) -> MKMapCamera {
        let camera = MKMapCamera()
        camera.centerCoordinateDistance = distance
        return camera
    }

    @Test("Closing a fresh offer flies back to the camera it left from")
    func closingFliesHome() {
        var state = MapCountryOfferState()
        let home = Self.camera(1_000)
        state.opening(from: { home })

        state.closeRequested(returning: true)
        let flight = state.closing()

        #expect(flight === home)
        #expect(state.flewBack)
    }

    @Test("Only the first camera is kept while the offer is up")
    func theFirstCameraIsKept() {
        var state = MapCountryOfferState()
        let home = Self.camera(1_000)
        state.opening(from: { home })
        var askedAgain = false

        state.opening(from: { askedAgain = true; return Self.camera(9_000) })

        #expect(state.camera === home)
        #expect(!askedAgain, "the current camera is read only when there is none yet")
    }

    @Test("A close after the viewer moved the map stays where they took it")
    func aPanCloseStaysPut() {
        var state = MapCountryOfferState()
        state.opening(from: { Self.camera(1_000) })

        state.closeRequested(returning: false)
        let flight = state.closing()

        #expect(flight == nil)
        #expect(!state.flewBack)
    }

    @Test("A close with no remembered camera flies nowhere")
    func noCameraNoFlight() {
        var state = MapCountryOfferState()
        let flight = state.closing()

        #expect(flight == nil)
        #expect(!state.flewBack)
    }

    @Test("A cancelled close reframes the country only after the map flew back")
    func cancelledCloseReframesOnlyAfterAFlight() {
        var flown = MapCountryOfferState()
        flown.opening(from: { Self.camera(1_000) })
        _ = flown.closing()

        var stayed = MapCountryOfferState()
        stayed.opening(from: { Self.camera(1_000) })
        stayed.closeRequested(returning: false)
        _ = stayed.closing()

        let flownReframes = flown.closeCancelled()
        let stayedReframes = stayed.closeCancelled()

        #expect(flownReframes)
        #expect(!stayedReframes)
    }

    @Test("After a cancelled close the next close returns home again")
    func aCancelledCloseRearmsTheReturn() {
        var state = MapCountryOfferState()
        let home = Self.camera(1_000)
        state.opening(from: { home })
        state.closeRequested(returning: false)
        _ = state.closing()

        _ = state.closeCancelled()

        #expect(state.returns)
        #expect(!state.flewBack)
        let flight = state.closing()
        #expect(flight === home)
    }

    @Test("Once the sheet is gone nothing is remembered, and the next offer keeps its own camera")
    func closedForgetsEverything() {
        var state = MapCountryOfferState()
        state.opening(from: { Self.camera(1_000) })
        state.closeRequested(returning: false)
        _ = state.closing()

        state.closed()

        #expect(state.camera == nil)
        #expect(state.returns)
        #expect(!state.flewBack)
        let next = Self.camera(2_000)
        state.opening(from: { next })
        #expect(state.camera === next)
    }
}
