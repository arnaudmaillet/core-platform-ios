import LaunchArguments

/// The launch arguments MediaPlayback reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let avplayerRender = LaunchArgument("-avplayer-render")
    static let avsbdlLog = LaunchArgument("-avsbdl-log")
    static let cacheAudit = LaunchArgument("-cache-audit")
    static let carouselAudit = LaunchArgument("-carousel-audit")
    static let composedProbe = LaunchArgument("-composed-probe")
    static let posterLog = LaunchArgument("-poster-log")
    static let richMedia = LaunchArgument("-rich-media")
    static let soundLog = LaunchArgument("-sound-log")
    static let zoomLiveLog = LaunchArgument("-zoom-live-log")
}
