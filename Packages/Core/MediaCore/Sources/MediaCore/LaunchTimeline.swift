import Darwin
import Foundation
import os

/// How long after the process started a launch milestone was reached (#1765):
/// the first Shots post's picture, its first video frame — what "the launch
/// screen is instant" is measured by, cold and warm.
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

    /// Seconds since the process started; nil if the kernel would not say.
    public static func sinceProcessStart() -> TimeInterval? {
        processStart.map { Date().timeIntervalSince($0) }
    }

    /// Records `milestone` the first time it is reached in this process.
    public static func mark(_ milestone: String) {
        guard let elapsed = sinceProcessStart() else { return }
        let isFirst = reached.withLock {
            guard marks[milestone] == nil else { return false }
            marks[milestone] = elapsed
            return true
        }
        guard isFirst else { return }
        logger.info("\(milestone, privacy: .public) +\(elapsed, format: .fixed(precision: 3), privacy: .public)s")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-launch-log") {
            print(String(format: "[launch] %@ +%.3fs", milestone, elapsed))
        }
        #endif
    }

    /// When `milestone` was reached, in seconds since the process started.
    public static func time(of milestone: String) -> TimeInterval? {
        reached.withLock { marks[milestone] }
    }
}
