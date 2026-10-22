import CoreModels
import Foundation
import Synchronization
import Testing
import UIKit
@testable import Notifications

/// A clock a test moves.
private final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// The server's pause, and what was sent to it.
private actor PauseServer: NotificationsProviding {
    private var held: PushPause
    private(set) var sent: [PushPause] = []
    private let refuses: Bool

    init(_ held: PushPause = .off, refuses: Bool = false) {
        self.held = held
        self.refuses = refuses
    }

    func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
        NotificationsPage(items: [], nextPageToken: nil)
    }
    func markAllRead() async throws {}
    func unreadCount() async throws -> Int { 0 }
    func pushPause() async throws -> PushPause { held }
    func setPushPause(_ pause: PushPause) async throws -> PushPause {
        sent.append(pause)
        if refuses { throw NotificationsError.transport(message: "refused") }
        held = pause
        return pause
    }
}

/// The mute toolbar (#1575): Mute (8 h) / Unmute, the duration menu, adding
/// to a running pause, the server's cap, the time left and its end.
@MainActor
@Suite(.serialized)
struct NotificationsMuteTests {
    private let clock = TestClock()

    private func model(_ server: PauseServer, long: Bool = true) -> NotificationsMuteModel {
        let clock = clock
        return NotificationsMuteModel(repository: server, allowsLongPauses: long, now: { clock.now })
    }

    @Test func muteSendsEightHoursFromNow() async throws {
        let server = PauseServer()
        let mute = model(server)
        await mute.load()
        let target = mute.mainTarget()
        #expect(target == .until(clock.now.addingTimeInterval(28_800)))
        _ = try await mute.set(target)
        #expect(await server.sent == [target])
        let expectedMs: Int64 = Int64(clock.now.timeIntervalSince1970 * 1_000) + 28_800_000
        #expect(target.pausedUntilMs == expectedMs)
        #expect(mute.pause.isPaused)
    }

    @Test func unmuteSendsZero() async throws {
        let server = PauseServer(.until(clock.now.addingTimeInterval(3_600)))
        let mute = model(server)
        await mute.load()
        let target = mute.mainTarget()
        #expect(target == .off && target.pausedUntilMs == 0)
        _ = try await mute.set(target)
        #expect(await server.sent == [.off])
        #expect(!mute.pause.isPaused)
    }

    /// ⚠️ Typed and pre-computed: Xcode 26 (CI) times out inferring a tuple
    /// literal mixed with arithmetic in `@Test(arguments:)` (#999's family).
    nonisolated static let choiceDurations: [(NotificationsMuteModel.Choice, TimeInterval)] = [
        (.hour, 3_600), (.eightHours, 28_800), (.day, 86_400), (.week, 604_800),
    ]

    @Test(arguments: choiceDurations)
    func eachChoiceSendsItsDeadline(choice: NotificationsMuteModel.Choice, seconds: TimeInterval) async {
        let mute = model(PauseServer())
        await mute.load()
        #expect(mute.target(for: choice) == .until(clock.now.addingTimeInterval(seconds)))
    }

    @Test func untilTurnedBackOnSendsTheIndefiniteForm() async {
        let mute = model(PauseServer())
        await mute.load()
        let target = mute.target(for: .indefinite)
        #expect(target == .indefinite)
        #expect(target.pausedUntilMs == PushPause.indefiniteMs)
        #expect(PushPause(pausedUntilMs: PushPause.indefiniteMs, now: clock.now) == .indefinite, "it does not read back")
    }

    /// Muted, a choice ADDS to the running deadline.
    @Test func aChoiceWhileMutedAddsToTheDeadline() async {
        let deadline = clock.now.addingTimeInterval(2 * 3_600)
        let mute = model(PauseServer(.until(deadline)))
        await mute.load()
        #expect(mute.target(for: .hour) == .until(deadline.addingTimeInterval(3_600)))
        #expect(mute.target(for: .week) == .until(deadline.addingTimeInterval(604_800)))
        #expect(mute.choices.contains(.indefinite))
    }

    /// Indefinitely muted: no deadline to add to — a timed row ends it after
    /// that long, and "until I turn it back on" is not offered again.
    @Test func whileIndefiniteATimedChoiceSetsAnEnd() async {
        let mute = model(PauseServer(.indefinite))
        await mute.load()
        #expect(mute.target(for: .day) == .until(clock.now.addingTimeInterval(86_400)))
        #expect(!mute.choices.contains(.indefinite))
    }

    /// ⚠️ Without backend #971, no row the fleet would refuse.
    @Test func withoutLongPausesOnlyRowsWithinEightHours() async {
        let idle = model(PauseServer(), long: false)
        await idle.load()
        #expect(idle.choices == [.hour, .eightHours])

        let oneHourLeft = model(PauseServer(.until(clock.now.addingTimeInterval(3_600))), long: false)
        await oneHourLeft.load()
        #expect(oneHourLeft.choices == [.hour], "1 h + 1 h fits, 1 h + 8 h does not")

        let nearlyFull = model(PauseServer(.until(clock.now.addingTimeInterval(27_000))), long: false)
        await nearlyFull.load()
        #expect(nearlyFull.choices.isEmpty)
        #expect(model(PauseServer()).choices == NotificationsMuteModel.Choice.allCases, "the mock offers them all")
    }

