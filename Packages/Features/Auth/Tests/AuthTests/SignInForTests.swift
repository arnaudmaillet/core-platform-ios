import CoreNetworkingMocks
@testable import Auth

/// How a test signs in since passwords went (#840): a code, and the account
/// becomes the session.
extension SessionManager {
    /// Against a scripted client, whose `Login` answers whatever it is told:
    /// the challenge and code are moot.
    func signInWithCode(challengeID: String = "ch-test", code: String = "123456") async throws {
        switch try await signIn(challengeID: challengeID, code: code) {
        case .existing(let account):
            completeSignIn(account)
        case .needsSecondStep, .needsSignUp:
            throw AuthError.identityRejected
        }
    }

    /// Against the mock: the demo account's real code sign-in.
    func signInAsDemo() async throws {
        let challenge = try await startVerification(.email, to: MockAuthService.demoEmail)
        try await signInWithCode(challengeID: challenge.id, code: MockAuthService.verificationCode)
    }

    /// Against the mock, two-step on: the second step's challenge.
    func demoSecondStep() async throws -> SecondStepChallenge? {
        let challenge = try await startVerification(.email, to: MockAuthService.demoEmail)
        if case .needsSecondStep(let step) = try await signIn(challengeID: challenge.id, code: MockAuthService.verificationCode) {
            return step
        }
        return nil
    }
}
