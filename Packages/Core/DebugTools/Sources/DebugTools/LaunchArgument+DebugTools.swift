import LaunchArguments

#if DEBUG
/// The launch arguments DebugTools reads (#2374): declared here, read
/// through `isPassed` or `value`, never as raw strings.
extension LaunchArgument {
    static let accessoryCollapseProbe = LaunchArgument("-accessory-collapse-probe")
    static let animationAudit = LaunchArgument("-animation-audit")
    static let debugDashboard = LaunchArgument("-debug-dashboard")
    static let dockTrace = LaunchArgument("-dock-trace")
    static let firstLayoutTrace = LaunchArgument("-first-layout-trace")
    static let firstLayoutTraceSelftest = LaunchArgument("-first-layout-trace-selftest")
    static let headerBarTree = LaunchArgument("-header-bar-tree")
    static let heroAudit = LaunchArgument("-hero-audit")
    static let latencyBench = LaunchArgument("-latency-bench")
    static let latencyBenchAuto = LaunchArgument("-latency-bench-auto")
    static let latencyBenchAutoOff = LaunchArgument("-latency-bench-auto-off")
    static let latencyBenchTools = LaunchArgument("-latency-bench-tools")
    static let latencyBenchToolsOff = LaunchArgument("-latency-bench-tools-off")
    static let lensLab = LaunchArgument("-lens-lab")
    static let lensLabDump = LaunchArgument("-lens-lab-dump")
    static let pillDragDemo = LaunchArgument("-pill-drag-demo")
    static let pillDragProbe = LaunchArgument("-pill-drag-probe")
    static let statusBarBlurAudit = LaunchArgument("-status-bar-blur-audit")
    static let statusBarBlurAuditDeep = LaunchArgument("-status-bar-blur-audit-deep")
    static let topFadeLab = LaunchArgument("-top-fade-lab")
    static let topFadeLabDark = LaunchArgument("-top-fade-lab-dark")
}
#endif
