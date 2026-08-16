import UIKit

/// The marker ring's hierarchy palette: a cluster's border says AT A GLANCE
/// which depth it speaks for — blue for a city, purple for a region, amber
/// for a country — while generic markers (proximity clusters, single pins)
/// keep the neutral ring they have always had. Semantic rings are a point
/// wider than neutral ones, so the depth reads even where a color is
/// ambiguous against the map beneath.
///
/// Pure mapping, separate from the views, so the palette is unit-testable
/// and pin, cluster and flight card all resolve one table (the flying card
/// must take off wearing the marker's exact ring — see `MapPinZoomSource`).
enum MapMarkerRing {
    /// The ring every marker wore before hierarchy levels existed, and what
    /// generic markers keep: `PinCardView`'s own width and background color.
    static let neutralWidth: CGFloat = PinCardView.ringWidth
    /// Semantic clusters wear a slightly heavier ring — depth should read
    /// even at a glance and in whatever the map renders beneath the marker.
    static let hierarchyWidth: CGFloat = 3

    /// Amber, tuned per appearance: deep enough to hold contrast against the
    /// light map's parchment tones, brightened toward gold in dark mode so it
    /// doesn't sink into a dark map. (`systemYellow` washes out on the light
    /// map, which is why this one is bespoke.)
    static let amber = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.78, blue: 0.24, alpha: 1)
            : UIColor(red: 0.80, green: 0.58, blue: 0.00, alpha: 1)
    }

    static func color(for kind: MapPlace.Kind?) -> UIColor {
        switch kind {
        case .city: .systemBlue
        case .region: .systemPurple
        case .country: amber
        case nil: .systemBackground
        }
    }

    static func width(for kind: MapPlace.Kind?) -> CGFloat {
        kind == nil ? neutralWidth : hierarchyWidth
    }
}
