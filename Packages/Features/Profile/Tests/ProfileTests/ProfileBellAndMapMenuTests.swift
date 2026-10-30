import CoreModels
import CoreNavigation
import DesignSystem
@testable import Feed
import FeedInterface
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
        screen.makePersonBarItem = { PersonBarItems.make() }
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

    // MARK: - The bell leaves the way it came (#1903)

    /// The screen at the root of a stack in a visible window, so the bar is
    /// on screen and its writes can animate.
    private func hostedOnScreen(
        relationship: ProfileRelationship
    ) -> (ProfileViewController, ProfileViewModel, StubProfiles, UINavigationController, UIWindow) {
        let (screen, viewModel, repository) = makeScreen(relationship: relationship)
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.isHidden = false
        window.layoutIfNeeded()
        return (screen, viewModel, repository, navigation, window)
    }

    /// An unfollow on a bar at rest takes the bell out ANIMATED, through the
    /// path it arrived by, so UIKit morphs it back into the balance pill. It
    /// went through `performWithoutAnimation`, and the owner filmed it
    /// vanishing between two frames.
    @Test func anUnfollowAtRestTakesTheBellOutAnimated() async throws {
        let (screen, viewModel, _, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: true, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBellItem != nil && screen.transitionCoordinator == nil })
        let before = screen.debugBarWrites.count

        viewModel.toggleFollow()

        #expect(screen.debugMuteBellItem == nil, "the bell stayed after the unfollow")
        #expect(screen.debugBarWrites.count > before, "the bar was never written")
        #expect(screen.debugBarWrites.last == true, "the bell left unanimated")
    }

    /// A refused unfollow rolls the optimistic flip back, and the bell comes
    /// back, animated as on a follow.
    @Test func aRefusedUnfollowBringsTheBellBack() async throws {
        let (screen, viewModel, repository, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: true, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBellItem != nil && screen.transitionCoordinator == nil })
        repository.refusesFollowChange = true

        viewModel.toggleFollow()
        #expect(screen.debugMuteBellItem == nil, "guard: the flip is optimistic")

        #expect(await settle { screen.debugMuteBellItem != nil }, "the bell never came back")
        #expect(screen.debugBarWrites.last == true, "the bell came back unanimated")
    }

    /// ⚠️ A REMOVAL MID-TRANSITION STILL WAITS FOR REST, UNANIMATED (#756):
    /// an item removed while a push runs pops at its end on device. Here the
    /// unfollow lands while a child is being pushed over the profile.
    @Test func aBellLeavingMidPushWaitsForRestUnanimated() async throws {
        let (screen, viewModel, _, navigation, window) = hostedOnScreen(
            relationship: .other(isFollowing: true, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBellItem != nil && screen.transitionCoordinator == nil })

        navigation.pushViewController(UIViewController(), animated: true)
        try #require(screen.transitionCoordinator != nil, "guard: the push is running")
        viewModel.toggleFollow()
        #expect(screen.debugMuteBellItem != nil, "the bell left mid-push")

        try #require(await settle { screen.debugMuteBellItem == nil }, "the bell never left")
        #expect(screen.debugBarWrites.last == false, "a removal mid-push was animated")
    }

    /// The glyph follows the scopes: `bell.slash` once one is muted, `bell`
    /// again when none is — and the menu's checkmarks with it. A new glyph
    /// is a NEW item under the same identifier (#1679, R3): the bar morphs
    /// it, never an image swapped in place.
    @Test func theBellsGlyphFollowsTheMutedScopes() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        // The bell comes once the read says the viewer follows (#1398).
        let bell = try #require(
            await settle { screen.debugMuteBellItem != nil && viewModel.canModerate } ? screen.debugMuteBellItem : nil
        )
        #expect(bell.image == UIImage(systemName: "bell"))
        #expect(bell.identifier == ProfileViewController.muteBellID)

        viewModel.toggleMute(.posts)
        try #require(await settle { screen.debugMuteBellItem?.image == UIImage(systemName: "bell.slash") })
        let muted = try #require(screen.debugMuteBellItem)
        #expect(muted !== bell, "the glyph was swapped on the item the bar shows")
        #expect(muted.identifier == bell.identifier)
        #expect(bell.image == UIImage(systemName: "bell"), "the old item was restyled")
        #expect(muted.accessibilityValue == "Muted: Posts")
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
        try #require(await settle { screen.debugMuteBellItem?.image == UIImage(systemName: "bell") })
        #expect(screen.debugMuteBellItem?.accessibilityValue == "Nothing muted")
        #expect(screen.debugMuteBellItem?.identifier == ProfileViewController.muteBellID)
        #expect((screen.debugMuteMenuElements().first as? UIMenu)?.title == "Mute")
    }

    /// ⚠️ OLD LOOK → TOAST → NEW LOOK (#1447). The mute's toast takes the
    /// bell's place in the bar: the bell on the bar keeps its glyph — never
    /// `bell.slash` before the toast — and the bell that comes back when it
    /// leaves wears the new one. Muting more (Undo, on the tap) and
    /// unmuting (once the server answered) alike.
    @Test func theBellChangesUnderItsToastNeverBefore() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        let bell = try #require(
            await settle { screen.debugMuteBellItem != nil && viewModel.canModerate } ? screen.debugMuteBellItem : nil
        )
        let isToast: (UIBarButtonItem) -> Bool = { $0.customView is ToastView }

        screen.debugToggleMute(.posts)
        #expect(bell.image == UIImage(systemName: "bell"), "the bell on the bar flipped with its toast")
        #expect((screen.navigationItem.rightBarButtonItems ?? []).contains(where: isToast), "no toast took the bar")
        let muted = try #require(screen.debugMuteBellItem, "no bell comes back")
        #expect(muted !== bell)
        #expect(muted.image == UIImage(systemName: "bell.slash"))

        // Let the Undo run out: the mute is sent.
        let undo = try #require((screen.navigationItem.rightBarButtonItems ?? []).compactMap { $0.customView as? ToastView }.first)
        undo.debugDismiss()
        try #require(await settle { repository.lastScopes == MuteScopes(posts: true) })
        try #require(await settle { !(screen.navigationItem.rightBarButtonItems ?? []).contains(where: isToast) })

        screen.debugToggleMute(.posts)
        #expect(screen.debugMuteBellItem?.image == UIImage(systemName: "bell.slash"), "bell showed before the toast")
        // ⚠️ THE TOAST'S ARRIVAL, NOT ITS PRESENCE (#1951). It shows once the
        // server answered and leaves after a few seconds; on a starved runner
        // (179 s for this test) a poll gap outlasted it, and a presence poll
        // missed a toast that had come and gone. Counted, it cannot be missed.
        try #require(await settle { screen.debugMuteToastsShown == 1 }, "no toast for the unmute")
        #expect(muted.image == UIImage(systemName: "bell.slash"), "the bell on the bar flipped with its toast")
        #expect(screen.debugMuteBellItem?.image == UIImage(systemName: "bell"))
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

    /// No bell before the relationship is read (#1398): an unknown
    /// relationship is not "followed", so no bell is shown during the push
    /// only to be taken away.
    @Test func noBellBeforeTheRelationshipIsRead() {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        #expect(screen.followButtonState == .hidden)
        #expect(screen.debugMuteBellItem == nil, "a bell presumed before the read")
    }

    /// Following from the profile brings the bell; unfollowing takes it.
    @Test func followingBringsTheBellAndUnfollowingTakesIt() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugMuteBellItem == nil)
        viewModel.toggleFollow()
        try #require(await settle { screen.debugMuteBellItem != nil }, "following brought no bell")
        try #require(await settle { !viewModel.followInFlight })
        viewModel.toggleFollow()
        #expect(await settle { screen.debugMuteBellItem == nil }, "unfollowing left the bell")
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

