import LaunchArguments

/// The launch arguments Settings reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let storageClearAll = LaunchArgument("-storage-clear-all")
    static let supervisionOpen = LaunchArgument("-supervision-open")
}
