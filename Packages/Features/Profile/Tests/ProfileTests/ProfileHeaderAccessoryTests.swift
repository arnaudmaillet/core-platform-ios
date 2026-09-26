import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// **The header's injected trailing item — the wallet balance, from the shell.**
///
/// The same number stands in the Maps header and on the post screen, so this
/// screen does not learn what a wallet is: the shell builds one item and hands
/// it over. What this screen promises is that the item stays in its trailing
/// run — and that promise is worth pinning here, because this run is REBUILT.
///
/// `applyNavigationState` composes the bar's items from scratch every time
/// the follow state or the identity moves, and it is guarded by
/// "say nothing unless it changed" — a guard that exists because handing UIKit
/// the same set mid-transition tears the capsule down. An item that arrives
/// from outside has to pass through both.
@MainActor
struct ProfileHeaderAccessoryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// The OWN profile, which is the only one the shell puts a balance on: it
    /// is built with an `onLogout`, which is also what gives it the gear.
    private func ownProfile() -> ProfileViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: {},
            trayPlacement: .aboveBottomSafeArea
        )
    }

    private func accessory() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Balance"
        return item
    }

    /// ⚠️ THE BALANCE STANDS INBOARD, and the gear keeps the corner.
    ///
    /// `rightBarButtonItems[0]` is nearest the screen edge, so appending puts
    /// the balance furthest from it — the same arrangement as the Maps header,
    /// where the coin sits inboard of the bell.
    @Test func theBalanceStandsInboardOfTheScreensOwnItems() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count > 1, "the screen's own trailing items went missing")
        #expect(items.last === badge, "the balance took the corner")
    }

    /// ⚠️ AND IT SURVIVES A REBUILD.
    ///
    /// The run is recomposed whenever the screen's state moves. Nothing about
    /// that state knows about an injected item, so the recomposition is exactly
    /// where one gets dropped.
    @Test func theBalanceSurvivesARebuildOfTheTrailingRun() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let badge = accessory()
        screen.setTrailingAccessoryItem(badge)

        screen.debugRebuildNavigationState()

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.contains { $0 === badge }, "a rebuild dropped the injected item")
    }

    /// Replacing swaps rather than accumulates — the badge hands over a FRESH
    /// item every time its count changes width, because a bar measures a custom
    /// view once, at install.
    @Test func replacingTheItemLeavesOneOfIt() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(accessory())
        let before = try #require(screen.navigationItem.rightBarButtonItems).count
        let second = accessory()
        screen.setTrailingAccessoryItem(second)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == before)
        #expect(items.last === second)
    }

    /// And clearing it leaves the screen exactly as it was.
    @Test func clearingItRestoresTheRun() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let before = try #require(screen.navigationItem.rightBarButtonItems).count

        screen.setTrailingAccessoryItem(accessory())
        screen.setTrailingAccessoryItem(nil)

        #expect(screen.navigationItem.rightBarButtonItems?.count == before)
    }

    // MARK: - The own profile's pair

    /// ⚠️ THE TAB ROOT READS `[coins][share settings]`: the gear at the corner,
    /// Share inboard of it, the balance inboard of both — and Share and the
    /// gear SHARE one capsule (neither opts out of the bar's shared
    /// background), while the balance, which does opt out, stands alone.
    @Test func theOwnProfileCarriesSettingsThenShareThenTheBalance() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let badge = accessory()
        badge.sharesBackground = false

        screen.setTrailingAccessoryItem(badge)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.map(\.accessibilityLabel) == ["Settings", "Share Profile", "Balance"])
        #expect(items[0].sharesBackground && items[1].sharesBackground,
                "share and settings no longer read as one capsule")
    }

    /// A pushed profile — built without `onLogout` — has neither: its trailing
    /// run is whatever the shell hands in, the balance alone.
    @Test func aPushedProfileCarriesOnlyTheBalance() throws {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 1)
        #expect(items.first === badge)
    }

    // MARK: - The leading item (the shell's bell)

    /// ⚠️ THE BELL LEADS, AHEAD OF THE SOURCE FILTER: `[bell][filter]`.
    @Test func theInjectedBellLeadsAheadOfTheSourceFilter() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 2)
        #expect(items.first === bell, "the filter took the corner from the bell")
        #expect(items.last?.accessibilityLabel == "Content source")
    }

    /// And, like the balance, it survives a rebuild of the bar.
    @Test func theBellSurvivesARebuild() throws {
        let screen = ownProfile()
        let bell = accessory()
        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()

        screen.debugRebuildNavigationState()

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.first === bell, "a rebuild dropped the bell")
    }

    /// Clearing it leaves the filter alone in the leading group.
    @Test func clearingTheBellLeavesTheFilter() {
        let screen = ownProfile()
        screen.loadViewIfNeeded()

        screen.setLeadingAccessoryItem(accessory())
        screen.setLeadingAccessoryItem(nil)

        #expect(screen.navigationItem.leftBarButtonItems?.count == 1)
    }
}

private struct StubAccessoryProfiles: ProfileProviding {
    func currentUserProfile() async throws -> UserProfile { throw CancellationError() }
    func profile(id: ProfileID) async throws -> UserProfile { throw CancellationError() }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { throw CancellationError() }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { throw CancellationError() }
}
