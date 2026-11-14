import LaunchArguments

/// The launch arguments Upload reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let cameraLogFrames = LaunchArgument("-camera-log-frames")
    static let cameraScript = LaunchArgument("-camera-script")
    static let cameraSimulated = LaunchArgument("-camera-simulated")
    static let richMedia = LaunchArgument("-rich-media")
    static let timelineProbe = LaunchArgument("-timeline-probe")
    static let uploadAccess = LaunchArgument("-upload-access")
    static let uploadBenchDrag = LaunchArgument("-upload-bench-drag")
    static let uploadBenchSlides = LaunchArgument("-upload-bench-slides")
    static let uploadEdit = LaunchArgument("-upload-edit")
    static let uploadEditReturn = LaunchArgument("-upload-edit-return")
    static let uploadFakeLatency = LaunchArgument("-upload-fake-latency")
    static let uploadFakeLibrary = LaunchArgument("-upload-fake-library")
    static let uploadLogSheet = LaunchArgument("-upload-log-sheet")
    static let uploadNoReveal = LaunchArgument("-upload-no-reveal")
    static let uploadPost = LaunchArgument("-upload-post")
    static let uploadPublish = LaunchArgument("-upload-publish")
    static let uploadSaveToPhotos = LaunchArgument("-upload-save-to-photos")
    static let uploadSeedReverse = LaunchArgument("-upload-seed-reverse")
}
