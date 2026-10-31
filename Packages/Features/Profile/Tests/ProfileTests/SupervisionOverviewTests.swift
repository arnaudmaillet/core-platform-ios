import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// A supervisor's view of a teen and the limits they set; a teen's view of
/// themselves (#417, backend #670 parts 2 and 3).
@MainActor
struct SupervisionOverviewTests {
    // MARK: - Over the mock

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private func repository(seed: MockSupervisionService.Seed) -> AccountRepository {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        // One fixed instant for the seed and the read (#1961): a run that
        // crosses local midnight must not move the overview's window.
        let now = Date()
        MockSupervisionService(
            dataset: MockSocialDataset(), viewerAge: { lifecycle.viewerAge }, seed: seed, autoAcceptDelay: nil,
            clock: { now }
        ).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let defaults = UserDefaults(suiteName: "overview-\(UUID().uuidString)")!
        return AccountRepository(
            accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session(),
            teenProtections: TeenProtections(defaults: defaults, screenTime: ScreenTimeStore(defaults: defaults))
        )
    }

    /// A supervisor reads a teen's last days (newest first) and limits, and
    /// a change comes back as the server holds it.
    @Test func aSupervisorReadsATeenAndSetsTheirLimits() async throws {
        let repository = repository(seed: .supervisor)
        let teen = try #require(try await repository.supervisions().first { $0.otherRole == .teen })
        let overview = try await repository.supervisionOverview(teenAccountID: teen.otherAccountID)
        #expect(overview.screenTime.count == 7)
        #expect(overview.screenTime.map(\.day) == overview.screenTime.map(\.day).sorted(by: >), "most recent first")
        #expect(overview.limits.limits?.dailyMinutes == 90)
        #expect(overview.limits.limits?.comments == .mutuals)
        #expect(overview.profiles.first?.handle == teen.primary?.handle)

        let next = SupervisionLimits(privateAccount: true, messages: .noOne, comments: .followers, hiddenFromSearch: true, dailyMinutes: 45)
        let saved = try await repository.setSupervisionLimits(next, teenAccountID: teen.otherAccountID)
        #expect(saved.limits == next)
        #expect(saved.setByAccountID == MockAuthService.accountID)
        #expect(try await repository.supervisionOverview(teenAccountID: teen.otherAccountID).limits.limits == next)
    }

