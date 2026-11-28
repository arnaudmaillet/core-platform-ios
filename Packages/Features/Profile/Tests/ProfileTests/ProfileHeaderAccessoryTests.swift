import CoreModels
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile
@testable import ProfileData

/// **The shell's items on the profile's bar (#2475).** The bell leads the
/// own profile's bar; a balance the shell hands in is never shown — no
/// profile, own or someone else's, wears the wallet's badge any more
/// (revising #2336): the wallet is Settings' (Wallet and Purchases).
@MainActor
struct ProfileHeaderAccessoryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// The OWN profile, built with an `onLogout`, which is what gives it the
    /// gear and the bell.
    private func ownProfile() -> ProfileViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: {},
            trayPlacement: .aboveBottomSafeArea
        )
    }

    private func accessory() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Balance"
        return item
    }

    /// ⚠️ NO BALANCE ON A PROFILE (#2475): handed one, the bar shows none —
    /// before a rebuild and after it.
    @Test func aBalanceHandedInIsNeverShown() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let before = screen.navigationItem.rightBarButtonItems ?? []

        screen.setTrailingAccessoryItem(accessory())
        let items = screen.navigationItem.rightBarButtonItems ?? []
        #expect(!items.contains { $0.accessibilityLabel == "Balance" }, "the balance came into the bar")
        #expect(items.elementsEqual(before, by: ===), "a balance handed in moved the bar")

        screen.debugRebuildNavigationState()
        #expect(!(screen.navigationItem.rightBarButtonItems ?? []).contains { $0.accessibilityLabel == "Balance" })
    }

    // MARK: - The own profile's bar (#2475 §4)

    /// ⚠️ THE OWN PROFILE'S BAR AT REST: `[✎][⋯ ⚙]` — the gear in the corner,
    /// ⋯ beside it in the same bubble, ✎ in its own; no switcher (its name
    /// wears the chevron), no title.
    @Test func theOwnProfileCarriesEditThenMoreAndSettings() throws {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: {},
            switcherFactory: ProfileSwitcherMenuFactory(
                switching: StubSwitching(), imagePipeline: ImagePipeline(fetcher: SilentFetcher())
            ),
            trayPlacement: .aboveBottomSafeArea
        )
        screen.loadViewIfNeeded()

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(screen.debugTrailingIDs == ["profile.settings", "profile.more", "profile.edit"])
        // ⋯ and the gear share a bubble; a space keeps ✎ in its own.
        #expect(items.count == 4 && items[2].customView == nil && items[2].image == nil, "no space before ✎")
        #expect(items[3].style == .plain, "✎ is filled at rest")
        #expect(items[1].menu != nil, "⋯ opens no menu")
        #expect(!items.contains { $0.identifier == "profile.switcher" })
        #expect(screen.navigationItem.title == nil, "the own profile is titled")
        // The switcher is the name's.
        #expect(screen.headerView.debugShowsTitleChevron)
    }

    /// Past the threshold: `[✎]`, quiet (the owner, 2026-11-28: the
    /// primary is History's Select) — the SAME item (#2331) — ⋯ and the
    /// gear gone; and back.
    @Test func pastTheThresholdEditIsAlone() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let edit = try #require(screen.debugBarItem(ProfileNavigationBarComposer.editItemID))

        screen.debugSetPastThreshold(true)
        #expect(screen.debugTrailingIDs == ["profile.edit"])
        #expect(screen.debugBarItem(ProfileNavigationBarComposer.editItemID) === edit, "✎ was minted anew")
        #expect(edit.style == .plain, "✎ is filled past the threshold")

        screen.debugSetPastThreshold(false)
        #expect(screen.debugTrailingIDs == ["profile.settings", "profile.more", "profile.edit"])
        #expect(screen.debugBarItem(ProfileNavigationBarComposer.editItemID) === edit)
        #expect(edit.style == .plain)
    }

    /// QR code is a row of the own ⋯ menu (#2475 §4): the header's QR
    /// bubble went with its action row.
    @Test func theOwnMoreMenuHoldsTheQRCode() async throws {
        let viewModel = ProfileViewModel(repository: NamedAccessoryProfiles())
        let screen = ProfileViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: {},
            trayPlacement: .aboveBottomSafeArea
        )
        screen.loadViewIfNeeded()
        for _ in 0..<400 where viewModel.shareCard == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(viewModel.shareCard != nil, "guard: the profile has a share card")
        let rows = screen.debugMoreMenuElements().flatMap { ($0 as? UIMenu)?.children ?? [$0] }.map(\.title)
        #expect(rows.contains("QR Code"), "no QR Code in the own ⋯: \(rows)")
        #expect(rows.contains("Share"))
    }

    /// Someone else's profile, or a pushed one: the name is text alone.
    @Test func aPushedProfilesNameWearsNoChevron() {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        #expect(!screen.headerView.debugShowsTitleChevron)
    }

    /// A pushed own profile — built without `onLogout` — has no gear: its
    /// bar is `[‹] … [✎][⋯]`, and no balance.
    @Test func aPushedOwnProfileCarriesEditAndMoreWithoutTheGear() throws {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: StubAccessoryProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        screen.setTrailingAccessoryItem(accessory())
        #expect(screen.debugTrailingIDs == ["profile.more", "profile.edit"])
    }

    // MARK: - The leading item (the shell's bell)

    /// ⚠️ THE BELL LEADS, ALONE: `[bell]`. The source filter that stood
    /// beside it is gone; its sources are tabs at the foot (#772).
    @Test func theInjectedBellLeadsAlone() throws {
        let screen = ownProfile()
        screen.loadViewIfNeeded()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 1)
        #expect(items.first === bell)
    }

    /// And it survives a rebuild of the bar.
    @Test func theBellSurvivesARebuild() throws {
        let screen = ownProfile()
        let bell = accessory()
        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()

        screen.debugRebuildNavigationState()

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.first === bell, "a rebuild dropped the bell")
    }

    /// Clearing it leaves the leading group empty: no filter stands there any
    /// more (#772).
    @Test func clearingTheBellEmptiesTheLeadingGroup() {
        let screen = ownProfile()
        screen.loadViewIfNeeded()

        screen.setLeadingAccessoryItem(accessory())
        screen.setLeadingAccessoryItem(nil)

        #expect(screen.navigationItem.leftBarButtonItems?.isEmpty != false)
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

/// The viewer's own profile, loaded: what a share card needs.
private struct NamedAccessoryProfiles: ProfileProviding {
    private static let me = UserProfile(
        id: ProfileID("prof-me"), handle: "me", displayName: "Me", bio: "", avatarURL: nil, websiteURL: nil,
        isVerified: false, followerCount: .exact(1), followingCount: .exact(1), reactionCount: .exact(1)
    )
    func currentUserProfile() async throws -> UserProfile { Self.me }
    func profile(id: ProfileID) async throws -> UserProfile { Self.me }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { Self.me }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { Self.me }
}

/// No account behind it — the switcher item only has to exist.
private struct StubSwitching: ProfileSwitching {
    func accountProfiles() async throws -> [AccountProfile] { [] }
    func activeProfileID() async -> ProfileID? { nil }
    func setActiveProfile(_ id: ProfileID) async {}
}
