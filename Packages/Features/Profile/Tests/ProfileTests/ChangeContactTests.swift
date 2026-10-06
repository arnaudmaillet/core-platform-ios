import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Account → Email / Phone (#393, backend #651), end to end over
/// the mock: a code to the new address, the change behind a step-up, and the
/// account reading the new address, verified.
@MainActor
struct ChangeContactTests {
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
    }

    private func fixture() async throws -> Fixture {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAuthService(lifecycle: lifecycle).register(on: bff)
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        let host = "https://mock.bff.local"
        let anonymous = Auth_V1_AuthServiceClient(client: ConnectClientFactory.makeUnauthenticated(host: host, httpClient: bff))
        var grant = Auth_V1_PasswordGrant()
        grant.username = MockAuthService.defaultCredentials.username
        grant.password = MockAuthService.defaultCredentials.password
        var request = Auth_V1_LoginRequest()
        request.grantType = .password
        request.credential = .password(grant)
        let login = try await anonymous.login(request: request, headers: [:]).result.get()
        let session = Session()
        await session.set(login.tokens.accessToken)
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        return Fixture(
            sessions: AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session),
            account: AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session)
        )
    }

    /// Done when: the email editor saves for real, and the address arrives
    /// verified.
    @Test func theEmailChangesBehindAStepUpAndACode() async throws {
        let fixture = try await fixture()
        let challenge = try await fixture.sessions.sendContactCode(.email, to: "nina@example.com")
        #expect(challenge.destination == "nina@example.com")

        await #expect(throws: ContactChangeError.stepUpRequired) {
            _ = try await fixture.sessions.changeContact(challenge, code: MockAuthService.verificationCode)
        }
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        await #expect(throws: ContactChangeError.wrongCode) {
            _ = try await fixture.sessions.changeContact(challenge, code: "000000")
        }
        let stored = try await fixture.sessions.changeContact(challenge, code: MockAuthService.verificationCode)
        #expect(stored == "nina@example.com")

        let account = try await fixture.account.currentAccount()
        #expect(account.email == "nina@example.com")
        #expect(account.emailVerified)
    }

    /// Done when: the phone editor saves for real, and the verified seal
    /// follows (the demo phone starts unverified).
    @Test func thePhoneChangesAndIsVerified() async throws {
        let fixture = try await fixture()
        #expect(try await !fixture.account.currentAccount().phoneVerified)
        let number = try #require(ContactAddress.normalized("+33 6 12 34 56 78", kind: .phone))
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        let challenge = try await fixture.sessions.sendContactCode(.phone, to: number)
        _ = try await fixture.sessions.changeContact(challenge, code: MockAuthService.verificationCode)

        let account = try await fixture.account.currentAccount()
        #expect(account.phone == "+33612345678")
        #expect(account.phoneVerified)
    }

    @Test func anotherAccountsAddressIsRefused() async throws {
        let fixture = try await fixture()
        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        let challenge = try await fixture.sessions.sendContactCode(.email, to: MockAuthService.takenEmail)
        await #expect(throws: ContactChangeError.addressTaken) {
            _ = try await fixture.sessions.changeContact(challenge, code: MockAuthService.verificationCode)
        }
        #expect(try await fixture.account.currentAccount().email == "demo@example.com")
    }

    @Test func addressesAreCheckedBeforeACodeGoes() {
        #expect(ContactAddress.normalized("  Nina@Example.COM ", kind: .email) == "nina@example.com")
        #expect(ContactAddress.normalized("nina@example", kind: .email) == nil)
        #expect(ContactAddress.normalized("nina example.com", kind: .email) == nil)
        #expect(ContactAddress.normalized("+1 (555) 010-0199", kind: .phone) == "+15550100199")
        #expect(ContactAddress.normalized("06 12 34 56 78", kind: .phone) == nil, "the country code is required")
        #expect(ContactAddress.normalized("+12", kind: .phone) == nil)
        #expect(ContactAddress.normalized("+33 6 12 ab 56", kind: .phone) == nil)
    }

    @Test func theScreenSaysWhatHappens() {
        #expect(ChangeContactViewController.addressPrompt(.email, current: "demo@example.com").contains("demo@example.com"))
        #expect(ChangeContactViewController.addressFooter(.phone).contains("country code"))
        #expect(ChangeContactViewController.failureMessage(ContactChangeError.addressTaken, kind: .phone).contains("another account"))
        #expect(AccountSettingsViewController.contactChangedNotice(.email, to: "nina@example.com").contains("next time you sign in"))
    }
}