    /// A daily limit outside 15–1440 is ACC-9001; someone else's teen is
    /// ACC-3005, for reading as for writing.
    @Test func limitsAreRefusedOutsideTheRangeAndForAnotherTeen() async throws {
        let repository = repository(seed: .supervisor)
        let teen = try #require(try await repository.supervisions().first)
        await #expect(throws: SupervisionError.invalidLimit) {
            _ = try await repository.setSupervisionLimits(SupervisionLimits(dailyMinutes: 5), teenAccountID: teen.otherAccountID)
        }
        await #expect(throws: SupervisionError.notFound) {
            _ = try await repository.setSupervisionLimits(SupervisionLimits(dailyMinutes: 60), teenAccountID: "acct-mock-prof-30")
        }
        await #expect(throws: SupervisionError.notFound) {
            _ = try await repository.supervisionOverview(teenAccountID: "acct-mock-prof-30")
        }
    }

    /// A teen reads the same overview about themselves; the limits lift when
    /// their last supervision ends.
    @Test func aTeenSeesWhatTheirSupervisorSeesUntilTheLastLinkEnds() async throws {
        let repository = repository(seed: .supervised)
        let mine = try await repository.supervisionOverview(teenAccountID: nil)
        #expect(mine.limits.limits?.dailyMinutes == 60)
        #expect(mine.limits.limits?.privateAccount == true)
        #expect(mine.limits.limits?.messages == .followers)
        #expect(!mine.screenTime.isEmpty)
        let supervisor = try #require(try await repository.supervisions().first)
        #expect(mine.limits.setByAccountID == supervisor.otherAccountID)

        _ = try await repository.endSupervision(with: supervisor.otherAccountID)
        #expect(try await repository.supervisionOverview(teenAccountID: nil).limits.limits == nil)
    }

    // MARK: - The model and the screens

    private final class FakeOverview: SupervisionOverviewing, SupervisionManaging, @unchecked Sendable {
        var overview = SupervisionOverview(
            limits: SupervisionLimitsState(limits: SupervisionLimits(dailyMinutes: 60), setByAccountID: "s1", setAt: Date()),
            screenTime: [ScreenTimeDay(day: "2026-10-13", minutes: 42)],
            profiles: []
        )
        var setError: SupervisionError?
        private(set) var saved: [SupervisionLimits] = []
        private(set) var reads: [String?] = []

        func supervisionOverview(teenAccountID: String?) async throws -> SupervisionOverview {
            reads.append(teenAccountID)
            return overview
        }
        func setSupervisionLimits(_ limits: SupervisionLimits, teenAccountID: String) async throws -> SupervisionLimitsState {
            if let setError { throw setError }
            saved.append(limits)
            return SupervisionLimitsState(limits: limits, setByAccountID: "me", setAt: Date())
        }
        func supervisions() async throws -> [Supervision] { [] }
        func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite { throw SupervisionError.notFound }
        func acceptSupervisionInvite(code: String) async throws -> Supervision { throw SupervisionError.notFound }
        func endSupervision(with otherAccountID: String) async throws -> [Supervision] { [] }
    }

    private nonisolated static func link(_ role: SupervisionRole, _ id: String) -> Supervision {
        Supervision(otherRole: role, otherAccountID: id, since: Date(), profiles: [
            SupervisionProfile(profileID: "prof-\(id)", handle: id, displayName: id.capitalized),
        ])
    }

    private func settle(looks: Int = 6_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Saving is never optimistic: a refusal leaves the limits as they were.
    @Test func aRefusedSaveKeepsTheLimits() async throws {
        let fake = FakeOverview()
        let model = SupervisionOverviewModel(manager: fake, teenAccountID: "t1")
        await model.load()
        fake.setError = .transport(message: "down", failure: .offline)
        await #expect(throws: SupervisionError.self) { try await model.setLimits(SupervisionLimits(dailyMinutes: 30)) }
        #expect(model.overview?.limits.limits?.dailyMinutes == 60)
        fake.setError = nil
        try await model.setLimits(SupervisionLimits(dailyMinutes: 30))
        #expect(model.overview?.limits.limits?.dailyMinutes == 30)
        #expect(model.overview?.screenTime.count == 1, "the days stay")
    }

    /// A teen reads their own overview (no teen id) and can't edit it; a
    /// supervisor reads the teen's and can.
    @Test func onlyASupervisorEditsAndEachReadsTheRightTeen() async throws {
        let fake = FakeOverview()
        let list = SupervisionListModel(manager: fake)
        let teenView = SupervisionDetailViewController(
            supervision: Self.link(.supervisor, "mum"), list: list, overviewing: fake, imagePipeline: nil, router: nil
        ) { _, _, _ in }
        teenView.loadViewIfNeeded()
        #expect(await settle { teenView.overview?.overview != nil })
        #expect(fake.reads == [nil])
        // The rows land after the bones' minimum when the bones came (#1770).
        #expect(await settle { teenView.dataSource.snapshot().indexOfItem(.limit(title: "Daily Limit", value: "1 hr")) != nil })
        #expect(teenView.dataSource.snapshot().indexOfItem(.editLimits) == nil)

        let parentView = SupervisionDetailViewController(
            supervision: Self.link(.teen, "leo"), list: list, overviewing: fake, imagePipeline: nil, router: nil
        ) { _, _, _ in }
        parentView.loadViewIfNeeded()
        #expect(await settle { parentView.overview?.overview != nil })
        #expect(fake.reads == [nil, "leo"])
        #expect(await settle { parentView.dataSource.snapshot().indexOfItem(.editLimits) != nil })
    }

    /// No limits and no time say so, rather than an empty section.
    @Test func emptyOverviewsSaySo() {
        let empty = SupervisionOverview(limits: SupervisionLimitsState(limits: nil), screenTime: [], profiles: [])
        let items = SupervisionDetailViewController.overviewItems(.loaded(empty), canEdit: true)
        #expect(items.time == [.noTime])
        #expect(items.limits == [.noLimits, .editLimits])
        #expect(SupervisionDetailViewController.overviewItems(.failed, canEdit: true).time == [.overviewFailed])
    }

    /// Save waits for a change, keeps the draft on a refusal, and hands back
    /// once the server agrees.
    @Test func theEditorSavesOnlyAChangeAndOnlyOnceAgreed() async throws {
        let fake = FakeOverview()
        let model = SupervisionOverviewModel(manager: fake, teenAccountID: "t1")
        await model.load()
        var savedCount = 0
        let editor = SupervisionLimitsViewController(model: model, teenName: "Leo") { _ in savedCount += 1 }
        editor.loadViewIfNeeded()
        #expect(!editor.canSave)
        editor.setDailyMinutes(30)
        editor.setMessages(.noOne)
        #expect(editor.canSave)

        fake.setError = .invalidLimit
        editor.save()
        // At work (#1775): the word becomes the loader, under its identifier.
        let busy = editor.ownTrailingBarItems.first
        #expect(busy?.customView != nil, "the Save did not turn into the loader")
        #expect(busy?.identifier == SupervisionLimitsViewController.saveID)
        #expect(await settle { !editor.isSaving })
        #expect(editor.ownTrailingBarItems.first?.title == "Save", "the word did not come back after the failure")
        #expect(editor.ownTrailingBarItems.first?.customView == nil)
        #expect(savedCount == 0)
        #expect(editor.draft.dailyMinutes == 30, "the draft stays to be fixed")

        fake.setError = nil
        editor.save()
        #expect(await settle { savedCount == 1 })
        #expect(fake.saved == [SupervisionLimits(messages: .noOne, dailyMinutes: 30)])
        #expect(model.overview?.limits.limits?.messages == .noOne)
    }

    // MARK: - Copy

    @Test func limitsReadAsRows() {
        let rows = SupervisionCopy.limitRows(SupervisionLimits(privateAccount: true, comments: .mutuals, dailyMinutes: 90))
        #expect(rows.map(\.title) == ["Daily Limit", "Private Account", "Who Can Message", "Who Can Comment", "Hidden from Search"])
        #expect(rows.map(\.value) == ["1 hr, 30 min", "On", "No Limit", "Mutual Followers", "Off"])
        #expect(SupervisionCopy.dailyLimitText(nil) == "Off")
    }

    @Test func daysReadAsTodayYesterdayOrADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_GB")
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
        #expect(SupervisionCopy.dayText("2026-10-13", today: today, calendar: calendar) == "Today")
        #expect(SupervisionCopy.dayText("2026-10-12", today: today, calendar: calendar) == "Yesterday")
        #expect(SupervisionCopy.dayText("2026-10-08", today: today, calendar: calendar).contains("8"))
    }

    /// The teen is told who set the limits and that they can be stricter.
    @Test func theLimitsFooterSaysWhoAndTheRule() {
        let teen = SupervisionCopy.limitsFooter(teen: true, teenName: "", changedBy: "@mum", changedAt: Date())
        #expect(teen.contains("Set by your supervisors"))
        #expect(teen.contains("by @mum"))
        let parent = SupervisionCopy.limitsFooter(teen: false, teenName: "Leo", changedBy: nil, changedAt: nil)
        #expect(parent.contains("Leo can choose stricter settings"))
        #expect(parent.contains("the last change applies"))
    }

    /// A settings change a supervisor's floor holds (PRF-5006) says who set
    /// it; any other failure keeps the screen's words.
    @Test func aLockedSettingSaysItIsSetByTheSupervisor() {
        let locked = ProfileError.transport(message: "PRF-5006: locked by supervision", failure: nil)
        #expect(SupervisionLock.isLocked(locked))
        #expect(SupervisionLock.message(for: locked, fallback: "x") == SupervisionLock.message)
        #expect(SupervisionLock.message(for: ProfileError.transport(message: "PRF-9001", failure: nil), fallback: "x") == "x")
    }
}
