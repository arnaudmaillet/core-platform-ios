import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import Foundation
import LaunchArguments
import MapsInterface
import MediaCore
import MediaUI
import PostGrid
import Testing
import UIKit
@testable import Profile
@testable import ProfileData

/// **Mute is a bell; the map star is a "Map" submenu of see-more (#689, the
/// owner's call 2026-10-08).**
///
/// ⚠️ THE BELL IS THE TOOLBAR'S SINCE #2475 (the owner, 2026-11-28; the
/// header's row since #2302): on someone else's profile, once followed,
/// Follow becomes the bell — `[🔔][——Message——][QR]`, the card's toolbar
/// (#1562), from one source — and the bar never carries it. The bell opens
/// the scoped Mute menu and wears `bell.slash` once anything is muted;
/// Unfollow leads the ⋯ menu (top right); the ⋯ menu has no Mute and gains
/// Map — Map Dock / Following Filter, and Friends Filter for a mutual — on a
/// followed profile only.
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
            makeGridPage: TestGridPages.factory(), presence: SectionPresenceStore(scope: StorageScope()),
            onLogout: own ? {} : nil,
            trayPlacement: own ? .aboveBottomSafeArea : .navigationToolbar
        )
        // A shell handing a balance in: no profile shows it (#2475).
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

    /// Followed: `[🔔][——Message——][QR]` in the toolbar (#2475), and the bar
    /// carries ⋯ alone — no bell, no balance (#2302, #2475).
    @Test func aFollowedProfileShowsTheBellInTheToolbar() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let bell = try #require(await settle { screen.debugMuteBell != nil } ? screen.debugMuteBell : nil)
        #expect(screen.debugToolbarKinds == [.bell, .message, .qr])
        #expect(screen.debugMuteBellSymbol == AppSymbol.bell.rawValue)
        #expect(bell.title == nil && bell.customView == nil, "the bell has words, or is a hosted view")
        #expect(bell.accessibilityLabel == "Notifications")
        #expect(bell.menu != nil, "the bell's tap is not its menu")
        #expect(screen.debugTrailingIDs == [ProfileNavigationBarComposer.moreItemID],
                "the bar carries more than ⋯ once followed")
    }

    /// Message takes the free width the bell leaves (#2302), as on the card:
    /// the word, stretched (#2475 §5).
    @Test func messageTakesTheFreeWidthBesideTheBell() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.debugMuteBell != nil })
        let wide = try #require(screen.relationToolbarWideLabel, "nothing takes the free width")
        #expect(wide.title == "Message")
    }

    // MARK: - Follow ⇄ the bell is the button's morph (#2302)

    /// The screen pushed on a stack in a visible window, so the bars are on
    /// screen and their writes can animate.
    private func hostedOnScreen(
        relationship: ProfileRelationship
    ) -> (ProfileViewController, ProfileViewModel, StubProfiles, UINavigationController, UIWindow) {
        let (screen, viewModel, repository) = makeScreen(relationship: relationship)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(screen, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.isHidden = false
        window.layoutIfNeeded()
        return (screen, viewModel, repository, navigation, window)
    }

    /// Follow → the bell, and an unfollow back to Follow, in the toolbar —
    /// Message's glyph turning into its word and back under ONE identifier
    /// (#2475 §5), the QR the same instance throughout (#2331), and the bar
    /// never part of it.
    @Test func followAndUnfollowChangeTheToolbarInPlace() async throws {
        let (screen, viewModel, _, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: false, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.followButtonState == .follow && viewModel.profile != nil })
        #expect(screen.debugToolbarKinds == [.follow, .message, .qr])
        let qr = try #require(screen.relationToolbarItem(.qr))
        let glyph = try #require(screen.relationToolbarItem(.message))
        #expect(glyph.customView == nil && glyph.image != nil, "Message is not the glyph beside Follow")

        viewModel.toggleFollow()
        #expect(screen.debugMuteBell != nil, "Follow did not become the bell")
        let word = try #require(screen.relationToolbarItem(.message))
        #expect((word.customView as? StretchedBarLabel)?.title == "Message", "Message is not the word once followed")
        #expect(word.identifier == glyph.identifier, "Message changed identity")
        #expect(screen.relationToolbarItem(.qr) === qr, "the QR was re-made")

        try #require(await settle { !viewModel.followInFlight })
        viewModel.toggleFollow()
        #expect(screen.debugMuteBell == nil, "the bell stayed after the unfollow")
        #expect(screen.debugFollowTitle == "Follow")
        #expect(screen.relationToolbarItem(.message)?.customView == nil, "Message kept its word beside Follow")
        #expect(screen.debugTrailingIDs == [ProfileNavigationBarComposer.moreItemID])
    }

    /// A refused unfollow rolls the optimistic flip back: the bell comes back.
    @Test func aRefusedUnfollowBringsTheBellBack() async throws {
        let (screen, viewModel, repository, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: true, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBell != nil && viewModel.profile != nil })
        repository.refusesFollowChange = true

        viewModel.toggleFollow()
        #expect(screen.debugMuteBell == nil, "guard: the flip is optimistic")
        #expect(await settle { screen.debugMuteBell != nil }, "the bell never came back")
    }

    /// The glyph follows the scopes: `bell.slash` once one is muted, `bell`
    /// again when none is — and the menu's checkmarks with it.
    @Test func theBellsGlyphFollowsTheMutedScopes() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        // The bell comes once the read says the viewer follows (#1398).
        let bell = try #require(
            await settle { screen.debugMuteBell != nil && viewModel.canModerate } ? screen.debugMuteBell : nil
        )
        #expect(screen.debugMuteBellSymbol == AppSymbol.bell.rawValue)
        #expect(bell.accessibilityValue == "Nothing muted")

        viewModel.toggleMute(.posts)
        try #require(await settle { screen.debugMuteBellSymbol == AppSymbol.bellSlash.rawValue })
        #expect(screen.debugMuteBell === bell, "the bell is not the toolbar's kept item")
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
        try #require(await settle { screen.debugMuteBellSymbol == AppSymbol.bell.rawValue })
        #expect(screen.debugMuteBell?.accessibilityValue == "Nothing muted")
        #expect((screen.debugMuteMenuElements().first as? UIMenu)?.title == "Mute")
    }

    /// The bell's glyph and spoken state from the scopes — one mapping, the
    /// page's and the card's.
    @Test func theBellsGlyphComesFromTheScopes() {
        #expect(ProfileRelationControl.bellSymbol(for: .none) == AppSymbol.bell.rawValue)
        #expect(ProfileRelationControl.bellSymbol(for: MuteScopes(stories: true)) == AppSymbol.bellSlash.rawValue)
        #expect(ProfileRelationControl.bellAccessibilityValue(for: .none) == "Nothing muted")
        #expect(ProfileRelationControl.bellAccessibilityValue(for: MuteScopes(posts: true, messages: true))
                == "Muted: Posts, Messages")
    }

    /// The bell changes AT ONCE, beside its toast (#2143): no toast takes
    /// its place in the bar any more, so it shows its new look on the tap
    /// (#2116's rule) — muting more (Undo, on the tap) and unmuting (once the
    /// server answered) alike — and stays tappable while the toast is up.
    @Test func theBellChangesAtOnceBesideItsToast() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBell != nil && viewModel.canModerate })
        let isToast: (UIBarButtonItem) -> Bool = { $0.customView is ToastView }

        screen.debugToggleMute(.posts)
        try #require(await settle { screen.debugMuteBellSymbol == AppSymbol.bellSlash.rawValue },
                     "the bell waited")
        #expect(!(screen.navigationItem.rightBarButtonItems ?? []).contains(where: isToast), "a toast took the bar")
        // ⚠️ THE TOAST'S ARRIVAL, NOT ITS PRESENCE (#1951): counted, it
        // cannot be missed between two looks on a starved runner.
        try #require(await settle { screen.debugUndoToastsShown == 1 }, "no toast for the mute")
        #expect(screen.debugMuteBell?.isEnabled != false, "the bell is not tappable beside its toast")

        // Let the Undo run out (if its time has not already): the mute is sent.
        screen.debugLastUndoToast?.debugDismiss()
        try #require(await settle { repository.lastScopes == MuteScopes(posts: true) })

        screen.debugToggleMute(.posts)
        // ⚠️ THE TOAST'S ARRIVAL, NOT ITS PRESENCE (#1951). It shows once the
        // server answered and leaves after a few seconds; on a starved runner
        // a poll gap outlasted it. Counted, it cannot be missed.
        try #require(await settle { screen.debugMuteToastsShown == 1 }, "no toast for the unmute")
        #expect(screen.debugMuteBellSymbol == AppSymbol.bell.rawValue)
    }

    /// Not followed: NO bell (the owner, 2026-10-15 — nothing of theirs to
    /// mute yet; the toolbar's Follow stands in its place), and ⋯ has no Map
    /// submenu and no Unfollow.
    @Test func anUnfollowedProfileHasNoBellAndNoMapSubmenu() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugMuteBell == nil, "a bell on a profile the viewer does not follow")
        #expect(screen.debugToolbarKinds == [.follow, .message, .qr])
        #expect(screen.debugTrailingIDs == [ProfileNavigationBarComposer.moreItemID])
        #expect(mapSubmenu(screen) == nil)
        #expect(!titles(screen.debugMoreMenuElements()).contains("Unfollow"))
    }

    /// No bell before the relationship is read (#1398): an unknown
    /// relationship is not "followed", so no bell is shown during the push
    /// only to be taken away.
    @Test func noBellBeforeTheRelationshipIsRead() {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        #expect(screen.followButtonState == .hidden)
        #expect(screen.debugMuteBell == nil, "a bell presumed before the read")
    }

    /// Following from the profile brings the bell; unfollowing takes it.
    @Test func followingBringsTheBellAndUnfollowingTakesIt() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugMuteBell == nil)
        viewModel.toggleFollow()
        try #require(await settle { screen.debugMuteBell != nil }, "following brought no bell")
        try #require(await settle { !viewModel.followInFlight })
        viewModel.toggleFollow()
        #expect(await settle { screen.debugMuteBell == nil }, "unfollowing left the bell")
    }

    /// Your own profile: no bell, the bar as it was.
    @Test func yourOwnProfileHasNoBell() async {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        await settle { viewModel.isRelationshipSettled }
        #expect(screen.debugMuteBell == nil)
    }

    /// A composition that cannot mute shows no bell.
    @Test func noMutingNoBell() async {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false), muting: false)
        await settle { viewModel.canModerate }
        #expect(screen.debugMuteBell == nil)
        #expect(screen.debugToolbarKinds == [.message, .qr], "Following came back")
    }

    /// A guest: no bell, whatever the relationship reads (#2302) — a guest
    /// has no account to mute from. Message alone across the free width.
    @Test func aGuestHasNoBell() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let navigation = GuestNavigation(root: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try #require(MemberGates.isGuest(screen), "guard: the gate is not up the chain")
        try #require(await settle { screen.followButtonState == .following && viewModel.canModerate })
        #expect(screen.debugMuteBell == nil, "a guest has a bell")
        #expect(screen.debugToolbarKinds == [.message, .qr])
    }

    // MARK: - The see-more menu

    /// ⚠️ UNFOLLOW LEADS SEE-MORE ONCE FOLLOWED (#2302): first, red, and it
    /// unfollows — the toolbar's path, the optimistic flip; the bell turns
    /// back into Follow and Unfollow leaves the menu.
    @Test func unfollowLeadsSeeMoreAndUnfollows() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following && viewModel.profile != nil })
        let elements = screen.debugMoreMenuElements()
        let first = try #require((elements.first as? UIMenu)?.children.first as? UIAction, "no row at the head")
        #expect(first.title == "Unfollow")
        #expect(first.attributes.contains(.destructive), "Unfollow is not red")
        #expect(first.image == UIImage(systemName: "person.badge.minus"))

        first.performWithSender(nil, target: nil)
        #expect(screen.followButtonState == .follow, "Unfollow did not unfollow")
        #expect(screen.debugToolbarKinds == [.follow, .message, .qr])
        #expect(!titles(screen.debugMoreMenuElements()).contains("Unfollow"), "Unfollow stayed once unfollowed")
    }

    /// Requested: no Unfollow — withdrawing a request stays on Requested.
    @Test func aRequestedProfileHasNoUnfollow() async throws {
        let (screen, _, _) = makeScreen(relationship: .requested)
        try #require(await settle { screen.followButtonState == .requested })
        #expect(!titles(screen.debugMoreMenuElements()).contains("Unfollow"))
        #expect(screen.debugToolbarKinds == [.requested, .message, .qr])
        #expect(screen.relationToolbarItem(.message)?.customView == nil, "Message is not the glyph beside Requested")
    }

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

    // MARK: - The toolbar per relation (#2302, #2475)

    /// ⚠️ THE TOOLBAR PER RELATION (#2475 §3, §5): someone else's profile and
    /// the card read ONE source (`ProfileRelationToolbar.items`).
    @Test func theToolbarPerRelation() {
        typealias Toolbar = ProfileRelationToolbar
        #expect(Toolbar.items(for: .follow) == [.follow, .message, .qr])
        #expect(Toolbar.items(for: .requested) == [.requested, .message, .qr])
        #expect(Toolbar.items(for: .following) == [.bell, .message, .qr])
        #expect(Toolbar.items(for: .following, showsBell: false) == [.message, .qr])
        #expect(Toolbar.items(for: .unavailable) == [.message, .qr])
        #expect(Toolbar.items(for: .hidden) == [.message, .qr])
        #expect(Toolbar.items(for: .edit) == [.openProfile])
        #expect(Toolbar.items(for: .follow, showsQR: false) == [.follow, .message])
    }

    /// Message is the glyph beside Follow or Requested, the word otherwise
    /// (#2475 §5).
    @Test func messageIsTheGlyphBesideFollowOrRequestedOnly() {
        typealias Toolbar = ProfileRelationToolbar
        #expect(Toolbar.messageIsGlyph(in: Toolbar.items(for: .follow)))
        #expect(Toolbar.messageIsGlyph(in: Toolbar.items(for: .requested)))
        for state in [ProfileViewModel.FollowButton.following, .unavailable, .hidden] {
            #expect(!Toolbar.messageIsGlyph(in: Toolbar.items(for: state)), "\(state)")
        }
        #expect(Toolbar.wideItem(in: Toolbar.items(for: .follow)) == .follow)
        #expect(Toolbar.wideItem(in: Toolbar.items(for: .requested)) == .requested)
        #expect(Toolbar.wideItem(in: Toolbar.items(for: .following)) == .message)
    }

    /// ONE SOURCE (#2475 §3): for every relationship, someone else's profile's
    /// toolbar is the card's — the same kinds, the same identifiers, the same
    /// stretched slot, Message the glyph or the word alike.
    @Test(arguments: [
        ProfileRelationship.other(isFollowing: false, isBlocked: false),
        .requested,
        .other(isFollowing: true, isBlocked: false),
    ])
    func someoneElsesToolbarIsTheCards(relationship: ProfileRelationship) async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: relationship)
        try #require(await settle { viewModel.isRelationshipSettled && viewModel.profile != nil })
        let card = ProfileCardViewController(
            viewModel: ProfileViewModel(repository: repository, mapPinning: StubPinning(), source: .profile(subject.id)),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), shareTargeting: nil,
            makeRelationshipsViewController: nil, identityStub: nil,
            actions: .init(openProfile: {}, push: { _ in })
        )
        card.loadViewIfNeeded()
        try #require(await settle { card.followButtonState == screen.followButtonState && card.viewModel.profile != nil })
        card.debugApplyFollowButton(screen.followButtonState)
        let ids: (UIViewController) -> [String] = { controller in
            (controller.toolbarItems ?? []).compactMap(\.identifier)
        }
        #expect(!ids(screen).isEmpty, "the profile has no toolbar")
        #expect(ids(screen) == ids(card), "\(relationship): the profile reads \(ids(screen)), the card \(ids(card))")
        #expect(screen.relationToolbarWideLabel?.title == card.wideLabel?.title)
        #expect((screen.relationToolbarItem(.message)?.customView == nil)
                == (card.relationToolbarItem(.message)?.customView == nil), "Message differs")
    }

    /// VoiceOver still says "Message" for the glyph (#2475 §5).
    @Test func theMessageGlyphIsReadAsMessage() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        let message = try #require(screen.relationToolbarItem(.message))
        #expect(message.accessibilityLabel == "Message")
        #expect(message.image != nil && message.title == nil, "the glyph has a word")
    }
}

