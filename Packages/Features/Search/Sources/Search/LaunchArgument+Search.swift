import LaunchArguments

/// The launch arguments Search reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let searchFiltersOpen = LaunchArgument("-search-filters-open")
    static let searchGestureAudit = LaunchArgument("-search-gesture-audit")
    static let searchLayoutAudit = LaunchArgument("-search-layout-audit")
    static let searchLayoutTrace = LaunchArgument("-search-layout-trace")
    static let searchNavTrace = LaunchArgument("-search-nav-trace")
    static let searchNoGestureGate = LaunchArgument("-search-no-gesture-gate")
    static let searchQuery = LaunchArgument("-search-query")
    static let searchRefineCycle = LaunchArgument("-search-refine-cycle")
    static let searchResultsTab = LaunchArgument("-search-results-tab")
    static let searchScope = LaunchArgument("-search-scope")
    static let searchSort = LaunchArgument("-search-sort")
    static let searchSubmit = LaunchArgument("-search-submit")
    static let searchTapQuery = LaunchArgument("-search-tap-query")
    static let searchTapUser = LaunchArgument("-search-tap-user")
}
