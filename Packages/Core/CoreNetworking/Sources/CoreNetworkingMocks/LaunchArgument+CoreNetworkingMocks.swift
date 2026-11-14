import LaunchArguments

/// The launch arguments CoreNetworkingMocks reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let avatarFrame = LaunchArgument("-avatar-frame")
    static let countriesNoSeed = LaunchArgument("-countries-no-seed")
    static let countriesReset = LaunchArgument("-countries-reset")
    static let mapsLogPins = LaunchArgument("-maps-log-pins")
    static let mapsLogPlacePosts = LaunchArgument("-maps-log-place-posts")
    static let mapsMockDensity = LaunchArgument("-maps-mock-density")
    static let mapsMockPitch = LaunchArgument("-maps-mock-pitch")
    static let mockAccountRestricted = LaunchArgument("-mock-account-restricted")
    static let mockAuthorizedApps = LaunchArgument("-mock-authorized-apps")
    static let mockBirthdate = LaunchArgument("-mock-birthdate")
    static let mockFollowRequests = LaunchArgument("-mock-follow-requests")
    static let mockHeldComments = LaunchArgument("-mock-held-comments")
    static let mockOffline = LaunchArgument("-mock-offline")
    static let mockPostCount = LaunchArgument("-mock-post-count")
    static let mockReportHistory = LaunchArgument("-mock-report-history")
    static let mockScreenTimeUsed = LaunchArgument("-mock-screen-time-used")
    static let mockSupervision = LaunchArgument("-mock-supervision")
    static let mockTakedown = LaunchArgument("-mock-takedown")
    static let mockTakedownAfter = LaunchArgument("-mock-takedown-after")
    static let mockTwoStep = LaunchArgument("-mock-two-step")
    static let mockVerification = LaunchArgument("-mock-verification")
    static let resetBookmarks = LaunchArgument("-reset-bookmarks")
    static let walletGems = LaunchArgument("-wallet-gems")
    static let walletReset = LaunchArgument("-wallet-reset")
}
