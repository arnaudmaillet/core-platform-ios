import LaunchArguments

/// The launch arguments Auth reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let loginDemoPhone = LaunchArgument("-login-demo-phone")
    static let loginDemoSignup = LaunchArgument("-login-demo-signup")
    static let loginLandscape = LaunchArgument("-login-landscape")
    static let loginLayoutAudit = LaunchArgument("-login-layout-audit")
    static let sheetFitTrace = LaunchArgument("-sheet-fit-trace")
}
