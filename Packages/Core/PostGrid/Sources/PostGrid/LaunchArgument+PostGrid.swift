import LaunchArguments

/// The launch arguments PostGrid reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let avsbdlLog = LaunchArgument("-avsbdl-log")
    static let carouselAudit = LaunchArgument("-carousel-audit")
    static let embedCatalog = LaunchArgument("-embed-catalog")
    static let glassPlayMark = LaunchArgument("-glass-play-mark")
    static let gridBitrateCap = LaunchArgument("-grid-bitrate-cap")
    static let gridPlaybackLog = LaunchArgument("-grid-playback-log")
    static let liveBackdropLog = LaunchArgument("-live-backdrop-log")
    static let textRevealLog = LaunchArgument("-text-reveal-log")
    /// One line per stake, refusal and undo (`StakeSession`), on every surface.
    static let walletLog = LaunchArgument("-wallet-log")
    static let zoomLiveLog = LaunchArgument("-zoom-live-log")
}
