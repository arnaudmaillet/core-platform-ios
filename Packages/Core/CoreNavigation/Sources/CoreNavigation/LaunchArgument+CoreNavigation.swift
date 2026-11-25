import LaunchArguments

/// The launch arguments CoreNavigation reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings. The transitions' and
/// the instrumentation's are declared in their own targets (#2384).
extension LaunchArgument {
    static let drawerTrace = LaunchArgument("-drawer-trace")
    /// The three places in one bubble, Profile no longer apart (#2489,
    /// `ShellTabs.Layout.grouped`). Read once, at launch.
    static let tabBarGrouped = LaunchArgument("-tabbar-grouped")
}
