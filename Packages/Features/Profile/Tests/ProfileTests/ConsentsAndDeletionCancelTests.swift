import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import DesignSystem
import Foundation
import Testing
@testable import Profile

/// Settings → Ads and Data → consents (#395) and the erasure grace period
/// (#402), end to end over the mock (backend #653).
@MainActor
@Suite(.serialized)
struct ConsentsAndDeletionCancelTests {
    private actor Session: AuthTokenProviding, AccessTokenInstalling, AuthSessionProviding {
        var token: String?
        func set(_ value: String) { token = value }
        func validAccessToken() async throws -> String? { token }
        func installStepUpToken(_ accessToken: String, expiresIn: Int64) async { token = accessToken }
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private struct Fixture {
        let sessions: AccountSessionsRepository
        let account: AccountRepository
        let login: () async -> Auth_V1_LoginResponse?
    }

    private func fixture() async throws -> Fixture {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAuthService(lifecycle: lifecycle).register(on: bff)
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        let host = "https://mock.bff.local"
        let anonymous = Auth_V1_AuthServiceClient(client: ConnectClientFactory.makeUnauthenticated(host: host, httpClient: bff))
        let login: () async -> Auth_V1_LoginResponse? = { await MockCodeSignIn.login(anonymous) }
        let session = Session()
        await session.set(try #require(await login()).tokens.accessToken)
        // The sign-in that minted it was long ago: a gated call needs a
        // fresh proof (#840).
        lifecycle.forgetRecentProofs()
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        let account = AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session)
        return Fixture(
            sessions: AccountSessionsRepository(
                authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session,
                account: account, reauthenticator: CodeReauthenticator(anonymous: anonymous, session: session)
            ),
            account: account,
            login: login
        )
    }

    // MARK: - Consents

    /// A change is applied, stamped, and only to the consent changed.
    @Test func withdrawingAConsentIsRecordedWithItsDate() async throws {
        let fixture = try await fixture()
        let before = try await fixture.account.consents()
        #expect(before.analytics.isGiven)
        #expect(!before.marketing.isGiven)

        let after = try await fixture.account.updateConsents(marketing: nil, analytics: false)
        #expect(!after.analytics.isGiven)
        #expect(after.analytics.changedAt != nil)
        #expect(after.marketing == before.marketing)
        #expect(after.dataProcessing.isGiven)

        let given = try await fixture.account.updateConsents(marketing: true, analytics: nil)
        #expect(given.marketing.isGiven)
        #expect(given.marketing.changedAt != nil)
    }

    @Test func statusReadsAsGivenOrWithdrawnWithTheDate() {
        #expect(ConsentsViewController.statusText(.init(isGiven: false)) == "Not given")
        #expect(ConsentsViewController.statusText(.init(isGiven: true, changedAt: Date())).hasPrefix("Given on "))
        #expect(ConsentsViewController.statusText(.init(isGiven: false, changedAt: Date())).hasPrefix("Withdrawn on "))
    }

    // MARK: - One save after another (#1775)

    /// The other switch stays usable while one travels: its change is shown
    /// at once and sent once the first is saved — one `updateConsents` at a
    /// time, in order. The same switch again sends nothing.
    @Test(.timeLimit(.minutes(10))) func aSecondConsentWaitsItsTurn() async {
        let stub = GatedConsents()
        let model = ConsentsViewModel(manager: stub)
        await model.load()
        #expect(!model.isGiven(.marketing))

        let first = Task { await model.set(.marketing, to: true) }
        await stub.waitForUpdate()
        #expect(model.isSaving(.marketing))
        #expect(model.isGiven(.marketing))
        #expect(await model.set(.marketing, to: false) == .ignored)
        let second = Task { await model.set(.analytics, to: false) }
        while !model.isSaving(.analytics) { await Task.yield() }
        #expect(!model.isGiven(.analytics), "the second flip was not shown as made")
        #expect(await stub.updates == 1, "the second change went out beside the first")

        await stub.release()
        #expect(await first.value == .saved)
        await stub.waitForUpdate(2)
        await stub.release()
        #expect(await second.value == .saved)
        #expect(await stub.updates == 2)
        #expect(!model.isSaving)
        #expect(model.consents?.marketing.isGiven == true)
        #expect(model.consents?.analytics.isGiven == false)
    }

    /// A failed save leaves the record as it was, and the switch's value
    /// goes back with it.
    @Test(.timeLimit(.minutes(10))) func aFailedSaveRollsTheSwitchBack() async {
        let stub = GatedConsents(failsUpdate: true)
        let model = ConsentsViewModel(manager: stub)
        await model.load()
        let before = model.phase

        let flip = Task { await model.set(.analytics, to: false) }
        await stub.waitForUpdate()
        #expect(!model.isGiven(.analytics))
        await stub.release()
        #expect(await flip.value == .failed)
        #expect(model.phase == before)
        #expect(model.isGiven(.analytics))
        #expect(!model.isSaving)
    }

    // MARK: - Erasure grace period

    /// Requesting deletion schedules it; cancelling withdraws it; a second
    /// cancel says nothing is pending.
    @Test func aPendingDeletionCanBeCancelled() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.reconfirmWithTheSentCode()
        try await fixture.account.requestDeletion()
        #expect(try await fixture.account.gdprStatus().deletionRequestedAt != nil)

        try await fixture.account.cancelDeletion()
        #expect(try await fixture.account.gdprStatus().deletionRequestedAt == nil)
        await #expect(throws: DeletionCancelError.nothingPending) { try await fixture.account.cancelDeletion() }
    }

