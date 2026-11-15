import LaunchArguments

/// The launch arguments ProfileSettings reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let storageClearAll = LaunchArgument("-storage-clear-all")
    static let supervisionOpen = LaunchArgument("-supervision-open")
}
