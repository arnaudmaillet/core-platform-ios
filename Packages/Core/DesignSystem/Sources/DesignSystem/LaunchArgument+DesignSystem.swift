import LaunchArguments

/// The launch arguments DesignSystem reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let barTouchAudit = LaunchArgument("-bar-touch-audit")
    static let foryouBackdropOff = LaunchArgument("-foryou-backdrop-off")
    static let hapticsLog = LaunchArgument("-haptics-log")
    static let heroBlurMaterial = LaunchArgument("-hero-blur-material")
    static let heroBlurTrace = LaunchArgument("-hero-blur-trace")
    static let lensTrace = LaunchArgument("-lens-trace")
    static let sectionTitleAudit = LaunchArgument("-section-title-audit")
    static let tabbarShapeTrace = LaunchArgument("-tabbar-shape-trace")
}
