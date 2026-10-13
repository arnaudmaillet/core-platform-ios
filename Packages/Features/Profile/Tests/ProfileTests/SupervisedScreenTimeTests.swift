import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Profile

/// A supervised teen's time in the app, reported in batches and kept until
/// the server takes it (#417, backend #670 part 2).
struct SupervisedScreenTimeTests {
    /// Answers the test sets; remembers each report's minutes.
    private final class Reporter: ScreenTimeReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [Int] = []
        private var failing = false
        var reached = false

        var minutes: [Int] { lock.withLock { sent } }
        func fail(_ on: Bool) { lock.withLock { failing = on } }

        func reportScreenTime(minutes: Int, timeZone: TimeZone) async throws -> ScreenTimeStatus {
            try lock.withLock {
                if failing { throw SupervisionError.transport(message: "offline", failure: .offline) }
                sent.append(minutes)
            }
            return ScreenTimeStatus(usedMinutes: minutes, limitMinutes: 60, reached: reached)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ date: Date) { value = date }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private final class Who: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String? = "acct-teen"
        var account: String? { lock.withLock { value } }
        func set(_ account: String?) { lock.withLock { value = account } }
    }

    private static let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// Noon in Paris, so the day never turns during a test unless it means to.
    private static let noon = paris.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!

    private func makeQueue(
        _ reporter: Reporter, clock: Clock = Clock(noon), who: Who = Who(), minor: Bool = true
    ) -> SupervisedScreenTime {
        SupervisedScreenTime(
            reporter: reporter,
            defaults: UserDefaults(suiteName: "supervised-\(UUID().uuidString)")!,
            accountID: { who.account },
            isMinor: { minor },
            calendar: { Self.paris },
            now: { clock.now }
        )
    }

    /// An adult's time never leaves the device.
    @Test func anAdultsTimeIsNeverReported() async {
        let reporter = Reporter()
        let queue = makeQueue(reporter, minor: false)
        await queue.record(seconds: 3_600)
        #expect(await queue.flush() == nil)
        #expect(reporter.minutes.isEmpty)
        #expect(await queue.pendingSeconds() == 0)
    }

    /// Whole minutes leave in reports of 15 at most; the seconds over a
    /// minute wait for the next report.
    @Test func timeLeavesInBatchesOfFifteenMinutesAtMost() async {
        let reporter = Reporter()
        let queue = makeQueue(reporter)
        await queue.record(seconds: 40 * 60 + 30)
        #expect(await queue.flush() != nil)
        #expect(reporter.minutes == [15, 15, 10])
        #expect(await queue.pendingSeconds() == 30)
        #expect(await queue.flush() == nil, "under a minute waits")
    }

    /// Offline, the time stays queued and goes out on the next try, once.
    @Test func aFailedReportKeepsTheTimeForTheNextTry() async {
        let reporter = Reporter()
        let queue = makeQueue(reporter)
        await queue.record(seconds: 5 * 60)
        reporter.fail(true)
        #expect(await queue.flush() == nil)
        #expect(await queue.pendingSeconds() == 300)
        reporter.fail(false)
        await queue.record(seconds: 60)
        #expect(await queue.flush() != nil)
        #expect(reporter.minutes == [6])
        #expect(await queue.pendingSeconds() == 0)
    }

    /// Time left over from a day gone by is never sent as today's: the
    /// server counts a report on the day it arrives.
    @Test func yesterdaysPendingTimeIsDroppedNotCountedToday() async {
        let reporter = Reporter()
        let clock = Clock(Self.noon)
        let queue = makeQueue(reporter, clock: clock)
        await queue.record(seconds: 10 * 60)
        clock.advance(86_400)
        #expect(await queue.flush() == nil)
        #expect(reporter.minutes.isEmpty)
        await queue.record(seconds: 120)
        #expect(await queue.pendingSeconds() == 120, "today starts from zero")
    }

    /// Pending time is one account's: another account starts over, and a
    /// viewer change clears it.
    @Test func pendingTimeBelongsToOneAccount() async {
        let reporter = Reporter()
        let who = Who()
        let queue = makeQueue(reporter, who: who)
        await queue.record(seconds: 10 * 60)
        who.set("acct-other")
        #expect(await queue.flush() == nil)
        #expect(reporter.minutes.isEmpty)

        await queue.record(seconds: 3 * 60)
        await queue.viewerDidChange(.member(AccountID("acct-other"), activeProfile: ProfileID("prof-2")))
        #expect(await queue.pendingSeconds() == 180, "a profile switch keeps the account's time")
        await queue.viewerDidChange(.guest)
        #expect(await queue.pendingSeconds() == 0)
        who.set(nil)
        await queue.record(seconds: 3 * 60)
        #expect(await queue.flush() == nil, "a guest reports nothing")
    }

    /// The pause screen shows when the limit is reached, then at most every
    /// half hour while it holds.
    @Test func thePauseShowsAtMostEveryHalfHour() async {
        let clock = Clock(Self.noon)
        let queue = makeQueue(Reporter(), clock: clock)
        let reached = ScreenTimeStatus(usedMinutes: 60, limitMinutes: 60, reached: true)
        #expect(await !queue.shouldShowPause(for: ScreenTimeStatus(usedMinutes: 30, limitMinutes: 60, reached: false)))
        #expect(await queue.shouldShowPause(for: reached))
        clock.advance(10 * 60)
        #expect(await !queue.shouldShowPause(for: reached))
        clock.advance(SupervisedScreenTime.pauseRepeatInterval)
        #expect(await queue.shouldShowPause(for: reached))
    }

    /// The pause says why and who set the limit, and that nothing is locked.
    @Test func thePauseSaysWhyWhoAndThatNothingIsLocked() {
        let status = ScreenTimeStatus(usedMinutes: 62, limitMinutes: 60, reached: true)
        let named = SupervisedPauseCopy.body(status, setBy: "@mum")
        #expect(named.contains("set by @mum"))
        #expect(named.contains("of 1 hr"))
        #expect(named.contains("Nothing is locked"))
        #expect(named.contains("blocking and reporting"))
        #expect(SupervisedPauseCopy.body(status, setBy: nil).contains("set by your supervisor"))
    }

    // MARK: - Over the mock

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    /// Against the contract's mock: the teen's 60-minute limit (42 used
    /// today) is reached after 18 more minutes, and the pause names the
    /// supervisor who set it.
    @Test func reportsReachTheSupervisorsLimitOverTheMock() async throws {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        let mock = MockSupervisionService(
            dataset: MockSocialDataset(), viewerAge: { 15 }, seed: .supervised, autoAcceptDelay: nil
        )
        mock.register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let defaults = UserDefaults(suiteName: "supervised-mock-\(UUID().uuidString)")!
        let repository = AccountRepository(
            accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session(),
            teenProtections: TeenProtections(defaults: defaults, screenTime: ScreenTimeStore(defaults: defaults))
        )
        let queue = SupervisedScreenTime(
            reporter: repository, defaults: defaults,
            accountID: { MockAuthService.accountID }, isMinor: { true },
            calendar: { Calendar.current }, now: { Date() }
        )
        let before = mock.viewerMinutesToday
        await queue.record(seconds: TimeInterval((60 - before) * 60))
        let status = try #require(await queue.flush())
        #expect(status.usedMinutes == 60)
        #expect(status.limitMinutes == 60)
        #expect(status.reached)
        #expect(mock.viewerMinutesToday == 60)
        let setter = await SupervisedPauseCopy.limitSetter(using: repository)
        #expect(setter?.hasPrefix("@") == true)
    }
}
