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
        if ProcessInfo.processInfo.arguments.contains("-launch-log") {
            print(String(format: "[launch] %@ +%.3fs", milestone, elapsed))
        }
        #endif
    }

    /// When `milestone` was reached, in seconds since the process started.
    public static func time(of milestone: String) -> TimeInterval? {
        reached.withLock { marks[milestone] }
    }

    /// Calls `handler` on the main actor once `milestone` is reached — on the
    /// next turn if it already was (#1812: the launch screen waits for the
    /// first post's picture).
    public static func whenReached(_ milestone: String, _ handler: @escaping @MainActor @Sendable () -> Void) {
        let already = reached.withLock { () -> Bool in
            guard marks[milestone] == nil else { return true }
            waiters[milestone, default: []].append(handler)
            return false
        }
        if already { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
    }

    // MARK: - The launch curtain (#1812)

    /// Whether the launch screen still covers the app: the shell holds it over
    /// the first post until that post's picture is on screen. What would be
    /// HEARD waits for it to lift — the page's song, a clip's sound — and is
    /// told when it does (`curtainDidLift`).
    @MainActor public static var curtainIsUp = false {
        didSet {
            guard oldValue, !curtainIsUp else { return }
            NotificationCenter.default.post(name: curtainDidLift, object: nil)
        }
    }

    /// Posted on the main actor when the launch curtain starts to lift.
    public static let curtainDidLift = Notification.Name("cn.wynn.core-platform-ios.launchCurtainDidLift")
}
