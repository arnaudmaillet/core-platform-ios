import AuthInterface
import CoreContracts
import CoreNetworking
import CoreStorage
import Foundation

/// Today's time on the app, all devices together, as `ReportScreenTime`
/// answered it (#417, backend #670 part 2).
public struct ScreenTimeStatus: Equatable, Sendable {
    public let usedMinutes: Int
    /// Nil: no daily limit (nothing is counted then).
    public let limitMinutes: Int?
    /// Show the pause screen. The server cuts nothing.
    public let reached: Bool

    public init(usedMinutes: Int, limitMinutes: Int?, reached: Bool) {
        self.usedMinutes = usedMinutes
        self.limitMinutes = limitMinutes
        self.reached = reached
    }
}

/// Reports minutes of use and learns today's total.
public protocol ScreenTimeReporting: Sendable {
    /// `minutes`: use since the last report, 1–15. `timeZone`: the day
    /// counted is local to it.
    func reportScreenTime(minutes: Int, timeZone: TimeZone) async throws -> ScreenTimeStatus
}

extension AccountRepository: ScreenTimeReporting {
    public func reportScreenTime(minutes: Int, timeZone: TimeZone) async throws -> ScreenTimeStatus {
        var request = Account_V1_ReportScreenTimeRequest()
        request.accountID = try await accountID()
        request.minutes = UInt32(max(0, minutes))
        request.timezone = timeZone.identifier
        let response = await accountClient.reportScreenTime(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            return ScreenTimeStatus(
                usedMinutes: Int(view.usedMinutes),
                limitMinutes: view.limitMinutes == 0 ? nil : Int(view.limitMinutes),
                reached: view.reached
            )
        case .failure(let error):
            throw SupervisionError(error)
        }
    }
}

