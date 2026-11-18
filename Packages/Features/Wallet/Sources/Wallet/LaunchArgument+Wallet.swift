import LaunchArguments

/// The launch arguments the wallet reads (#2374, #2385): declared here, read
/// through `isPassed` or `value`, never as raw strings. `-switch-tab` is the
/// app's too: the badge waits for the tab it selects. `nonisolated`: the
/// target is MainActor by default, and a flag is read from any context.
extension LaunchArgument {
    nonisolated static let openWallet = LaunchArgument("-open-wallet")
    nonisolated static let switchTab = LaunchArgument("-switch-tab")
    nonisolated static let walletDemoClaim = LaunchArgument("-wallet-demo-claim")
    nonisolated static let walletOpenActivity = LaunchArgument("-wallet-open-activity")
    nonisolated static let walletOpenShop = LaunchArgument("-wallet-open-shop")
    nonisolated static let walletOpenStake = LaunchArgument("-wallet-open-stake")
    nonisolated static let walletOpenStakes = LaunchArgument("-wallet-open-stakes")
    nonisolated static let walletSheetLarge = LaunchArgument("-wallet-sheet-large")
    nonisolated static let walletSheetScroll = LaunchArgument("-wallet-sheet-scroll")
}