    /// The time left counts down, and the pause ends on its own.
    @Test func theTimeLeftCountsDownAndThePauseEnds() async {
        let deadline = clock.now.addingTimeInterval(27_720)
        let mute = model(PauseServer(.until(deadline)))
        await mute.load()
        #expect(NotificationsMuteModel.timeLeft(mute.pause, now: clock.now) == "7 h 42")
        #expect(mute.nextTick() == 60)

        clock.advance(by: 7 * 3_600)
        #expect(NotificationsMuteModel.timeLeft(mute.pause, now: clock.now) == "42 min")

        var expired = 0
        mute.onExpire = { expired += 1 }
        clock.advance(by: 41 * 60)
        mute.tick()
        #expect(expired == 0 && NotificationsMuteModel.timeLeft(mute.pause, now: clock.now) == "1 min")
        clock.advance(by: 60)
        mute.tick()
        #expect(expired == 1)
        #expect(mute.pause == .off)
        #expect(mute.nextTick() == nil)
    }

    @Test func theTimeLeftReads() {
        let now = clock.now
        let left = { (seconds: TimeInterval) in NotificationsMuteModel.timeLeft(.until(now.addingTimeInterval(seconds)), now: now) }
        #expect(left(28_800) == "8 h")
        #expect(left(3_900) == "1 h 05")
        #expect(left(30) == "1 min")
        #expect(left(183_600) == "2 d 3 h")
        #expect(left(604_800) == "7 d")
        #expect(NotificationsMuteModel.timeLeft(.indefinite, now: now) == "∞")
        #expect(NotificationsMuteModel.timeLeft(.off, now: now) == nil)
    }

    @Test func aDeadlinePastReadsOff() {
        let now = clock.now
        let past = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        #expect(PushPause(pausedUntilMs: past, now: now) == .off)
        #expect(PushPause(pausedUntilMs: 0, now: now) == .off)
    }

    // MARK: - The toolbar

    private func hosting(_ server: PauseServer) -> (UIWindow, NotificationsViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = NotificationsViewController(
            viewModel: NotificationsViewModel(repository: server), imagePipeline: nil, muteModel: model(server)
        )
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, controller)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theToolbarSaysWhatATapWillDo() async {
        let (window, controller) = hosting(PauseServer())
        defer { window.rootViewController = nil; window.isHidden = true }
        #expect(controller.navigationController?.isToolbarHidden == false)
        #expect(controller.toolbarItems?.count == 3)
        #expect(controller.debugMuteButtonTitle == "Mute")
        #expect(controller.debugMuteTimerText == nil, "not muted: the timer glyph")

        let (mutedWindow, muted) = hosting(PauseServer(.until(clock.now.addingTimeInterval(27_720))))
        defer { mutedWindow.rootViewController = nil; mutedWindow.isHidden = true }
        await settle { muted.debugMuteButtonTitle == "Unmute" }
        #expect(muted.debugMuteButtonTitle == "Unmute")
        #expect(muted.debugMuteTimerText == "7 h 42")
    }

    /// The menu offers the rows, worded as additions while muted.
    @Test func theMenuAddsWhileMuted() async throws {
        let (window, controller) = hosting(PauseServer(.until(clock.now.addingTimeInterval(3_600))))
        defer { window.rootViewController = nil; window.isHidden = true }
        await settle { controller.debugMuteButtonTitle == "Unmute" }
        let menu = try #require(controller.muteMenuElements().first as? UIMenu)
        #expect(menu.title == "Add Time")
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
        #expect(titles == ["Add 1 Hour", "Add 8 Hours", "Add 24 Hours", "Add 1 Week", "Until I Turn It Back On"])
    }

    @Test func confirmationsAndFailuresRead() {
        let now = clock.now
        #expect(NotificationsMuteModel.confirmation(for: .off, now: now) == "Notifications unmuted")
        #expect(NotificationsMuteModel.confirmation(for: .indefinite, now: now) == "Muted until you turn it back on")
        #expect(NotificationsMuteModel.confirmation(for: .until(now.addingTimeInterval(60)), now: now).hasPrefix("Muted until "))
        #expect(NotificationsMuteModel.failure(muting: true) == "Couldn't mute notifications")
    }

    /// A refused write leaves the pause as it was.
    @Test func aRefusalKeepsThePause() async {
        let server = PauseServer(refuses: true)
        let mute = model(server)
        await mute.load()
        await #expect(throws: NotificationsError.self) { try await mute.set(mute.mainTarget()) }
        #expect(mute.pause == .off)
        #expect(!mute.isSaving)
    }
}
