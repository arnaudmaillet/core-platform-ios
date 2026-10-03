import OSLog

/// DEBUG: names a write that reached its repository for a guest — a control
/// the member gate does not cover yet (#440).
///
/// A log, not an assertion, on purpose: a member's session can expire between
/// the gate's answer and the write, and that is not a missing gate. The line is
/// `[gate] UNGATED WRITE …` in the console and a fault in Console.app, so a QA
/// run that exercises a guest finds the gap by searching for it.
public enum GateAudit {
    private static let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "gate")

    public static func ungatedWrite(_ write: String) {
        #if DEBUG
        logger.fault("[gate] UNGATED WRITE \(write, privacy: .public): a guest reached it without the member gate")
        print("[gate] UNGATED WRITE \(write): a guest reached it without the member gate")
        #endif
    }
}
