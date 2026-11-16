import LaunchArguments

/// The launch arguments PostSurfaces reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let authorBadgeTrace = LaunchArgument("-author-badge-trace")
    static let foryouSegmentsLog = LaunchArgument("-foryou-segments-log")
    static let foryouVisibilityLog = LaunchArgument("-foryou-visibility-log")
    static let galleryTileInfoLog = LaunchArgument("-gallery-tile-info-log")
    static let gridPlaybackLog = LaunchArgument("-grid-playback-log")
    static let listJumpTrace = LaunchArgument("-list-jump-trace")
    static let listJumpUnpinned = LaunchArgument("-list-jump-unpinned")
    static let pillNoFace = LaunchArgument("-pill-no-face")
    static let pillProbe = LaunchArgument("-pill-probe")
    static let previewLaunchLog = LaunchArgument("-preview-launch-log")
    static let previewLaunchMiss = LaunchArgument("-preview-launch-miss")
    static let scrollStopTrace = LaunchArgument("-scroll-stop-trace")
    static let textRevealLog = LaunchArgument("-text-reveal-log")
    static let warmLog = LaunchArgument("-warm-log")
    static let zoomBlendLog = LaunchArgument("-zoom-blend-log")
    static let zoomLiveLog = LaunchArgument("-zoom-live-log")
}
