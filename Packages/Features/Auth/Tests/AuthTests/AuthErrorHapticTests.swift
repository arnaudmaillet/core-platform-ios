import DesignSystem
import Testing
import UIKit
@testable import Auth

/// AN ERROR THE VIEWER'S ATTEMPT MET (#1886): each of the flow's alerts
/// plays `error` once, as it appears.
@MainActor
struct AuthErrorHapticTests {
    @Test(arguments: LoginFlowCoordinator.DebugAlert.allCases)
    func eachAlertPlaysErrorOnce(alert: LoginFlowCoordinator.DebugAlert) {
        let flow = LoginFlowCoordinator()
        _ = flow.start(prompt: nil)
        let played = HapticRecorder.recording { flow.debugPresent(alert) }
        #expect(played == [.error], "\(alert) played \(played)")
    }
}
