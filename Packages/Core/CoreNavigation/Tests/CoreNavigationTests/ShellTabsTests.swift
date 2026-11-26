import Testing
import UIKit
@testable import CoreNavigation

/// The shell's bar holds three places and no "+" (#2489), in one centred
/// bubble for a member and a guest alike: no tab stands apart (#2579).
@MainActor
struct ShellTabsTests {
    @Test func aMembersBarHoldsTheThreePlacesInOrder() {
        #expect(ShellTabs.tabs(isMember: true) == [.explore, .messages, .profile])
    }

    /// Messages leaves a guest's bar; Profile stays, dressed as Settings.
    @Test func aGuestsBarHoldsExploreAndTheProfileTab() {
        #expect(ShellTabs.tabs(isMember: false) == [.explore, .profile])
    }

    /// `-select-tab N` indexes `AppTab.allCases`, and the routes name the
    /// cases: the bar's order is theirs, so 0, 1 and 2 still land on
    /// Explore, Messages and Profile.
    @Test func selectTabIndicesStillNameTheSamePlaces() {
        #expect(AppTab.allCases == [.explore, .messages, .profile])
        #expect(ShellTabs.tabs(isMember: true) == AppTab.allCases)
        #expect(AppTab.allCases.map(\.rawValue) == ["explore", "messages", "profile"])
    }

    /// On iOS 27 the controller's `prominentTabIdentifier` names no tab once
    /// the shell has drawn its bar, a member's as a guest's, even where
    /// Profile stood apart before. iOS 26 has no such property: nothing is
    /// set, and the test stops there.
    @Test(arguments: [true, false])
    func noTabStandsApart(isMember: Bool) {
        let controller = UITabBarController()
        controller.tabs = ShellTabs.tabs(isMember: isMember).map { place in
            UITab(title: place.rawValue, image: nil, identifier: place.rawValue) { _ in UIViewController() }
        }
        let getter = NSSelectorFromString("prominentTabIdentifier")
        guard controller.responds(to: getter) else { return }
        controller.setValue(AppTab.profile.rawValue, forKey: "prominentTabIdentifier")

        ShellTabs.drawAsOneBubble(controller)

        #expect(controller.value(forKey: "prominentTabIdentifier") as? String == nil)
    }
}
