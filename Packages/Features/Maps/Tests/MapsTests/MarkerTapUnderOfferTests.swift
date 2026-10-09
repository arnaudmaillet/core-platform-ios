import Testing
@testable import Maps

/// A marker tap while a locked country's unlock offer is open closes the
/// offer and opens nothing (#686) — as a tap on the map does.
@MainActor
struct MarkerTapUnderOfferTests {
    @Test func anOpenOfferSwallowsTheMarkerTap() {
        #expect(MapsViewController.markerTapClosesOffer(offerOpen: true))
    }

    @Test func withNoOfferTheMarkerOpensAsBefore() {
        #expect(!MapsViewController.markerTapClosesOffer(offerOpen: false))
    }
}
