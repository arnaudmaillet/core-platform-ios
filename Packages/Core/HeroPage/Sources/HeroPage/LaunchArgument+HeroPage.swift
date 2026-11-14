import LaunchArguments

/// The launch arguments HeroPage reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let heroBlurTrace = LaunchArgument("-hero-blur-trace")
}
