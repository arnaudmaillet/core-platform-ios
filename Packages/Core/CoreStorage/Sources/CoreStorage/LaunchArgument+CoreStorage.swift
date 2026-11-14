import LaunchArguments

/// The launch arguments CoreStorage reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let countriesReset = LaunchArgument("-countries-reset")
    static let profileItemsReset = LaunchArgument("-profile-items-reset")
    static let resetBookmarks = LaunchArgument("-reset-bookmarks")
    static let resetRecentSearches = LaunchArgument("-reset-recent-searches")
    static let resetViewHistory = LaunchArgument("-reset-view-history")
    static let seedBookmarks = LaunchArgument("-seed-bookmarks")
    static let seedRecentSearches = LaunchArgument("-seed-recent-searches")
    static let walletBalance = LaunchArgument("-wallet-balance")
    static let walletClaimReady = LaunchArgument("-wallet-claim-ready")
    static let walletGems = LaunchArgument("-wallet-gems")
    static let walletReset = LaunchArgument("-wallet-reset")
    static let walletStakeShots = LaunchArgument("-wallet-stake-shots")
    static let walletStreak = LaunchArgument("-wallet-streak")
    static let welcomeGiftReset = LaunchArgument("-welcome-gift-reset")
}
