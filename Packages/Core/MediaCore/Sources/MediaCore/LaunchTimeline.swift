import Darwin
import Foundation
import LaunchArguments
import os

/// How long after the process started a launch milestone was reached (#1765):
/// the scene, the first auth state, the shell, the curtain's lift — what "the
/// launch is instant" is measured by, cold and warm.
///
/// Each milestone is recorded once per process, and logged (`os.Logger`,
/// category `launch`, any build — how a Release run is measured); `-launch-log`
/// also prints them (DEBUG), as `[launch] <name> +<seconds>s`.
public enum LaunchTimeline {
    /// The process's start, from the kernel (`sysctl`, a public interface):
    /// earlier than anything the app's own code can stamp.
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "launch")
    private static let reached = NSLock()
    nonisolated(unsafe) private static var marks: [String: TimeInterval] = [:]
    nonisolated(unsafe) private static var waiters: [String: [@MainActor @Sendable () -> Void]] = [:]

    /// Seconds since the process started; nil if the kernel would not say.
    public static func sinceProcessStart() -> TimeInterval? {
        processStart.map { Date().timeIntervalSince($0) }
    }

    /// Records `milestone` the first time it is reached in this process.
    public static func mark(_ milestone: String) {
        guard let elapsed = sinceProcessStart() else { return }
        let (isFirst, waiting) = reached.withLock { () -> (Bool, [@MainActor @Sendable () -> Void]) in
            guard marks[milestone] == nil else { return (false, []) }
            marks[milestone] = elapsed
            return (true, waiters.removeValue(forKey: milestone) ?? [])
        }
        guard isFirst else { return }
        for handler in waiting {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        }
        logger.info("\(milestone, privacy: .public) +\(elapsed, format: .fixed(precision: 3), privacy: .public)s")
        #if DEBUG
        if LaunchArgument.launchLog.isPassed() {
            print(String(format: "[launch] %@ +%.3fs", milestone, elapsed))
        }
        #endif
    }

    /// When `milestone` was reached, in seconds since the process started.
    public static func time(of milestone: String) -> TimeInterval? {
        reached.withLock { marks[milestone] }
    }

    /// Calls `handler` on the main actor once `milestone` is reached — on the
    /// next turn if it already was.
    public static func whenReached(_ milestone: String, _ handler: @escaping @MainActor @Sendable () -> Void) {
        let already = reached.withLock { () -> Bool in
            guard marks[milestone] == nil else { return true }
            waiters[milestone, default: []].append(handler)
            return false
        }
        if already { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
    }
}
