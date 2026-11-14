import LaunchArguments

/// The launch arguments MediaCore reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let avatarPlayLog = LaunchArgument("-avatar-play-log")
    static let avatarRounds = LaunchArgument("-avatar-rounds")
    static let cacheAudit = LaunchArgument("-cache-audit")
    static let launchCap = LaunchArgument("-launch-cap")
    static let launchLog = LaunchArgument("-launch-log")
    static let slowMedia = LaunchArgument("-slow-media")
}
