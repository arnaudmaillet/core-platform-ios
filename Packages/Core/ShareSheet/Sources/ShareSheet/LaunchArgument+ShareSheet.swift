import LaunchArguments

/// The launch arguments ShareSheet reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let profileShareDemo = LaunchArgument("-profile-share-demo")
}
