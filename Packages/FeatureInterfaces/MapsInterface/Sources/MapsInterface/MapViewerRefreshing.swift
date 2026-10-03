import UIKit

/// A map screen whose content depends on who is looking — the favourites dock
/// and the Friends / Following rows are the viewer's people. The shell calls it
/// when the viewer signs in or out (guest mode), because the Explore stack is
/// not rebuilt for that. Adopted by the view controller
/// `MapsFeatureBuilding.makeMapViewController()` returns.
@MainActor
public protocol MapViewerRefreshing: AnyObject {
    func viewerDidChange()
}
