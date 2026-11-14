import LaunchArguments

/// The launch arguments Notifications reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let notificationsShowMore = LaunchArgument("-notifications-show-more")
}
