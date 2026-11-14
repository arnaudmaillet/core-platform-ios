import LaunchArguments

/// The launch arguments VoiceKitUI reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let voiceCatalog = LaunchArgument("-voice-catalog")
}
