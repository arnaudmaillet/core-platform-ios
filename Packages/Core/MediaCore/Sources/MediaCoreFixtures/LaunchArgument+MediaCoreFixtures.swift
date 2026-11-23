import LaunchArguments

/// The launch arguments MediaCoreFixtures reads (#2374, #2516): declared
/// here, read through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let slowMedia = LaunchArgument("-slow-media")
}
