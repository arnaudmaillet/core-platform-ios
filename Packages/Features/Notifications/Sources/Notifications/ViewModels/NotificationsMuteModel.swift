import Foundation

/// The Notifications screen's mute toolbar (#1575, the owner 2026-10-22):
///
/// ```
/// not muted   [ ——— bell.slash  Mute ——— ][ timer ]
/// muted       [ ——— bell  Unmute ——— ][ 7 h 42 ]
/// ```
///
/// - The wide button pauses EVERY push for 8 h, or resumes at once; its
///   glyph and label say what a tap will do.
/// - The trailing item always opens the duration menu. Not muted, a choice
///   pauses for that long; muted, it ADDS that long to the running pause.
///   "Until I turn it back on" makes the pause indefinite.
/// - Push only: the list keeps filling while muted.
///
/// It is the server's one "pause all" preference, the one Settings →
/// Notifications writes, read again on every visit.
///
/// ⚠️ LONGER PAUSES WAIT FOR THE SERVER (backend #971): the fleet caps a
/// pause at 8 h, so without `allowsLongPauses` the menu offers only the
/// choices that end within 8 h — never a row that would fail.
@MainActor
public final class NotificationsMuteModel {
    /// A duration in the menu.
    public enum Choice: CaseIterable, Sendable {
        case hour
        case eightHours
        case day
        case week
        case indefinite

        /// Nil: until resumed.
        public var duration: TimeInterval? {
            switch self {
            case .hour: 3_600
            case .eightHours: 8 * 3_600
            case .day: 24 * 3_600
            case .week: 7 * 24 * 3_600
            case .indefinite: nil
            }
        }

        public var title: String {
            switch self {
            case .hour: "1 Hour"
            case .eightHours: "8 Hours"
            case .day: "24 Hours"
            case .week: "1 Week"
            case .indefinite: "Until I Turn It Back On"
            }
        }
    }

    /// What the wide button pauses for.
    public static let muteDuration: TimeInterval = 8 * 3_600
    /// The longest pause the fleet accepts before backend #971, with the
    /// minute of slack the server allows for the trip.
    public static let serverCap: TimeInterval = 8 * 3_600 + 60

    /// What the server last said, seen now (a deadline reached is off).
    public var pause: PushPause { serverPause.at(now()) }
    /// A write is on its way: the controls take no second one.
    public private(set) var isSaving = false
    /// The pause ended on its own while the screen was open (`tick`).
    public var onExpire: (() -> Void)?

    public let allowsLongPauses: Bool
    /// The model's clock — what the toolbar reads the time left at.
    public var clock: Date { now() }
    private var serverPause: PushPause = .off
    private let repository: any NotificationsProviding
    private let now: @Sendable () -> Date

    public init(
        repository: any NotificationsProviding,
        allowsLongPauses: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.allowsLongPauses = allowsLongPauses
        self.now = now
    }

    /// Reads the preference again — every visit, so a change made in
    /// Settings shows. A failure keeps what was known.
    @discardableResult
    public func load() async -> PushPause {
        if let read = try? await repository.pushPause() { serverPause = read }
        return pause
    }

    // MARK: - What a control asks for

    /// The wide button: mute for 8 h, or unmute.
    public func mainTarget() -> PushPause {
        pause.isPaused ? .off : .until(now().addingTimeInterval(Self.muteDuration))
    }

    /// A menu row. Muted on a deadline, the duration is ADDED to it; an
    /// indefinite pause has no deadline to add to, so a timed row there
    /// ends it after that long.
    public func target(for choice: Choice) -> PushPause {
        guard let duration = choice.duration else { return .indefinite }
        if case .until(let deadline) = pause { return .until(deadline.addingTimeInterval(duration)) }
        return .until(now().addingTimeInterval(duration))
    }

    /// The rows the menu offers: all of them where long pauses are
    /// accepted; otherwise only the ones ending within the server's cap.
    /// "Until I turn it back on" is left out while it is already the pause.
    public var choices: [Choice] {
        Choice.allCases.filter { choice in
            if choice == .indefinite, pause == .indefinite { return false }
            if allowsLongPauses { return true }
            guard case .until(let deadline) = target(for: choice) else { return false }
            return deadline.timeIntervalSince(now()) <= Self.serverCap
        }
    }

    // MARK: - Writing

    /// Sends `target`; returns what the server now holds. One at a time.
    public func set(_ target: PushPause) async throws -> PushPause {
        guard !isSaving else { throw CancellationError() }
        isSaving = true
        defer { isSaving = false }
        let held = try await repository.setPushPause(target)
        serverPause = held
        return held.at(now())
    }

    // MARK: - The clock

    /// Re-reads the clock: a deadline reached ends the pause.
    public func tick() {
        guard case .until(let deadline) = serverPause, deadline <= now() else { return }
        serverPause = .off
        onExpire?()
    }

    /// How long until the time left reads differently (it counts whole
    /// minutes, rounded up), or the pause ends. Nil when nothing changes.
    public func nextTick() -> TimeInterval? {
        guard case .until(let deadline) = serverPause else { return nil }
        let left = deadline.timeIntervalSince(now())
        guard left > 0 else { return 0 }
        let shownMinutes = (left / 60).rounded(.up)
        return max(left - (shownMinutes - 1) * 60, 0.05)
    }

    // MARK: - Words

    /// The trailing item's text while muted: "7 h 42", "42 min", "2 d 3 h",
    /// "∞"; nil when not muted (the item is a timer glyph).
    public static func timeLeft(_ pause: PushPause, now: Date) -> String? {
        switch pause.at(now) {
        case .off: return nil
        case .indefinite: return "∞"
        case .until(let deadline):
            let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
            if minutes < 60 { return "\(minutes) min" }
            let hours = minutes / 60
            if hours < 24 {
                let rest = minutes % 60
                return rest == 0 ? "\(hours) h" : "\(hours) h " + String(format: "%02d", rest)
            }
            let days = hours / 24
            let restHours = hours % 24
            return restHours == 0 ? "\(days) d" : "\(days) d \(restHours) h"
        }
    }

    /// VoiceOver's reading of the time left.
    public static func timeLeftForVoiceOver(_ pause: PushPause, now: Date) -> String {
        switch pause.at(now) {
        case .off: return "Not muted"
        case .indefinite: return "Muted until you turn it back on"
        case .until(let deadline):
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.maximumUnitCount = 2
            let left = max(deadline.timeIntervalSince(now), 60)
            return (formatter.string(from: left) ?? "") + " left"
        }
    }

    /// The bar toast confirming a change.
    public static func confirmation(for pause: PushPause, now: Date, calendar: Calendar = .current) -> String {
        switch pause {
        case .off: return "Notifications unmuted"
        case .indefinite: return "Muted until you turn it back on"
        case .until(let deadline):
            // Today: a time; this week: its day; further: its date.
            let style: Date.FormatStyle = if calendar.isDate(deadline, inSameDayAs: now) {
                .dateTime.hour().minute()
            } else if deadline.timeIntervalSince(now) < 6 * 24 * 3_600 {
                .dateTime.weekday(.abbreviated).hour().minute()
            } else {
                .dateTime.month(.abbreviated).day().hour().minute()
            }
            return "Muted until \(deadline.formatted(style))"
        }
    }

    /// The toast when a change is refused.
    public static func failure(muting: Bool) -> String {
        muting ? "Couldn't mute notifications" : "Couldn't unmute notifications"
    }
}
