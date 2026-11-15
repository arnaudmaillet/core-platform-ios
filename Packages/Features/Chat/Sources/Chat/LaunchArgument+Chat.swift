import LaunchArguments

/// The launch arguments Chat reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let chatPinDemo = LaunchArgument("-chat-pin-demo")
    static let chatPreviewDemo = LaunchArgument("-chat-preview-demo")
    static let inboxMockNewActivity = LaunchArgument("-inbox-mock-new-activity")
    static let inboxPageTo = LaunchArgument("-inbox-page-to")
    static let inboxRecentsTrace = LaunchArgument("-inbox-recents-trace")
    static let inboxSearchCancel = LaunchArgument("-inbox-search-cancel")
    static let inboxSearchOpen = LaunchArgument("-inbox-search-open")
    static let inboxSearchQuery = LaunchArgument("-inbox-search-query")
    static let inboxSelectorTrace = LaunchArgument("-inbox-selector-trace")
    static let newMessagePageSize = LaunchArgument("-new-message-page-size")
    static let tabbarShapeWatch = LaunchArgument("-tabbar-shape-watch")
}
