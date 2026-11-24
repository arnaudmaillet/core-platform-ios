import LaunchArguments

/// The launch arguments MediaPlaybackFixtures reads (#2374, #2516): declared
/// here, read through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let richMedia = LaunchArgument("-rich-media")
}
