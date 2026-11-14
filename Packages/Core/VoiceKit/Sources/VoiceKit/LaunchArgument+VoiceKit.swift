import LaunchArguments

/// The launch arguments VoiceKit reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let voiceLab = LaunchArgument("-voice-lab")
}
