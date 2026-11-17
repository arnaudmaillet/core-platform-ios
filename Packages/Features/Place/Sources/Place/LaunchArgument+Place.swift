import LaunchArguments

/// The launch arguments the place page reads (#2374, #2381): declared here,
/// read through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let grabLog = LaunchArgument("-grab-log")
    static let mapsPlaceOpenTile = LaunchArgument("-maps-place-open-tile")
    static let mapsPlacePopDemo = LaunchArgument("-maps-place-pop-demo")
    static let mapsPlaceScroll = LaunchArgument("-maps-place-scroll")
    static let mapsPlaceTileDismiss = LaunchArgument("-maps-place-tile-dismiss")
    static let mapsPlaceTileDismissVertical = LaunchArgument("-maps-place-tile-dismiss-vertical")
    static let placeGrabDemo = LaunchArgument("-place-grab-demo")
    static let placeInkAudit = LaunchArgument("-place-ink-audit")
    static let placePullRefresh = LaunchArgument("-place-pull-refresh")
    static let placeScrollSweep = LaunchArgument("-place-scroll-sweep")
    static let placeStretchSweep = LaunchArgument("-place-stretch-sweep")
}
