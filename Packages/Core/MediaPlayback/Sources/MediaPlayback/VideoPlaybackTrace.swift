import Foundation

/// A breadcrumb trail for the pool's OWNERSHIP boundaries.
///
/// ⚠️ It exists because the fault it chases has no moment: a surface that ends
/// up without a player was fine at every point anyone thought to look, and the
/// call that took its loan away happened somewhere else entirely. Only the
/// ORDER of the boundary crossings says which one it was.
///
/// Writes to the same file the carousel audit uses, so the two read as one
/// sequence — the pool's side and the surface's side of the same handoff.
/// Silent unless `-carousel-audit` is on.
@MainActor
public enum VideoPlaybackTrace {
    public private(set) static var isEnabled = ProcessInfo.processInfo.arguments.contains("-carousel-audit")

    #if DEBUG
    /// Test hook. The flag is read from launch arguments, which a unit test
    /// cannot set — and what it gates includes BOOKKEEPING (the stall-observer
    /// table), so a table that leaks only under the flag would otherwise be
    /// untestable exactly where it misbehaves.
    public static func debugOverrideEnabled(_ enabled: Bool) { isEnabled = enabled }
    #endif

    /// Set by the app so the pool can write beside the audit without depending
    /// on it — MediaPlayback sits below PostGrid and must not import it.
    public static var sink: ((String) -> Void)?

    public static func emit(_ line: String) {
        guard isEnabled else { return }
        sink?("pool " + line)
    }
}
