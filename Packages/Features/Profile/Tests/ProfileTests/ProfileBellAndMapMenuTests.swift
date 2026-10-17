import CoreModels
import CoreNavigation
import DesignSystem
import Foundation
import MapsInterface
import MediaCore
import Testing
import UIKit
@testable import Profile

/// **Mute is a bell in the bar; the map star is a "Map" submenu of see-more
/// (#689, the owner's call 2026-10-08).**
///
/// On someone else's profile the bar reads `[coins][bell]` (the bell in the
/// corner), the bell opens
/// the scoped Mute menu and wears `bell.slash` once anything is muted; the
/// see-more menu loses Mute and gains Map — Map Dock / Following Filter, and
/// Friends Filter for a mutual — on a followed profile only. The header's row
/// reads Follow · Message · QR · ⋯.
@MainActor
struct ProfileBellAndMapMenuTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func makeScreen(
        relationship: ProfileRelationship,
        muting: Bool = true,
        pinning: Bool = true,
        own: Bool = false
    ) -> (ProfileViewController, ProfileViewModel, StubProfiles) {
        let repository = StubProfiles(relationship: relationship)
        let viewModel = ProfileViewModel(
            repository: muting ? repository : StubProfilesWithoutMute(base: repository),
            mapPinning: pinning ? StubPinning() : nil,
            source: own ? .currentUser : .profile(subject.id)
        )
        let screen = ProfileViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: own ? {} : nil,
            trayPlacement: .aboveBottomSafeArea
        )
        let coins = UIBarButtonItem(customView: UIView())
        coins.accessibilityLabel = "Balance"
        screen.setTrailingAccessoryItem(coins)
        screen.loadViewIfNeeded()
        return (screen, viewModel, repository)
    }

    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            guard let menu = element as? UIMenu else { return [element.title] }
            return [menu.title] + titles(menu.children)
        }
    }

    private func mapSubmenu(_ screen: ProfileViewController) -> UIMenu? {
        func find(_ elements: [UIMenuElement]) -> UIMenu? {
            for case let menu as UIMenu in elements {
                if menu.title == "Map" { return menu }
                if let found = find(menu.children) { return found }
            }
            return nil
        }
        return find(screen.debugMoreMenuElements())
    }

    // MARK: - The bell

    /// On screen `[coins][bell]`: the bell keeps the corner, a fixed space
    /// keeps the two bubbles apart.
    /// ⚠️ A PUSHED PROFILE POPS WITH THE SYSTEM'S SWIPE (#1324): it carries
    /// no slide of its own and installs no stack delegate; it only says where
    /// the swipe may begin — anywhere on its first tab (the others page, by
    /// the shared policy), and never at a root.
    @Test func aPushedProfileGatesTheSystemSwipe() {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(screen, animated: false)
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.layoutIfNeeded()
        let header = CGPoint(x: 200, y: 120)
        #expect(screen.allowsContentPop(beginningAt: header, in: screen.view))
        #expect(nav.delegate == nil, "the profile installed a stack delegate")
        // The later tabs' refusal is the policy's (`ProfileDismissalPolicyTests`):
        // this screen asks it with its pager's live index.
    }

    @Test func aProfileAtTheRootNeverAsksForTheSwipe() {
        let (screen, _, _) = makeScreen(relationship: .me, own: true)
        _ = UINavigationController(rootViewController: screen)
        #expect(!screen.allowsContentPop(beginningAt: CGPoint(x: 200, y: 120), in: screen.view))
    }

    /// The own profile, the Profile tab's root, answers the shell's re-tap
    /// (#1309) and comes back to the profile's top.
    @Test func theOwnProfileAnswersATabReTap() {
        let (screen, _, _) = makeScreen(relationship: .me, own: true)
        let stack = UINavigationController(rootViewController: screen)
        let target = TabReselect.target(tappedSelectedTab: true, stack: stack)
        #expect(target === screen)
        target?.scrollToTopForTabReselect()
        #expect(screen.galleryPager.verticalOffset <= 0.5)
    }

    @Test func aFollowedProfileShowsTheBellInTheCorner() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.debugMuteBellItem != nil })
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.first === screen.debugMuteBellItem, "the bell lost the corner")
        #expect(items.last?.accessibilityLabel == "Balance")
        #expect(items.count == 3, "no space between the bell and the balance")
        #expect(screen.debugMuteBellItem?.accessibilityLabel == "Notifications")
    }

    /// The glyph follows the scopes: `bell.slash` once one is muted, `bell`
    /// again when none is — and the menu's checkmarks with it.
    @Test func theBellsGlyphFollowsTheMutedScopes() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        // The bell is up from frame 0 (#778); muting waits for the
        // relationship to say whose profile this is.
        let bell = try #require(
            await settle { screen.debugMuteBellItem != nil && viewModel.canModerate } ? screen.debugMuteBellItem : nil
        )
        #expect(bell.image == UIImage(systemName: "bell"))

        viewModel.toggleMute(.posts)
        try #require(await settle { bell.image == UIImage(systemName: "bell.slash") })
        #expect(bell.accessibilityValue == "Muted: Posts")
        let menu = try #require(screen.debugMuteMenuElements().first as? UIMenu)
        #expect(menu.title == "Muted")
        #expect(menu.subtitle == "Posts")
        let states = menu.children.compactMap { $0 as? UIAction }.map { ($0.title, $0.state) }
        #expect(states.map(\.0) == ["Posts", "Stories", "Messages"])
        #expect(states.map(\.1) == [.on, .off, .off])
        try #require(await settle { repository.lastScopes == MuteScopes(posts: true) })

        // Wait for the first write to land before the second toggle: one at a time.
        try #require(await settle { !viewModel.muteInFlight })
        viewModel.toggleMute(.posts)
        try #require(await settle { bell.image == UIImage(systemName: "bell") })
        #expect(bell.accessibilityValue == "Nothing muted")
        #expect((screen.debugMuteMenuElements().first as? UIMenu)?.title == "Mute")
    }

    /// Not followed: NO bell (the owner, 2026-10-15 — nothing of theirs to
    /// mute yet; the corner goes to the bar's Follow), and see-more has no
    /// Map submenu.
    @Test func anUnfollowedProfileHasNoBellAndNoMapSubmenu() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugMuteBellItem == nil, "a bell on a profile the viewer does not follow")
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"])
        #expect(mapSubmenu(screen) == nil)
    }

    /// Your own profile: no bell, the bar as it was.
    @Test func yourOwnProfileHasNoBell() async {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        await settle { viewModel.isRelationshipSettled }
        #expect(screen.debugMuteBellItem == nil)
    }

    /// A composition that cannot mute shows no bell.
    @Test func noMutingNoBell() async {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false), muting: false)
        await settle { viewModel.canModerate }
        #expect(screen.debugMuteBellItem == nil)
    }

    // MARK: - The see-more menu

    /// See-more has no Mute entry any more; Restrict, Block and Report stay.
    @Test func seeMoreLostMute() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { viewModel.canModerate })
        let all = titles(screen.debugMoreMenuElements())
        #expect(!all.contains("Mute") && !all.contains("Muted"), "\(all)")
        #expect(all.contains("Block"))
        #expect(all.contains("Report"))
    }

    /// Followed: Map Dock and Following Filter, toggling as the star did and
    /// keeping the menu open. Mutual: Friends Filter too.
    @Test(arguments: [false, true])
    func aFollowedProfileHasTheMapSubmenu(mutual: Bool) async throws {
        let (screen, viewModel, _) = makeScreen(
            relationship: .other(isFollowing: true, isMutual: mutual, isBlocked: false)
        )
        try #require(await settle { viewModel.mapPinButton != .hidden })
        let map = try #require(mapSubmenu(screen))
        let rows = map.children.compactMap { $0 as? UIAction }
        #expect(rows.map(\.title) == (mutual
            ? ["Map Dock", "Following Filter", "Friends Filter"]
            : ["Map Dock", "Following Filter"]))
        #expect(rows.allSatisfy { $0.attributes.contains(.keepsMenuPresented) })
        #expect(rows.allSatisfy { $0.state == .off })
        #expect(map.subtitle == nil)

        viewModel.toggleMapCategory(.dock)
        try #require(await settle { viewModel.mapPinButton.categories == [.dock] })
        let after = try #require(mapSubmenu(screen))
        #expect(after.children.compactMap { $0 as? UIAction }.first?.state == .on)
        #expect(after.subtitle == "Map Dock")
        #expect(after.image == UIImage(systemName: "mappin.circle.fill"))
    }

    /// No pinning service wired: no Map submenu even on a followed profile.
    @Test func noPinningNoMapSubmenu() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false), pinning: false)
        try #require(await settle { viewModel.canModerate })
        #expect(mapSubmenu(screen) == nil)
    }

    // MARK: - The header's row

    /// Follow · Message · QR · ⋯ — no star.
    @Test func theRowHasNoStar() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configureAction(.following)
        let symbols = header.debugTrayButtons.filter { !$0.isHidden }
            .compactMap { $0.configuration?.image?.description }
        #expect(header.debugTrayButtons.count == 5)
        #expect(!symbols.contains { $0.contains("star") }, "\(symbols)")
    }
}