// MARK: - The avatar's relation mark (#2014, #2050)

extension ProfileBellAndMapMenuTests {
    /// ONE MARK EVERYWHERE, PASSIVE (#2419, the owner 2026-11-13): the
    /// avatar keeps Following and Friends only — no "+" and no clock; the
    /// toolbar's Follow is the action. Nothing for someone blocked, the
    /// viewer's own profile, one not followable, not followed or only asked;
    /// the skeleton's badge for one not read yet (#2098), never on the
    /// viewer's own.
    @Test func theAvatarWearsOnlyFollowingAndFriends() {
        typealias Header = ProfileHeaderView
        #expect(Header.avatarMark(for: .follow, mutual: false, blocked: false, isOwnProfile: false) == PersonPill.Badge.none)
        #expect(Header.avatarMark(for: .requested, mutual: false, blocked: false, isOwnProfile: false) == PersonPill.Badge.none)
        #expect(Header.avatarMark(for: .following, mutual: false, blocked: false, isOwnProfile: false) == .following)
        #expect(Header.avatarMark(for: .following, mutual: true, blocked: false, isOwnProfile: false) == .friends)
        for state in [ProfileViewModel.FollowButton.follow, .requested, .following] {
            #expect(Header.avatarMark(for: state, mutual: true, blocked: true, isOwnProfile: false) == PersonPill.Badge.none, "\(state)")
            #expect(Header.avatarMark(for: state, mutual: false, blocked: false, isOwnProfile: false)
                    == (Header.relationBadge(for: state, mutual: false) ?? .none), "the avatar left the one mapping")
        }
        for state in [ProfileViewModel.FollowButton.edit, .unavailable] {
            #expect(Header.avatarMark(for: state, mutual: false, blocked: false, isOwnProfile: false) == PersonPill.Badge.none, "\(state)")
        }
        #expect(Header.avatarMark(for: .hidden, mutual: false, blocked: false, isOwnProfile: false) == .loading)
        for state in [ProfileViewModel.FollowButton.hidden, .edit] {
            #expect(Header.avatarMark(for: state, mutual: false, blocked: false, isOwnProfile: true) == PersonPill.Badge.none,
                    "the viewer's own face wore a mark for \(state)")
        }
        #expect(Header.avatarMark(for: .hidden, mutual: false, blocked: true, isOwnProfile: false) == PersonPill.Badge.none)
    }

    /// Friends on the avatar: the two people.
    @Test func theProfilesAvatarWearsTheRelation() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isMutual: true, isBlocked: false))
        #expect(await settle { screen.headerView.relationMark == .friends })
    }

    /// The viewer's own profile: no mark, and no edge (#2082).
    @Test func theViewersOwnAvatarWearsNoMark() async throws {
        let (screen, _, _) = makeScreen(relationship: .me, own: true)
        try #require(await settle { screen.followButtonState == .edit })
        #expect(screen.headerView.relationMark == .none)
        #expect(screen.headerView.debugRelationSymbol == nil)
        #expect(screen.headerView.debugAvatarRingWidth == 0)
    }

    /// NO "+" ON THE HEADER'S FACE (#2419): not followed, the avatar wears
    /// nothing; the toolbar's Follow brings the check.
    @Test func theToolbarsFollowBringsTheAvatarsCheck() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.headerView.relationMark == .none, "a + on the profile's avatar")
        #expect(screen.headerView.debugRelationSymbol == nil)
        let follow = try #require(screen.relationToolbarItem(.follow)?.customView as? StretchedBarLabel)
        follow.debugTap()
        try #require(await settle { screen.followButtonState == .following }, "the toolbar did not follow")
        #expect(screen.headerView.relationMark == .following, "the toolbar's Follow left the avatar behind")
    }

    /// The badge is passive: no mark takes a touch or calls the follow, and
    /// VoiceOver reads it as its state, never a button.
    @Test func theBadgeIsPassive() throws {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let badge = try #require(header.debugRelationBadge)
        for mark in [PersonPill.Badge.following, .friends, .loading, .none] {
            header.setRelationMark(mark, animated: false)
            #expect(!badge.isUserInteractionEnabled, "\(mark) takes touches")
            #expect(!badge.accessibilityTraits.contains(.button), "\(mark) reads as a button")
        }
        #expect(badge.accessibilityLabel == nil && !badge.isAccessibilityElement, "none is read")
        header.setRelationMark(.friends, animated: false)
        #expect(badge.accessibilityLabel == "Friends")
        header.setRelationMark(.following, animated: false)
        #expect(badge.accessibilityLabel == "Following")
    }
}

// MARK: - Stubs

/// A stack whose shell says the viewer is a guest.
private final class GuestNavigation: UINavigationController, MemberGateProviding {
    let memberGate: any MemberGating

    init(root: UIViewController) {
        memberGate = MemberGate(isMember: false)
        super.init(nibName: nil, bundle: nil)
        setViewControllers([root], animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

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
