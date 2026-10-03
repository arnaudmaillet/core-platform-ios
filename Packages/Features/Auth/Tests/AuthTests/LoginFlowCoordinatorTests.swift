import Testing
import UIKit
@testable import Auth

private struct NoLogin: LoginPerforming {
    func login(username: String, password: String) async throws {}
}

@MainActor
struct LoginFlowCoordinatorTests {
    private func firstScreen(of flow: UIViewController) throws -> UIViewController {
        let navigation = try #require(flow as? UINavigationController)
        return try #require(navigation.viewControllers.first)
    }

    /// Presented over the app for a guest, the flow can be closed.
    @Test func presentedOverTheAppItCarriesAWorkingCloseButton() throws {
        var closed = false
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start { closed = true }

        let close = try #require(try firstScreen(of: flow).navigationItem.leftBarButtonItem)
        close.primaryAction?.performWithSender(nil, target: nil)

        #expect(closed)
    }

    /// Installed without a way out, it offers none.
    @Test func withoutACloseHandlerItHasNoCloseButton() throws {
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start()

        #expect(try firstScreen(of: flow).navigationItem.leftBarButtonItem == nil)
    }
}