    /// #402's "done when": logging back in cancels a pending deletion.
    @Test func loggingBackInCancelsAPendingDeletion() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.reconfirmWithTheSentCode()
        try await fixture.account.requestDeletion()

        let back = try #require(await fixture.login())
        #expect(back.reactivated)
        #expect(try await fixture.account.gdprStatus().deletionRequestedAt == nil)
    }

    /// The welcome after that login says the deletion was cancelled only
    /// when it was asked for on this iPhone, and once.
    @Test func theWelcomeKnowsADeletionWasAskedHere() {
        let previous = PendingDeletionNotice.defaults
        defer { PendingDeletionNotice.defaults = previous }
        PendingDeletionNotice.defaults = UserDefaults(suiteName: "deletion-notice-\(UUID().uuidString)")!
        #expect(!PendingDeletionNotice.consume())
        PendingDeletionNotice.recordRequest()
        #expect(PendingDeletionNotice.consume())
        #expect(!PendingDeletionNotice.consume())
    }
}

/// Consents whose saves wait for the test to let them through, so a second
/// flip can be tried while the first is in flight.
private actor GatedConsents: AccountConsentManaging {
    private let failsUpdate: Bool
    private(set) var updates = 0
    private var record = AccountConsents(
        dataProcessing: .init(isGiven: true), marketing: .init(isGiven: false), analytics: .init(isGiven: true)
    )
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var releasedEarly = false

    init(failsUpdate: Bool = false) {
        self.failsUpdate = failsUpdate
    }

    func consents() async throws -> AccountConsents { record }

    func updateConsents(marketing: Bool?, analytics: Bool?) async throws -> AccountConsents {
        updates += 1
        arrival?.resume()
        arrival = nil
        if releasedEarly {
            releasedEarly = false
        } else {
            await withCheckedContinuation { held = $0 }
        }
        if failsUpdate { throw AccountError.transport(message: "down") }
        if let marketing { record.marketing = .init(isGiven: marketing, changedAt: Date(timeIntervalSince1970: 1)) }
        if let analytics { record.analytics = .init(isGiven: analytics, changedAt: Date(timeIntervalSince1970: 1)) }
        return record
    }

    /// Returns once `count` updates have reached the stub.
    func waitForUpdate(_ count: Int = 1) async {
        guard updates < count else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    /// Lets the update in flight answer.
    func release() {
        if let held {
            held.resume()
            self.held = nil
        } else {
            releasedEarly = true
        }
    }
}
