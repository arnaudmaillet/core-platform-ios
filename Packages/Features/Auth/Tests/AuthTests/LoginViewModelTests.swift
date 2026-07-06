import Foundation
import Testing
@testable import Auth

private final class FakeLoginService: LoginPerforming, @unchecked Sendable {
    let lock = NSLock()
    var result: Result<Void, AuthError> = .success(())
    var receivedUsername: String?

    func login(username: String, password: String) async throws {
        try lock.withLock {
            receivedUsername = username
            return try result.get()
        }
    }
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

    @Test func emptyFieldsFailFastWithoutCallingService() {
        let service = FakeLoginService()
        let viewModel = LoginViewModel(loginService: service)

        viewModel.submit(username: "   ", password: "")

        #expect(viewModel.state == .failed(message: "Enter your username and password."))
        #expect(service.lock.withLock { service.receivedUsername } == nil)
    }
}