// MARK: - The bar's identity (#1451)

/// Once the header's action tray has scrolled out of sight, the bar carries
/// the profile's identity: the post page's person pill, its relation a badge
/// on the face whose "+" follows — never a Follow item. ⚠️ LEADING since
/// #1590: `[‹][pill] … [balance]`, and `… [balance][bell]` once followed.
/// Never while the tray shows, never on the viewer's own profile.
extension ProfileBellAndMapMenuTests {
    private func pill(_ screen: ProfileViewController) throws -> any PersonBarItem {
        try #require(screen.debugBarIdentityPill, "no pill was built")
    }

    @Test func aStrangersProfileWearsThePillWithAPlusAndNoFollowItem() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugBarRelationshipItem == nil, "the pill showed with the tray on screen")

        screen.debugSetTrayScrolledAway(true)
        let item = try #require(screen.debugBarRelationshipItem)
        #expect(item.customView === (try pill(screen)).view)
        #expect(try pill(screen).followBadge == .follow, "no + on a profile not followed")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(!items.contains { $0.title == "Follow" }, "a Follow item in the bar")
        // Trailing is the balance alone; the pill leads, after the chevron.
        #expect(items.count == 1)
        #expect(items[0].accessibilityLabel == "Balance", "the balance is not in the corner")
        #expect(!items.contains { $0 === item }, "the pill stayed trailing")
        #expect(screen.navigationItem.leftBarButtonItems?.last === item, "the pill does not lead")
        #expect(screen.navigationItem.leftItemsSupplementBackButton, "the pill would replace the chevron")
        #expect(screen.debugMuteBellItem == nil)

        screen.debugSetTrayScrolledAway(false)
        #expect(screen.debugBarRelationshipItem == nil, "the pill stayed with the tray back")
    }

    /// Followed: `[pill][coins][bell]`, the bell keeping the corner.
    @Test func aFollowedProfileReadsPillBalanceBell() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following && viewModel.canModerate })
        try #require(await settle { screen.debugMuteBellItem != nil })
        screen.debugSetTrayScrolledAway(true)
        let item = try #require(screen.debugBarRelationshipItem)
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 3)
        #expect(items[0] === screen.debugMuteBellItem, "the bell lost the corner")
        #expect(items[2].accessibilityLabel == "Balance")
        #expect(screen.navigationItem.leftBarButtonItems?.last === item, "the pill does not lead")
        #expect(try pill(screen).followBadge == .following)
        let shown = (try pill(screen).view as? SnapAuthorIdentityView)?.debugShownLines ?? []
        #expect(shown.contains("Lena Fischer") && shown.contains("@lena"), "\(shown)")
        let budget = (try pill(screen).view as? SnapAuthorIdentityView)?.widthCap ?? 0
        #expect(budget > 0 && budget < screen.view.bounds.width, "the pill is not capped by the bar's room")
    }

    /// The badge is the post page's, from the relation.
    @Test func theBadgeFollowsTheRelation() {
        #expect(ProfileViewController.barBadge(for: .follow, mutual: false) == .follow)
        #expect(ProfileViewController.barBadge(for: .requested, mutual: false) == .pending)
        #expect(ProfileViewController.barBadge(for: .following, mutual: false) == .following)
        #expect(ProfileViewController.barBadge(for: .following, mutual: true) == .friends)
        #expect(ProfileViewController.barBadge(for: .unavailable, mutual: false) == nil)
        #expect(ProfileViewController.barBadge(for: .hidden, mutual: false) == nil)
    }

    /// The "+" follows, through the tray's own path: the badge turns.
    @Test func thePlusFollows() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        screen.debugSetTrayScrolledAway(true)
        let shown = try pill(screen)
        shown.onFollowTapped?(subject.id)
        try #require(await settle { screen.followButtonState == .following }, "the + did not follow")
        #expect(shown.followBadge == .following, "the badge did not turn")
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

    /// ⚠️ HISTORY'S DAY GOES TRAILING (#1590), innermost of the screen's
    /// own trailing items, beside the pill now leading.
    @Test func historysDayIsTheInnermostTrailingItem() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following && viewModel.canModerate })
        try #require(await settle { screen.debugMuteBellItem != nil })
        screen.debugSetTrayScrolledAway(true)
        screen.debugApplyPinnedSection(PostGridPinnedSection(index: 1, title: "Yesterday"))
        let day = try #require(screen.debugSectionItem, "the day is not trailing")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.last === day, "the day is not the innermost trailing item")
        #expect(items[0] === screen.debugMuteBellItem, "the bell lost the corner")
        #expect(!(screen.navigationItem.leftBarButtonItems ?? []).contains { $0 === day }, "the day stayed leading")
        #expect(screen.debugBarRelationshipItem != nil, "the pill left the leading group")

        screen.debugApplyPinnedSection(nil)
        #expect(screen.debugSectionItem == nil, "the day stayed after the list went back to the top")
    }

    /// The pill's room is the bar's width less the chevron and the trailing
    /// group — History's day included (#1590), on an SE and an 18 Pro.
    @Test(arguments: [375.0, 402.0])
    func thePillsWidthIsTheBarsRoom(width: CGFloat) async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following && viewModel.canModerate })
        try #require(await settle { screen.debugMuteBellItem != nil })
        screen.view.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        screen.debugSetTrayScrolledAway(true)
        let free = (try pill(screen).view as? SnapAuthorIdentityView)?.widthCap ?? 0
        #expect(free > 0 && free < width - 88, "the pill is not capped by the bar's room at \(width)")
        screen.debugApplyPinnedSection(PostGridPinnedSection(index: 1, title: "Yesterday"))
        screen.debugSetTrayScrolledAway(false)
        screen.debugSetTrayScrolledAway(true)
        let withDay = (try pill(screen).view as? SnapAuthorIdentityView)?.widthCap ?? 0
        #expect(withDay < free, "the day's bubble did not take its room from the pill at \(width)")
    }

    /// Your own profile: the day goes LEADING (#1642, the owner 2026-10-23),
    /// after the shell's bell — the inbox's arrangement — and the trailing
    /// group keeps the balance and the gear alone.
    @Test func theOwnProfilesDayLeads() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        try #require(await settle { viewModel.isOwnProfile })
        let bell = UIBarButtonItem(image: UIImage(systemName: "bell"))
        screen.setLeadingAccessoryItem(bell)
        screen.debugApplyPinnedSection(PostGridPinnedSection(index: 0, title: "Today"))
        let day = try #require(screen.debugSectionItem)
        let leading = screen.navigationItem.leftBarButtonItems ?? []
        #expect(leading.count == 2 && leading[0] === bell && leading[1] === day, "the day is not after the bell")
        #expect(!(screen.navigationItem.rightBarButtonItems ?? []).contains { $0 === day }, "the day stayed trailing")
        #expect(screen.debugBarRelationshipItem == nil)

        // The bell rebuilt by the shell keeps the day after it.
        screen.debugRebuildNavigationState()
        #expect((screen.navigationItem.leftBarButtonItems ?? []).last === day)

        screen.debugApplyPinnedSection(nil)
        #expect(screen.debugSectionItem == nil, "the day stayed after the list went back to the top")
        #expect((screen.navigationItem.leftBarButtonItems ?? []).elementsEqual([bell], by: ===))
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
    /// Whether the server refuses a follow or an unfollow.
    var refusesFollowChange: Bool {
        get { lock.withLock { refuses } }
        set { lock.withLock { refuses = newValue } }
    }
    private var refuses = false

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        if refusesFollowChange { throw URLError(.badServerResponse) }
    }
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
