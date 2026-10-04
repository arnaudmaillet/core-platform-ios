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
        let login: () async -> Auth_V1_LoginResponse? = {
            var grant = Auth_V1_PasswordGrant()
            grant.username = MockAuthService.defaultCredentials.username
            grant.password = MockAuthService.defaultCredentials.password
            var request = Auth_V1_LoginRequest()
            request.grantType = .password
            request.credential = .password(grant)
            return try? await anonymous.login(request: request, headers: [:]).result.get()
        }
        let session = Session()
        await session.set(try #require(await login()).tokens.accessToken)
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        return Fixture(
            sessions: AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session),
            account: AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session),
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

    // MARK: - Erasure grace period

    /// Requesting deletion schedules it; cancelling withdraws it; a second
    /// cancel says nothing is pending.
    @Test func aPendingDeletionCanBeCancelled() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        try await fixture.account.requestDeletion()
        #expect(try await fixture.account.gdprStatus().deletionRequestedAt != nil)

        try await fixture.account.cancelDeletion()
        #expect(try await fixture.account.gdprStatus().deletionRequestedAt == nil)
        await #expect(throws: DeletionCancelError.nothingPending) { try await fixture.account.cancelDeletion() }
    }

    /// #402's "done when": logging back in cancels a pending deletion.
    @Test func loggingBackInCancelsAPendingDeletion() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
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
