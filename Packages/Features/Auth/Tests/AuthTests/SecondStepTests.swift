import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Auth

/// Two-step sign-in's second step (#383, backend #649), through the whole
/// client stack against the mock: an emailed code is proven
/// but no session exists until the authenticator's code or a backup code.
struct SecondStepTests {
    private func makeManager() -> (SessionManager, InMemorySessionStore) {
        let bff = MockBFF()
        MockAuthService(lifecycle: MockAccountLifecycle(twoStepOn: true)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let store = InMemorySessionStore()
        let manager = SessionManager(
            authClient: Auth_V1_AuthServiceClient(client: client),
            store: store,
            configuration: .init(deviceID: "second-step-device")
        )
        return (manager, store)
    }

    private func codeChallenge(_ manager: SessionManager) async throws -> SecondStepChallenge {
        guard let challenge = try await manager.demoSecondStep() else {
            Issue.record("the code signed in without a second step")
            throw CancellationError()
        }
        return challenge
    }

    /// The second step's account becomes the session.
    private func finish(_ manager: SessionManager, _ challenge: SecondStepChallenge, code: String) async throws {
        let account = try await manager.completeSecondStep(challenge, code: code)
        await manager.completeSignIn(account)
    }

    /// Done when: a user with two-step on signs in with a code.
    @Test func theCodeAloneIsNotASession() async throws {
        let (manager, store) = makeManager()
        let challenge = try await codeChallenge(manager)
        #expect(challenge.expiresIn > 0)
        #expect(await manager.currentState() == .unauthenticated)
        #expect(try store.load() == nil)

        await #expect(throws: AuthError.wrongSecondStepCode) {
            try await finish(manager, challenge, code: "000000")
        }
        // A wrong code leaves the challenge usable.
        try await finish(manager, challenge, code: MockAuthService.verificationCode)
        #expect(await manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))
        #expect(try store.load() != nil)
    }

    @Test func fiveWrongCodesLockTheSignIn() async throws {
        let (manager, _) = makeManager()
        let challenge = try await codeChallenge(manager)
        for _ in 0..<5 {
            await #expect(throws: AuthError.wrongSecondStepCode) { try await finish(manager, challenge, code: "000000") }
        }
        await #expect(throws: AuthError.secondStepLocked) {
            try await finish(manager, challenge, code: MockAuthService.verificationCode)
        }
    }

    /// A used or unknown challenge means signing in again.
    @Test func aUsedChallengeMeansSigningInAgain() async throws {
        let (manager, _) = makeManager()
        let challenge = try await codeChallenge(manager)
        try await finish(manager, challenge, code: MockAuthService.verificationCode)
        await #expect(throws: AuthError.secondStepExpired) {
            try await finish(manager, challenge, code: MockAuthService.verificationCode)
        }
    }

    /// An emailed code proves the address, then the app's code: the account
    /// comes back pending, so the flow can check its profile first (#548).
    @Test func anEmailedCodeAlsoNeedsTheSecondStep() async throws {
        let (manager, _) = makeManager()
        let sent = try await manager.startVerification(.email, to: MockAuthService.demoEmail)
        let answer = try await manager.signIn(challengeID: sent.id, code: MockAuthService.verificationCode)
        guard case .needsSecondStep(let challenge) = answer else {
            Issue.record("the emailed code signed in without a second step")
            return
        }
        let account = try await manager.completeSecondStep(challenge, code: MockAuthService.verificationCode)
        #expect(account.accountID == AccountID(MockAuthService.accountID))
        #expect(await manager.currentState() == .unauthenticated, "pending until completeSignIn")
        await manager.completeSignIn(account)
        #expect(await manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))
    }

    /// An AuthError keeps WHY the call failed (#794): a lost connection
    /// (the URLError Connect attaches) reads offline, a bare `unavailable`
    /// is a server's answer, and `offline` (#791) says it already.
    @Test func anAuthErrorKeepsWhyTheCallFailed() {
        let lost = ConnectError(code: .unavailable, message: nil, exception: URLError(.notConnectedToInternet))
        #expect(AuthError.loginFailure(lost).networkFailure == .offline)
        #expect(AuthError.secondStepFailure(lost).networkFailure == .offline)

        let outage = ConnectError(code: .unavailable, message: "down")
        #expect(AuthError.loginFailure(outage).networkFailure == .server(code: "unavailable"))
        #expect(AuthError.offline.networkFailure == .offline)
        #expect(AuthError.invalidCredentials.networkFailure == nil)
    }

    @MainActor
    @Test func theCodeFieldKeepsToItsMode() {
        typealias Step = SecondStepViewController
        #expect(Step.cleaned("12 34 567", mode: .authenticator) == "123456")
        #expect(Step.isComplete("123456", mode: .authenticator))
        #expect(Step.cleaned("ABCDE fghij", mode: .backupCode) == "abcde-fghij")
        #expect(Step.cleaned("abc", mode: .backupCode) == "abc")
        #expect(Step.isComplete("abcde-fghij", mode: .backupCode))
        #expect(!Step.isComplete("abcde-fghi", mode: .backupCode))
    }
}
