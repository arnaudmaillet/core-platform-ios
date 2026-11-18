import LaunchArguments

/// The launch arguments the instrumentation reads (#2374, #2384): declared
/// here, read through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let interactionLatency = LaunchArgument("-interaction-latency")
    static let interactionLatencyHud = LaunchArgument("-interaction-latency-hud")
}
