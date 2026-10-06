import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Security and Login → Two-Step Sign-In (#383, backend #649), end
/// to end over the mock: enrol behind a step-up, the backup codes, new codes
/// and off behind a code.
@MainActor
struct TwoStepSignInTests {
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
        let lifecycle: MockAccountLifecycle
    }

    private func fixture(twoStepOn: Bool = false) async throws -> Fixture {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle(twoStepOn: twoStepOn)
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
        var first = try await anonymous.login(request: request, headers: [:]).result.get()
        if first.mfaRequired {
            var second = Auth_V1_CompleteLoginRequest()
            second.mfaToken = first.mfaToken
            second.code = MockAuthService.verificationCode
            first = try await anonymous.completeLogin(request: second, headers: [:]).result.get()
        }
        let session = Session()
        await session.set(first.tokens.accessToken)
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        return Fixture(
            sessions: AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session),
            account: AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session),
            lifecycle: lifecycle
        )
    }

    /// Done when: a user can turn it on — the app's QR code, its first code,
    /// then the backup codes — and the account says it's on.
    @Test func turningOnNeedsAStepUpThenTheFirstCode() async throws {
        let fixture = try await fixture()
        #expect(try await !fixture.account.currentAccount().twoStepOn)
        await #expect(throws: TwoStepError.stepUpRequired) { _ = try await fixture.sessions.startTwoStepEnrollment() }

        try await fixture.sessions.stepUp(password: MockAuthService.defaultCredentials.password)
        let enrollment = try await fixture.sessions.startTwoStepEnrollment()
        #expect(enrollment.secret == MockAccountLifecycle.authenticatorSecret)
        #expect(enrollment.otpauthURI.hasPrefix("otpauth://totp/"))
        await #expect(throws: TwoStepError.wrongCode) { _ = try await fixture.sessions.confirmTwoStepEnrollment(code: "000000") }

        let codes = try await fixture.sessions.confirmTwoStepEnrollment(code: MockAuthService.verificationCode)
        #expect(codes.codes.count == 10)
        #expect(codes.sessionsSignedOut == 2)
        #expect(try await fixture.account.currentAccount().twoStepOn)
    }

    /// With it on, a code from the app (or a backup code) is the step-up for
    /// new backup codes and for turning it off; the old codes stop working.
    @Test func newCodesAndOffNeedACode() async throws {
        let fixture = try await fixture(twoStepOn: true)
        #expect(try await fixture.account.currentAccount().twoStepOn)
        await #expect(throws: StepUpError.wrongCode) { try await fixture.sessions.stepUp(code: "999999") }

        try await fixture.sessions.stepUp(code: MockAuthService.verificationCode)
        let first = try await fixture.sessions.regenerateBackupCodes()
        let second = try await fixture.sessions.regenerateBackupCodes()
        #expect(Set(first.codes).isDisjoint(with: second.codes))

        // A backup code steps up once, and only once.
        let backup = try #require(second.codes.first)
        try await fixture.sessions.stepUp(code: backup.uppercased())
        await #expect(throws: StepUpError.wrongCode) { try await fixture.sessions.stepUp(code: backup) }

        try await fixture.sessions.disableTwoStep()
        #expect(try await !fixture.account.currentAccount().twoStepOn)
        await #expect(throws: TwoStepError.alreadyChanged) { try await fixture.sessions.disableTwoStep() }
    }

    @Test func theSetupKeyReadsInGroupsOfFour() {
        let enrollment = TwoStepEnrollment(secret: "JBSWY3DPEHPK3PXP", otpauthURI: "", expiresIn: 600)
        #expect(enrollment.groupedSecret == "JBSW Y3DP EHPK 3PXP")
        #expect(TwoStepEnrollmentViewController.cleaned("12 34-56 7") == "123456")
        #expect(TwoStepEnrollmentViewController.qrCode(for: "otpauth://totp/x?secret=ABC") != nil)
    }

    @Test func theScreenSaysWhatEachStateMeans() {
        #expect(TwoStepViewController.footer(.status, isOn: false)?.contains("authenticator app") == true)
        #expect(TwoStepViewController.footer(.backupCodes, isOn: true)?.contains("works once") == true)
        #expect(TwoStepViewController.failureMessage(TwoStepError.stepUpRequired).contains("confirm it's you"))
        let codes = BackupCodes(codes: ["aaaaa-bbbbb", "ccccc-ddddd"], sessionsSignedOut: 2)
        #expect(BackupCodesViewController.plainText(codes) == "aaaaa-bbbbb\nccccc-ddddd")
        #expect(BackupCodesViewController.footer(for: codes).contains("other devices were logged out"))
    }
}
