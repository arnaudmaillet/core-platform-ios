import LaunchArguments

/// The launch arguments ThreadKit reads (#2374, #2380): declared here, read
/// through `isPassed` or `value`, never as raw strings. The composer's QA
/// switches, which moved here with it.
extension LaunchArgument {
    static let composerDraft = LaunchArgument("-composer-draft")
    static let composerDraftKeep = LaunchArgument("-composer-draft-keep")
    static let composerKeyboardQa = LaunchArgument("-composer-keyboard-qa")
    static let emoteKeyboardQa = LaunchArgument("-emote-keyboard-qa")
    static let gestureLog = LaunchArgument("-gesture-log")
}
