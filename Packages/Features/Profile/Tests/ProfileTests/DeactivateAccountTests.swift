import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Account → Deactivate Account (#385), end to end over the mock:
/// step-up first (backend #648), then the deactivation it unlocks, then the
/// login that reactivates the account (backend #650).
@MainActor
struct DeactivateAccountTests {
    /// Vends the session's access token and takes a step-up's fresh one, as
    /// the app's `SessionManager` does.
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
        let first = try #require(await login())
        await session.set(first.tokens.accessToken)
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        return Fixture(
            sessions: AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session),
            account: AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session),
            login: login
        )
    }

    /// The server gates it: without a fresh step-up the app is told to ask
    /// for the password, not that something broke.
    @Test func deactivatingWithoutAStepUpAsksForThePassword() async throws {
        let fixture = try await fixture()
        await #expect(throws: AccountError.stepUpRequired) { try await fixture.account.deactivate() }
    }

    @Test func aWrongPasswordIsSaidAsSuch() async throws {
        let fixture = try await fixture()
        await #expect(throws: StepUpError.wrongPassword) { try await fixture.sessions.stepUp(password: "nope") }
    }

    /// Step-up, deactivate, and the next login reactivates the account and
    /// says so, once.
    @Test func aSteppedUpDeactivationIsUndoneByLoggingBackIn() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        try await fixture.account.deactivate()
        let back = try #require(await fixture.login())
        #expect(back.reactivated)
        let again = try #require(await fixture.login())
        #expect(!again.reactivated)
    }

    /// Deletion is gated the same way (#648): refused without a fresh
    /// step-up, accepted right after one.
    @Test func deletionIsGatedByTheStepUpToo() async throws {
        let fixture = try await fixture()
        await #expect(throws: AccountError.stepUpRequired) { try await fixture.account.requestDeletion() }
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        try await fixture.account.requestDeletion()
        let status = try await fixture.account.gdprStatus()
        #expect(status.deletionRequestedAt != nil)
    }
}
