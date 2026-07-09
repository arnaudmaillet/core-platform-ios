import UIKit

/// Entry point contract for the Maps feature. The app shell depends on this
/// interface package — never on the Maps implementation — so editing Maps
/// internals recompiles nothing but Maps itself.
///
/// Maps is a client-side product surface over the existing `geo_discovery.v1`
/// contract: the map view pans/zooms and queries lightweight pins (the Radar
/// path), and — from Step B — a pin tap opens a vertical snap feed via a custom
/// hero transition (the Focus path). This builder vends only the map surface;
/// the tap-to-feed hand-off is wired inside the feature.
@MainActor
public protocol MapsFeatureBuilding {
    /// The map surface for the Maps tab: an `MKMapView` rendering post pins in
    /// the current viewport, re-queried on pan/zoom settle.
    func makeMapViewController() -> UIViewController
}
