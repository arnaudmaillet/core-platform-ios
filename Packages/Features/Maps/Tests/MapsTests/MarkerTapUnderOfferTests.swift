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

    /// ⚠️ FROM ONE LOCKED COUNTRY STRAIGHT TO ANOTHER (#760): under an open
    /// offer, another locked country's teaser moves the offer to it; its own
    /// teaser leaves it be; any other marker still closes it (#686).
    @Test func aTeaserUnderAnOfferSwitchesItsCountry() {
        #expect(MapsViewController.tapUnderOffer(teaserCountry: "FI", offeredCountry: "NO") == .switchTo("FI"))
        #expect(MapsViewController.tapUnderOffer(teaserCountry: "NO", offeredCountry: "NO") == .keep)
        #expect(MapsViewController.tapUnderOffer(teaserCountry: nil, offeredCountry: "NO") == .close)
    }

    /// MapKit's selection, ~0.3 s after the instant tap, is its echo, not a
    /// second tap: it closed the offer the tap had just opened (#760).
    @Test func mapKitsSelectionRightAfterTheInstantTapIsAnEcho() {
        #expect(MapsViewController.isSelectionEcho(tappedAt: 10, now: 10.35))
        #expect(!MapsViewController.isSelectionEcho(tappedAt: 10, now: 11.5))
    }
}
