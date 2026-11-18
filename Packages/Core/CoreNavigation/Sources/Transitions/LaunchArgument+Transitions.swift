import LaunchArguments

/// The launch arguments the transition engine reads (#2374, #2384): declared
/// here, read through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let barDump = LaunchArgument("-bar-dump")
    static let grabFrames = LaunchArgument("-grab-frames")
    static let grabGeometry = LaunchArgument("-grab-geometry")
    static let grabLog = LaunchArgument("-grab-log")
    static let heroReduceMotion = LaunchArgument("-hero-reduce-motion")
    static let textRevealLog = LaunchArgument("-text-reveal-log")
    static let zoomDemoGrabVertical = LaunchArgument("-zoom-demo-grab-vertical")
    static let zoomInterrupt = LaunchArgument("-zoom-interrupt")
    static let zoomLiveLog = LaunchArgument("-zoom-live-log")
    static let zoomProbe = LaunchArgument("-zoom-probe")
    static let zoomProfile = LaunchArgument("-zoom-profile")
}