// MARK: - The bar's relationship (the owner, 2026-10-15)

/// Once the header's action tray has scrolled out of sight, the bar carries
/// the relationship, inboard of the balance: a pink Follow while the viewer
/// does not follow, the profile's identity pill once they do. Never while
/// the tray shows, never on the viewer's own profile.
extension ProfileBellAndMapMenuTests {
    @Test func aStrangersProfileWearsAPinkFollowOnceTheTrayHasGone() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugBarRelationshipItem == nil, "the tray still shows Follow")

        screen.debugSetTrayScrolledAway(true)
        let follow = try #require(screen.debugBarRelationshipItem)
        #expect(follow === screen.debugBarFollowItem)
        #expect(follow.title == "Follow")
        #expect(follow.style == .prominent)
        #expect(follow.tintColor == Palette.prominentGlassTint, "the Follow is not pink")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        // On screen [coins][pill][Follow] (the owner, 2026-10-15): the
        // Follow in the bell's corner, the pill inboard of it.
        #expect(items.count == 5)
        #expect(items[0] === follow, "the Follow is not in the corner")
        #expect(items[2].customView === screen.debugBarIdentityPill, "no pill beside the Follow")
        #expect(items[4].accessibilityLabel == "Balance", "the balance is not the inboard end")
        #expect(screen.debugMuteBellItem == nil)
        for space in [items[1], items[3]] {
            #expect(space.customView == nil && space.title == nil, "no space keeps each its own bubble")
        }

        screen.debugSetTrayScrolledAway(false)
        #expect(screen.debugBarRelationshipItem == nil, "the Follow stayed with the tray back")
    }

    /// ⚠️ AT REST THE TRAY IS ON SCREEN: a push placed the header before it
    /// had laid out, read the tray as gone, and the pill showed over a
    /// profile that had not moved (the owner, on a device, 2026-10-15).
    @Test func aProfileAtRestWearsNoRelationshipInTheBar() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following })
        screen.debugApplyHeaderOffset(0)
        #expect(screen.debugBarRelationshipItem == nil, "the pill showed at rest")
        screen.debugApplyHeaderOffset(-40)
        #expect(screen.debugBarRelationshipItem == nil, "the pill showed on a pull")
    }

    @Test func aFollowedProfileWearsItsIdentityPill() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following })
        screen.debugSetTrayScrolledAway(true)
        let item = try #require(screen.debugBarRelationshipItem)
        #expect(item.customView === screen.debugBarIdentityPill)
        #expect(screen.debugBarIdentityPill.name == "Lena Fischer")
        #expect(screen.debugBarIdentityPill.handle == "@lena")
        // The bars' one identity look, the post's author pill's too.
        #expect(screen.debugBarIdentityPill.debugNameFont.pointSize == BarIdentityStyle.nameFont.pointSize)
        #expect(screen.debugBarIdentityPill.debugHandleFont.pointSize == BarIdentityStyle.handleFont.pointSize)
        // The profile's pill carries no relation badge (#1277).
        #expect(screen.debugBarIdentityPill.debugGeometry.badge == nil)
        // And no ring either: the ring goes with the badge (the owner, 2026-10-16).
        #expect(screen.debugBarIdentityPill.ringRelation == .none)
        let budget = screen.debugBarIdentityPill.widthCap
        #expect(budget > 0 && budget < screen.view.bounds.width, "the pill is not capped by the bar's room")
    }

    @Test func theOwnProfileWearsNothing() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        try #require(await settle { viewModel.isOwnProfile })
        screen.debugSetTrayScrolledAway(true)
        #expect(screen.debugBarRelationshipItem == nil)
    }
}

