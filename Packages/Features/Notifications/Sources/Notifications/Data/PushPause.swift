import Foundation

/// Whether push is paused (#1575): the server's ONE "pause all" preference,
/// the same one Settings → Notifications writes (`paused_until_ms`).
public enum PushPause: Equatable, Sendable {
    case off
    /// Every push held until then.
    case until(Date)
    /// Every push held until the viewer resumes.
    case indefinite

    /// ⚠️ PROVISIONAL INDEFINITE FORM, until backend #971 names one: a pause
    /// to the last second of 9999 (`paused_until_ms`). Any deadline past
    /// `indefiniteThreshold` from now reads back as indefinite, so a server
    /// that clamps the sentinel still reads right.
    public static let indefiniteMs: Int64 = 253_402_300_799_000
    /// A deadline this far ahead is "until I turn it back on".
    public static let indefiniteThreshold: TimeInterval = 10 * 365 * 24 * 3_600

    /// What the server holds, read at `now`: a deadline already past is off.
    public init(pausedUntilMs: Int64, now: Date) {
        guard pausedUntilMs > 0 else { self = .off; return }
        let deadline = Date(timeIntervalSince1970: TimeInterval(pausedUntilMs) / 1_000)
        if deadline.timeIntervalSince(now) >= Self.indefiniteThreshold {
            self = .indefinite
        } else {
            self = deadline > now ? .until(deadline) : .off
        }
    }

    /// The value sent to the server: 0 resumes.
    public var pausedUntilMs: Int64 {
        switch self {
        case .off: 0
        case .until(let deadline): Int64(deadline.timeIntervalSince1970 * 1_000)
        case .indefinite: Self.indefiniteMs
        }
    }

    public var isPaused: Bool { self != .off }

    /// The same pause seen at `now`: a deadline reached ends it.
    public func at(_ now: Date) -> PushPause {
        if case .until(let deadline) = self, deadline <= now { return .off }
        return self
    }
}
