import MapKit

/// When the map is a GLOBE, and what it is drawn with then.
///
/// ## Why the configuration changes with the zoom
///
/// MapKit draws a 3D globe only for its IMAGERY configurations
/// (`MKHybridMapConfiguration` / `MKImageryMapConfiguration` with
/// `.realistic` elevation — what replaced the `*Flyover` map types). The
/// standard map never becomes one, measured on the iOS 27 simulator at the
/// same 20 000 km camera: standard FLAT and standard REALISTIC rendered the
/// same flat Mercator world, hybrid realistic rendered the globe. (Standard
/// realistic itself works on that simulator — pitched over Paris it draws the
/// 3D Eiffel Tower — so this is the configuration's limit, not the machine's.)
///
/// So the map stays the app's standard map everywhere a person reads it, and
/// becomes hybrid (satellite imagery with labels) only once the camera is far
/// enough out that the view is a globe anyway. Hybrid rather than imagery:
/// its labels ("EUROPE", seas, capitals) carry the standard map's across the
/// switch.
///
/// ⚠️ Hybrid realistic lights the globe by the REAL sun: the night side is
/// dark, with city lights. That is MapKit's, not a bug.
///
/// ## Why two distances, and these
///
/// The switch happens at a SETTLE (`regionDidChangeAnimated`), never under a
/// finger, and changing the configuration re-renders the map. One threshold
/// would flip the style back and forth for a camera resting on it; the gap
/// between the two is the hysteresis.
///
/// Measured on the iOS 27 simulator, over Paris: the standard map clamps
/// the camera at ~26 300 km (its widest view, ~85° of longitude); 12 000 km
/// frames ~40° (Europe), where the hybrid globe's curvature is already
/// visible; 3 000 km frames ~10° (France and its neighbours). MapKit reports
/// the same camera distance and region for either configuration at a given
/// camera, so the thresholds mean the same thing in both states.
enum MapGlobe {
    /// A settled camera at least this far above its centre becomes the globe.
    static let entryDistance: CLLocationDistance = 12_000_000
    /// A globe whose camera settles closer than this goes back to the map.
    static let exitDistance: CLLocationDistance = 8_000_000

    /// Whether a settled camera at `distance` metres should show the globe,
    /// given what is on screen now.
    static func showsGlobe(atDistance distance: CLLocationDistance, showingGlobe: Bool) -> Bool {
        distance >= (showingGlobe ? exitDistance : entryDistance)
    }

    /// The configuration for either state. Both state their point-of-interest
    /// filter: a configuration carries its OWN, so assigning one without it
    /// brings the POIs back that `configureMapView` excluded.
    @MainActor
    static func configuration(globe: Bool) -> MKMapConfiguration {
        if globe {
            let hybrid = MKHybridMapConfiguration(elevationStyle: .realistic)
            hybrid.pointOfInterestFilter = .excludingAll
            return hybrid
        }
        let standard = MKStandardMapConfiguration()
        standard.pointOfInterestFilter = .excludingAll
        return standard
    }
}
