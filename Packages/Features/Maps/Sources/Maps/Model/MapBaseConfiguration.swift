import MapKit

/// What the map is drawn with — ONE configuration, at every zoom: the
/// standard map, flat, its points of interest excluded.
///
/// ## Why one, and never a switch
///
/// #302 swapped `preferredConfiguration` from the standard map to hybrid
/// imagery with realistic elevation past 12 000 km, to reach MapKit's 3D
/// globe. On a device that read as two different maps with a cut between
/// them (satellite imagery replacing the drawn map in one frame). It was
/// also the only code that re-created MapKit's renderer mid-session — from
/// inside `regionDidChangeAnimated`, with the clusters reconciled right
/// after — and a zoom-out there stopped on `hit program assert` (a C assert
/// inside MapKit's stack). The map is configured once, in
/// `configureMapView`, and nothing reassigns `preferredConfiguration`.
///
/// ## Why no globe
///
/// The globe Apple Plans draws in its standard style is not MapKit's to
/// give: MapKit curves only its imagery configurations into a globe. The
/// standard map stays a flat world at every elevation style (measured on
/// the iOS 27 simulator; an Apple DTS answer on the Developer Forums says
/// the same of devices — "The Apple Maps app isn't just a MapKit view").
/// So the map is the standard one everywhere, and its widest view is the
/// flat world, where MapKit clamps the camera at ~26 300 km.
///
/// Flat, not realistic: realistic elevation only matters under a pitched
/// camera (terrain, 3D landmarks), which this map is not about, and flat is
/// the look and cost the map had before #302.
///
/// ⚠️ The configuration carries its OWN point-of-interest filter: assigning
/// one without it brings back the POIs this map excludes.
enum MapBaseConfiguration {
    @MainActor
    static func make() -> MKMapConfiguration {
        let standard = MKStandardMapConfiguration(elevationStyle: .flat)
        standard.pointOfInterestFilter = .excludingAll
        return standard
    }
}
