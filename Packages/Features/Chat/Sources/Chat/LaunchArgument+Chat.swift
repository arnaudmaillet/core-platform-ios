import LaunchArguments

/// The launch arguments Chat reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let chatPinDemo = LaunchArgument("-chat-pin-demo")
    static let chatPreviewDemo = LaunchArgument("-chat-preview-demo")
    /// `-inbox-badges 0,43,150` (#2411): the counts the selector's segments
    /// wear, in order, whatever the pages publish — the width captures.
    static let inboxBadges = LaunchArgument("-inbox-badges")
    static let inboxMockNewActivity = LaunchArgument("-inbox-mock-new-activity")
    static let inboxPageTo = LaunchArgument("-inbox-page-to")
    static let inboxRecentsTrace = LaunchArgument("-inbox-recents-trace")
    static let inboxSearchCancel = LaunchArgument("-inbox-search-cancel")
    static let inboxSearchOpen = LaunchArgument("-inbox-search-open")
    static let inboxSearchQuery = LaunchArgument("-inbox-search-query")
    static let inboxSelectorTrace = LaunchArgument("-inbox-selector-trace")
    /// `-new-message-open` (#2411): the compose item's sheet, opened ~1.5 s
    /// in, by the same path a tap takes.
    static let newMessageOpen = LaunchArgument("-new-message-open")
    static let newMessagePageSize = LaunchArgument("-new-message-page-size")
    /// `-new-message-query <text>` (#2411): the sheet's field seeded with
    /// `text` once it is open — the keyboard is not scriptable.
    static let newMessageQuery = LaunchArgument("-new-message-query")
    static let tabbarShapeWatch = LaunchArgument("-tabbar-shape-watch")
}
