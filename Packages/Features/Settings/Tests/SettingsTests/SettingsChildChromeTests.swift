import Testing
import UIKit
@testable import ProfileData
@testable import Settings

/// The chrome Settings' screens ask for (the profile editor's is the
/// profile's `ProfileChildChromeTests`).
///
/// Settings is somewhere you GO — a list you come back from — rather than a
/// place the app keeps four doors open onto. The flag says so, and it is a
/// single line that a refactor drops without anything failing to compile and
/// without any screenshot of the screen itself looking wrong: the tab bar is
/// simply still there, at the bottom, offering four ways to leave.
///
/// It is stated in each screen's own init rather than at the push site so that
/// it holds wherever the screen is pushed from, which is the property these
/// assert — they construct the screens directly, with no profile in sight.
@MainActor
struct SettingsChildChromeTests {
    private actor StubAccount: AccountProviding {
        func currentAccount() async throws -> AccountDetails {
            AccountDetails(
                email: "ada@example.com",
                emailVerified: true,
                phone: "",
                phoneVerified: false,
                country: "FR"
            )
        }
    }

    @Test func accountSettingsHidesTheTabBar() {
        let settings = AccountSettingsViewController(account: StubAccount())
        #expect(settings.hidesBottomBarWhenPushed)
    }

    @Test func settingsAndItsComingSoonPagesHideTheTabBar() {
        let settings = SettingsViewController(switching: nil, switcher: nil, makeDestination: { _ in nil }, onLogout: {})
        #expect(settings.hidesBottomBarWhenPushed)
        #expect(SettingsComingSoonViewController(section: .wallet).hidesBottomBarWhenPushed)
    }

    /// Settings screens are the exception (2026-10-04): UIKit's SOFT top
    /// edge under the bar — see `prefersSoftTopEdge`.
    @Test func accountSettingsWearsTheSoftTopEdge() throws {
        let settings = AccountSettingsViewController(account: StubAccount())
        settings.loadViewIfNeeded()
        let list = try #require(settings.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(!list.topEdgeEffect.isHidden)
        #expect(list.topEdgeEffect.style == .soft)
    }

    @Test func settingsWearsTheSoftTopEdge() throws {
        let settings = SettingsViewController(switching: nil, switcher: nil, makeDestination: { _ in nil }, onLogout: {})
        settings.loadViewIfNeeded()
        let list = try #require(settings.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(!list.topEdgeEffect.isHidden)
        #expect(list.topEdgeEffect.style == .soft)
    }
}
