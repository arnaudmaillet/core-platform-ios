import Testing
import UIKit
@testable import CoreNavigation

/// The shell's bar holds three places and no "+" (#2489): Profile apart by
/// default, the three in one bubble under `-tabbar-grouped`.
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

    @Test func profileStandsApartByDefault() {
        #expect(ShellTabs.layout(arguments: ["app"]) == .profileApart)
        #expect(ShellTabs.prominentTab(in: .profileApart) == .profile)
    }

    @Test func theGroupedFlagNamesNoTab() {
        #expect(ShellTabs.layout(arguments: ["app", "-tabbar-grouped"]) == .grouped)
        #expect(ShellTabs.prominentTab(in: .grouped) == nil)
    }

    /// On iOS 27 the controller's `prominentTabIdentifier` names Profile, or
    /// nothing when grouped. iOS 26 has no such property: nothing is set.
    @Test func theControllerIsToldWhichTabStandsApart() {
        let controller = UITabBarController()
        let getter = NSSelectorFromString("prominentTabIdentifier")
        ShellTabs.applyProminence(.profileApart, to: controller)
        guard controller.responds(to: getter) else { return }
        #expect(controller.value(forKey: "prominentTabIdentifier") as? String == AppTab.profile.rawValue)
        ShellTabs.applyProminence(.grouped, to: controller)
        #expect(controller.value(forKey: "prominentTabIdentifier") as? String == nil)
    }
}