// MARK: - Stubs

private let subject = UserProfile(
    id: ProfileID("prof-7"),
    handle: "lena",
    displayName: "Lena Fischer",
    bio: "",
    avatarURL: nil,
    websiteURL: nil,
    isVerified: false,
    followerCount: .exact(12),
    followingCount: .exact(9),
    reactionCount: .exact(3)
)

/// Identity, relationship and mute — what the bell and the menus read.
private final class StubProfiles: ProfileProviding, ProfileMuting, @unchecked Sendable {
    private let lock = NSLock()
    private let relationshipValue: ProfileRelationship
    private var scopes = MuteScopes.none

    init(relationship: ProfileRelationship) {
        relationshipValue = relationship
    }

    var lastScopes: MuteScopes { lock.withLock { scopes } }

    func currentUserProfile() async throws -> UserProfile { subject }
    func profile(id: ProfileID) async throws -> UserProfile { subject }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { relationshipValue }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { subject }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { subject }

    func muteScopes(for profileID: ProfileID) async throws -> MuteScopes { lastScopes }
    func setMuteScopes(_ newScopes: MuteScopes, for profileID: ProfileID) async throws {
        lock.withLock { scopes = newScopes }
    }
    func mutedProfiles() async throws -> [MutedProfile] { [] }
}

/// The same answers from a repository that cannot mute.
private struct StubProfilesWithoutMute: ProfileProviding {
    let base: StubProfiles

    func currentUserProfile() async throws -> UserProfile { subject }
    func profile(id: ProfileID) async throws -> UserProfile { subject }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        try await base.relationship(for: profileID)
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { subject }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { subject }
}

private actor StubPinning: MapProfilePinning {
    private var rails: [ProfileID: Set<MapFavoriteCategory>] = [:]

    func categories(for id: ProfileID) async -> Set<MapFavoriteCategory> { rails[id] ?? [] }
    func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async {
        rails[id] = categories
    }
}