/// A supervised teen's time in the app, reported to the server (#417).
///
/// **Only what the app measures**: the foreground time `ScreenTimeCoordinator`
/// already counts for Time Management, no Screen Time or FamilyControls
/// framework (the personal signing team has no such entitlement). **Only a
/// teen's**: an adult's time never leaves the device (the server counts only
/// under a supervisor's daily limit anyway).
///
/// - **Batched**: time gathers here and leaves in whole minutes, at most 15
///   per report (the contract's cap), every `reportInterval` while the app is
///   in front, and when it leaves the front.
/// - **Off main, resilient**: an actor; the pending seconds are kept in
///   `UserDefaults`, so a report that fails (offline, killed) is sent on the
///   next try, and nothing is counted twice: a minute leaves the queue only
///   once the server has taken it.
/// - **Honest days**: the server counts a report on the day it arrives. Time
///   still pending when the local day changes is dropped rather than added
///   to the new day; at most one interval's worth.
/// - **Viewer-scoped**: pending time belongs to one account; another
///   account, or a sign-out, starts over (`viewerDidChange`).
public actor SupervisedScreenTime: ViewerScoped {
    /// The contract's cap on one report.
    public static let maxMinutesPerReport = 15
    /// How often the app reports while in front.
    public static let reportInterval: TimeInterval = 300
    /// How long a dismissed pause screen waits before it may show again,
    /// while the limit is still reached.
    public static let pauseRepeatInterval: TimeInterval = 1800

    struct Pending: Codable, Equatable {
        var account: String
        var day: String
        var seconds: TimeInterval
    }

    struct PauseShown: Codable, Equatable {
        var account: String
        var day: String
        var at: Date
    }

    private let reporter: any ScreenTimeReporting
    private let defaults: UserDefaults
    private let accountID: @Sendable () async -> String?
    private let isMinor: @Sendable () -> Bool
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private var sending = false
    private let pendingKey = "supervisedScreenTime.pending"
    private let pauseKey = "supervisedScreenTime.pauseShown"

    /// No default arguments: an actor's defaults can't be evaluated from the
    /// app's main-actor composition root.
    public init(
        reporter: any ScreenTimeReporting,
        defaults: UserDefaults,
        accountID: @escaping @Sendable () async -> String?,
        isMinor: @escaping @Sendable () -> Bool,
        calendar: @escaping @Sendable () -> Calendar,
        now: @escaping @Sendable () -> Date
    ) {
        self.reporter = reporter
        self.defaults = defaults
        self.accountID = accountID
        self.isMinor = isMinor
        self.calendar = calendar
        self.now = now
    }

    private func today() -> String { ScreenTimeLedger.key(for: now(), calendar: calendar()) }

    /// Seconds waiting to be reported, for the current account and day.
    public func pendingSeconds() async -> TimeInterval {
        guard let account = await accountID(), let pending = load(), pending.account == account, pending.day == today() else {
            return 0
        }
        return pending.seconds
    }

    /// Adds `seconds` of foreground time. Nothing for an adult or a guest.
    public func record(seconds: TimeInterval) async {
        guard seconds > 0, isMinor(), let account = await accountID() else { return }
        let day = today()
        var pending = load() ?? Pending(account: account, day: day, seconds: 0)
        if pending.account != account || pending.day != day {
            pending = Pending(account: account, day: day, seconds: 0)
        }
        pending.seconds += seconds
        save(pending)
    }

    /// Sends the whole minutes waiting, 15 at most per report, and returns
    /// the last answer; nil when nothing was sent (nothing waiting, a report
    /// already running, or the first report failed — the time stays queued).
    public func flush() async -> ScreenTimeStatus? {
        guard !sending, isMinor(), let account = await accountID() else { return nil }
        sending = true
        defer { sending = false }
        var last: ScreenTimeStatus?
        while true {
            guard let pending = load(), pending.account == account, pending.day == today() else {
                // Someone else's, or a day gone by: never sent as today's.
                if load() != nil { defaults.removeObject(forKey: pendingKey) }
                return last
            }
            let minutes = min(Self.maxMinutesPerReport, Int(pending.seconds / 60))
            guard minutes >= 1 else { return last }
            do {
                last = try await reporter.reportScreenTime(minutes: minutes, timeZone: calendar().timeZone)
            } catch {
                return last
            }
            // Time recorded during the call is in the stored value: take the
            // sent minutes off what is there now.
            if var current = load(), current.account == pending.account, current.day == pending.day {
                current.seconds = max(0, current.seconds - TimeInterval(minutes * 60))
                save(current)
            }
        }
    }

    /// Whether `status` should bring the pause screen up now: the limit is
    /// reached and it hasn't shown in the last `pauseRepeatInterval` today.
    /// Saying yes records that it showed.
    public func shouldShowPause(for status: ScreenTimeStatus) async -> Bool {
        guard status.reached, let account = await accountID() else { return false }
        let day = today()
        let moment = now()
        if let shown = loadPause(), shown.account == account, shown.day == day,
           moment.timeIntervalSince(shown.at) < Self.pauseRepeatInterval {
            return false
        }
        savePause(PauseShown(account: account, day: day, at: moment))
        return true
    }

    /// Another account, or nobody: what was pending was someone else's. A
    /// switch between the same account's profiles keeps it: time is the
    /// account's, not a profile's.
    public func viewerDidChange(_ state: ViewerState) async {
        if case .member(let account, _) = state, load()?.account == account.rawValue { return }
        clear()
    }

    public func clear() {
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: pauseKey)
    }

    // MARK: - Storage

    private func load() -> Pending? {
        defaults.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
    }

    private func save(_ pending: Pending) {
        if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: pendingKey) }
    }

    private func loadPause() -> PauseShown? {
        defaults.data(forKey: pauseKey).flatMap { try? JSONDecoder().decode(PauseShown.self, from: $0) }
    }

    private func savePause(_ shown: PauseShown) {
        if let data = try? JSONEncoder().encode(shown) { defaults.set(data, forKey: pauseKey) }
    }
}

/// The pause screen's words (#417): why it shows, who set the limit, and
/// that nothing is locked.
public enum SupervisedPauseCopy {
    public static let title = "Time for a pause"
    public static let dismiss = "OK"

    /// `setBy`: the supervisor's handle when known.
    public static func body(_ status: ScreenTimeStatus, setBy: String?) -> String {
        let used: String = ScreenTimeLedger.durationText(TimeInterval(status.usedMinutes * 60))
        let who: String = setBy ?? "your supervisor"
        let limit: String = status.limitMinutes.map { "of \(ScreenTimeLedger.durationText(TimeInterval($0 * 60))) " } ?? ""
        return "You've spent \(used) in the app today, on all your devices. The daily limit \(limit)set by \(who) is reached, so this is a good moment for a break. Nothing is locked: Settings, blocking and reporting always work."
    }

    /// Who set the teen's limit, by handle: the last change's author among
    /// the viewer's supervisors. Nil when it can't be told.
    public static func limitSetter(using account: any SupervisionManaging & SupervisionOverviewing) async -> String? {
        guard let overview = try? await account.supervisionOverview(teenAccountID: nil),
              let setBy = overview.limits.setByAccountID,
              let supervisions = try? await account.supervisions() else { return nil }
        return supervisions.first { $0.otherAccountID == setBy }?.handleText
    }
}
