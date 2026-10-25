import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// EXPERIMENTAL (#1681): off by default; on by the launch argument or the
/// DEBUG switch.
///
/// ⚠️ SERIALIZED, and every test restores the seams before returning with
/// no `await` in between: the flag is process-wide.
@Suite(.serialized)
struct ForYouFullScreenExperimentTests {
    private func withSeams(arguments: [String], _ body: (UserDefaults) -> Void) {
        let savedDefaults = ForYouFullScreenExperiment.defaults
        let savedArguments = ForYouFullScreenExperiment.arguments
        let defaults = UserDefaults(suiteName: "experiments.tests.\(UUID().uuidString)")!
        ForYouFullScreenExperiment.defaults = defaults
        ForYouFullScreenExperiment.arguments = arguments
        defer {
            ForYouFullScreenExperiment.defaults = savedDefaults
            ForYouFullScreenExperiment.arguments = savedArguments
        }
        body(defaults)
    }

    /// The tab bar dark on the For You tab only, and only in the experiment
    /// (#1697).
    @Test func theTabBarIsDarkOnTheForYouTabOnlyInTheExperiment() {
        withSeams(arguments: ["app", "-foryou-fullscreen"]) { _ in
            #expect(ForYouFullScreenExperiment.tabBarStyle(forYouSelected: true) == .dark)
            #expect(ForYouFullScreenExperiment.tabBarStyle(forYouSelected: false) == .unspecified)
        }
        withSeams(arguments: []) { _ in
            #expect(ForYouFullScreenExperiment.tabBarStyle(forYouSelected: true) == .unspecified)
        }
    }

    @Test func itIsOffByDefault() {
        withSeams(arguments: []) { _ in
            #expect(!ForYouFullScreenExperiment.isOn)
        }
    }

    @Test func theLaunchArgumentTurnsItOn() {
        withSeams(arguments: ["app", "-foryou-fullscreen"]) { _ in
            #expect(ForYouFullScreenExperiment.isOn)
        }
    }

    @Test func theSwitchTurnsItOnAndOff() {
        withSeams(arguments: []) { _ in
            ForYouFullScreenExperiment.storedSwitch = true
            #expect(ForYouFullScreenExperiment.isOn)
            ForYouFullScreenExperiment.storedSwitch = false
            #expect(!ForYouFullScreenExperiment.isOn)
        }
    }
}
