import Foundation
import Testing
@testable import Auth

private final class FakeLoginService: LoginPerforming, @unchecked Sendable {
    let lock = NSLock()
    var result: Result<LoginOutcome, AuthError> = .success(.signedIn)
    var receivedUsername: String?

    func login(username: String, password: String) async throws -> LoginOutcome {
        try lock.withLock {
            receivedUsername = username
            return try result.get()
        }
    }

    func completeLogin(_ challenge: SecondStepChallenge, code: String) async throws {}
}

@MainActor
struct LoginViewModelTests {
    private func awaitTerminalState(_ viewModel: LoginViewModel) async -> LoginViewModel.State {
        await withCheckedContinuation { continuation in
            viewModel.onStateChange = { state in
                if state != .submitting {
                    viewModel.onStateChange = nil
                    continuation.resume(returning: state)
                }
            }
        }
    }

    @Test func successfulSubmitTrimsUsernameAndReturnsToIdle() async {
        let service = FakeLoginService()
        let viewModel = LoginViewModel(loginService: service)

        viewModel.submit(username: "  demo ", password: "pw")
        #expect(viewModel.state == .submitting)

        #expect(await awaitTerminalState(viewModel) == .idle)
        #expect(service.lock.withLock { service.receivedUsername } == "demo")
    }

    @Test func invalidCredentialsShowActionableMessage() async {
        let service = FakeLoginService()
        service.result = .failure(.invalidCredentials)
        let viewModel = LoginViewModel(loginService: service)

        viewModel.submit(username: "demo", password: "wrong")

        #expect(await awaitTerminalState(viewModel) == .failed(message: "Incorrect username or password."))
    }

    /// Two-step sign-in on (#383): the right password leads to the code,
    /// not to an error.
    @Test func aRightPasswordWithTwoStepOnAsksForTheCode() async {
        let service = FakeLoginService()
        let challenge = SecondStepChallenge(token: "mfa-1", expiresIn: 300)
        service.result = .success(.needsSecondStep(challenge))
        let viewModel = LoginViewModel(loginService: service)
        var asked: SecondStepChallenge?
        viewModel.onSecondStep = { asked = $0 }

        viewModel.submit(username: "demo", password: "pw")

        #expect(await awaitTerminalState(viewModel) == .idle)
        #expect(asked == challenge)
    }

    @Test func secondStepFailuresReadPlainly() {
        #expect(LoginViewModel.message(for: .wrongSecondStepCode).contains("backup code"))
        #expect(LoginViewModel.message(for: .secondStepLocked).contains("Too many"))
        #expect(LoginViewModel.message(for: .secondStepExpired).contains("Sign in again"))
    }

    @Test func emptyFieldsFailFastWithoutCallingService() {
        let service = FakeLoginService()
        let viewModel = LoginViewModel(loginService: service)

        viewModel.submit(username: "   ", password: "")

        #expect(viewModel.state == .failed(message: "Enter your username and password."))
        #expect(service.lock.withLock { service.receivedUsername } == nil)
    }
}
