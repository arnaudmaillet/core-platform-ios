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

/// **Mute is a bell; the map star is a "Map" submenu of see-more (#689, the
/// owner's call 2026-10-08).**
///
/// ⚠️ THE BELL IS THE HEADER'S SINCE #2302 (the owner, 2026-11-11): on
/// someone else's profile, once followed, the header's Follow becomes the
/// bell — `[bell][——Message——][QR][…]`, the card's row (#1562) — and the bar's
/// corner stays empty. The bell opens the scoped Mute menu and wears
/// `bell.slash` once anything is muted; Unfollow leads the see-more menu; the
/// see-more menu has no Mute and gains Map — Map Dock / Following Filter, and
/// Friends Filter for a mutual — on a followed profile only.
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

    /// Followed: `[bell][——Message——][QR][…]` in the header, nothing but the
    /// balance in the bar (#2302).
    @Test func aFollowedProfileShowsTheBellInTheHeadersRow() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        let bell = try #require(await settle { screen.debugMuteBell != nil } ? screen.debugMuteBell : nil)
        #expect(screen.headerView.debugTrayItems == [.bell, .message, .qr, .more])
        #expect(bell.content.symbol == "bell")
        #expect(bell.content.title == nil, "the bell has words")
        #expect(bell.accessibilityLabel == "Notifications")
        #expect(bell.showsMenuAsPrimaryAction && bell.menu != nil, "the bell's tap is not its menu")
        #expect(!bell.accessibilityTraits.contains(.toggleButton), "the bell reads as a toggle")
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"],
                "the bar kept a corner item once followed")
    }

    /// The bell is a bubble the QR's size and Message takes the width
    /// Following left (#2302), as on the card.
    @Test func theBellIsTheQRsSizeAndMessageTakesTheRest() throws {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configure(with: ProfileDisplayModel(profile: subject))
        header.configureAction(.follow)
        header.frame = CGRect(x: 0, y: 0, width: 402, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        let buttons = header.debugTrayButtons
        let (follow, message, qr) = (buttons[0], buttons[1], buttons[3])
        #expect(abs(follow.bounds.width - message.bounds.width) < 1, "Follow and Message are not halves")

        header.configureAction(.following, bell: ProfileHeaderView.Bell(scopes: .none))
        header.setNeedsLayout()
        header.layoutIfNeeded()
        #expect(abs(follow.bounds.width - qr.bounds.width) < 1, "the bell is \(follow.bounds.width) wide, the QR \(qr.bounds.width)")
        #expect(abs(follow.bounds.height - qr.bounds.height) < 1)
        #expect(message.bounds.width > 2 * follow.bounds.width, "Message did not take the free width")
    }

    // MARK: - Follow ⇄ the bell is the button's morph (#2302)

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

    /// Follow → the bell, and an unfollow back to Follow: the SAME button's
    /// content change (the morph, #1665), never a pop — and the bar is never
    /// part of it.
    @Test func followAndUnfollowMorphTheButtonBothWays() async throws {
        let (screen, viewModel, _, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: false, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.followButtonState == .follow && viewModel.profile != nil })
        let button = screen.headerView.debugFollowButton
        button.reducesMotion = { false }

        viewModel.toggleFollow()
        #expect(screen.debugMuteBell === button, "Follow did not become the bell")
        #expect(button.events.last == .blurMorph, "Follow → the bell did not morph")
        #expect(!button.events.contains(.scaleOut), "Follow popped out")

        try #require(await settle { !viewModel.followInFlight })
        viewModel.toggleFollow()
        #expect(screen.debugMuteBell == nil, "the bell stayed after the unfollow")
        #expect(screen.headerView.debugFollowTitle == "Follow")
        #expect(button.events.last == .blurMorph, "the bell → Follow did not morph")
        #expect(!button.isHidden)
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"])
    }

    /// A refused unfollow rolls the optimistic flip back: Follow morphs back
    /// into the bell.
    @Test func aRefusedUnfollowMorphsBackIntoTheBell() async throws {
        let (screen, viewModel, repository, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: true, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.debugMuteBell != nil && viewModel.profile != nil })
        let button = screen.headerView.debugFollowButton
        button.reducesMotion = { false }
        repository.refusesFollowChange = true

        viewModel.toggleFollow()
        #expect(screen.debugMuteBell == nil, "guard: the flip is optimistic")
        #expect(button.events.last == .blurMorph)
        let morphs = button.events.filter { $0 == .blurMorph }.count

        #expect(await settle { screen.debugMuteBell != nil }, "the bell never came back")
        #expect(button.events.filter { $0 == .blurMorph }.count > morphs, "the bell came back without a morph")
    }

    /// The glyph follows the scopes: `bell.slash` once one is muted, `bell`
    /// again when none is — and the menu's checkmarks with it.
    @Test func theBellsGlyphFollowsTheMutedScopes() async throws {
        let (screen, viewModel, repository) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        // The bell comes once the read says the viewer follows (#1398).
        let bell = try #require(
            await settle { screen.debugMuteBell != nil && viewModel.canModerate } ? screen.debugMuteBell : nil
        )
        #expect(bell.content.symbol == "bell")
        #expect(bell.accessibilityValue == "Nothing muted")

        viewModel.toggleMute(.posts)
        try #require(await settle { screen.debugMuteBell?.content.symbol == "bell.slash" })
        #expect(screen.debugMuteBell === bell, "the bell is not the row's own button")
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
        try #require(await settle { screen.debugMuteBell?.content.symbol == "bell" })
        #expect(screen.debugMuteBell?.accessibilityValue == "Nothing muted")
        #expect((screen.debugMuteMenuElements().first as? UIMenu)?.title == "Mute")
    }

    /// The bell's glyph and spoken state from the scopes — one mapping, the
    /// page's and the card's.
    @Test func theBellsGlyphComesFromTheScopes() {
        #expect(ProfileRelationControl.bellSymbol(for: .none) == "bell")
        #expect(ProfileRelationControl.bellSymbol(for: MuteScopes(stories: true)) == "bell.slash")
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
        try #require(await settle { screen.debugMuteBell?.content.symbol == "bell.slash" },
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
        #expect(screen.debugMuteBell?.content.symbol == "bell")
    }

    /// Not followed: NO bell (the owner, 2026-10-15 — nothing of theirs to
    /// mute yet; the header's Follow stands in its place), and see-more has
    /// no Map submenu and no Unfollow.
    @Test func anUnfollowedProfileHasNoBellAndNoMapSubmenu() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugMuteBell == nil, "a bell on a profile the viewer does not follow")
        #expect(screen.headerView.debugTrayItems == [.follow, .message, .qr, .more])
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"])
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
        #expect(screen.headerView.debugTrayItems == [.message, .qr, .more], "Following came back")
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
        #expect(screen.headerView.debugTrayItems == [.message, .qr, .more])
    }

    // MARK: - The see-more menu

    /// ⚠️ UNFOLLOW LEADS SEE-MORE ONCE FOLLOWED (#2302): first, red, and it
    /// unfollows — the tray's path, the optimistic flip; the bell morphs back
    /// into Follow and Unfollow leaves the menu.
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
        #expect(screen.headerView.debugTrayItems == [.follow, .message, .qr, .more])
        #expect(!titles(screen.debugMoreMenuElements()).contains("Unfollow"), "Unfollow stayed once unfollowed")
    }

    /// Requested: no Unfollow — withdrawing a request stays on Requested.
    @Test func aRequestedProfileHasNoUnfollow() async throws {
        let (screen, _, _) = makeScreen(relationship: .requested)
        try #require(await settle { screen.followButtonState == .requested })
        #expect(!titles(screen.debugMoreMenuElements()).contains("Unfollow"))
        #expect(screen.headerView.debugTrayItems == [.requested, .message, .qr, .more])
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

    // MARK: - The header's row

    /// ⚠️ THE ROW PER RELATION (#2302), the card's rule (#1562): the
    /// relationship's control comes from the one rule both read.
    @Test func theRowPerRelation() {
        typealias Header = ProfileHeaderView
        #expect(Header.trayItems(for: .follow, showsBell: true) == [.follow, .message, .qr, .more])
        #expect(Header.trayItems(for: .requested, showsBell: true) == [.requested, .message, .qr, .more])
        #expect(Header.trayItems(for: .following, showsBell: true) == [.bell, .message, .qr, .more])
        #expect(Header.trayItems(for: .following, showsBell: false) == [.message, .qr, .more])
        #expect(Header.trayItems(for: .unavailable, showsBell: true) == [.message, .qr, .more])
        #expect(Header.trayItems(for: .hidden, showsBell: true) == [.placeholder, .message, .qr, .more])
        #expect(Header.trayItems(for: .edit, showsBell: true) == [.edit, .qr, .more])
    }

    /// The page's row and the card's toolbar lead with the same control for
    /// every relation (#2302): they can no longer drift.
    @Test(arguments: [true, false])
    func thePagesRowAndTheCardsToolbarAgree(showsBell: Bool) {
        let states: [ProfileViewModel.FollowButton] = [.follow, .requested, .following, .unavailable, .hidden]
        for state in states {
            let page = ProfileHeaderView.trayItems(for: state, showsBell: showsBell).compactMap { item -> String? in
                switch item {
                case .follow: "follow"
                case .requested: "requested"
                case .bell: "bell"
                default: nil
                }
            }
            let card = ProfileCardViewController.toolbarItems(for: state, showsBell: showsBell).compactMap { item -> String? in
                switch item {
                case .follow: "follow"
                case .requested: "requested"
                case .bell: "bell"
                default: nil
                }
            }
            #expect(page == card, "\(state): the page leads with \(page), the card with \(card)")
        }
    }

    /// The header drawn per relation: what the rule says is what shows.
    @Test func theHeaderDrawsTheRowPerRelation() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let bell = ProfileHeaderView.Bell(scopes: .none)
        let cases: [(ProfileViewModel.FollowButton, ProfileHeaderView.Bell?)] = [
            (.hidden, bell), (.follow, bell), (.requested, bell), (.following, bell), (.following, nil),
            (.unavailable, bell), (.edit, nil),
        ]
        for (state, bell) in cases {
            header.configureAction(state, bell: bell)
            #expect(header.debugTrayItems == ProfileHeaderView.trayItems(for: state, showsBell: bell != nil),
                    "\(state), bell: \(bell != nil)")
        }
    }

    /// Follow · Message · QR · ⋯ — no star.
    @Test func theRowHasNoStar() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configureAction(.following, bell: ProfileHeaderView.Bell(scopes: .none))
        let symbols = header.debugTrayButtons.filter { !$0.isHidden }
            .compactMap { $0.configuration?.image?.description }
        #expect(header.debugTrayButtons.count == 5)
        #expect(!symbols.contains { $0.contains("star") }, "\(symbols)")
    }
}

// MARK: - The bar's corner and title (#2248)

/// No identity pill in the bar any more (#2248, the owner 2026-11-10,
/// replacing #1451 / #1590): someone else's pushed profile reads
/// `[‹ @handle] … [coins][Follow]` once the header's tray has scrolled away,
/// `… [coins][Requested]` on a private profile the viewer asked to follow,
/// and `… [coins]` once followed — the bell is the header's since #2302,
/// never the bar's. Each corner item native, under its own identifier, its
/// tap the tray's own path. The tab root keeps `[bell] … [day][coins][gear]`
/// and no title.
extension ProfileBellAndMapMenuTests {
    /// Not followed: nothing in the corner while the tray is on screen;
    /// once it has gone, `[Follow][space][coins]` — Follow in the corner, its
    /// own bubble — and nothing leading but the chevron. Back with the tray.
    @Test func aStrangersProfileWearsFollowInTheCornerOnceTheTrayHasGone() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.debugBarRelationshipItem == nil, "Follow showed in the bar with the tray's Follow on screen")
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"])

        screen.debugSetTrayScrolledAway(true)
        let follow = try #require(screen.debugBarRelationshipItem, "no Follow once the tray had gone")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 3, "no space between Follow and the balance")
        #expect(items[0] === follow, "Follow is not in the corner")
        #expect(items[2].accessibilityLabel == "Balance")
        #expect(follow.title == "Follow")
        #expect(follow.customView == nil, "Follow is a hosted view, not a native item")
        #expect(follow.identifier == ProfileViewController.followItemID)
        #expect((screen.navigationItem.leftBarButtonItems ?? []).isEmpty, "a leading item beside the chevron")
        #expect(screen.debugMuteBell == nil)

        screen.debugSetTrayScrolledAway(false)
        #expect(screen.debugBarRelationshipItem == nil, "Follow stayed with the tray back")
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"])
    }

    /// Requested, on a private profile: its own item, under its own
    /// identifier, in the same corner and by the same scroll rule.
    @Test func aRequestedProfileWearsRequestedInTheCorner() async throws {
        let (screen, _, _) = makeScreen(relationship: .requested)
        try #require(await settle { screen.followButtonState == .requested })
        #expect(screen.debugBarRelationshipItem == nil, "Requested showed with the tray on screen")

        screen.debugSetTrayScrolledAway(true)
        let requested = try #require(screen.debugBarRelationshipItem, "no Requested once the tray had gone")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.first === requested, "Requested is not in the corner")
        #expect(items.last?.accessibilityLabel == "Balance")
        #expect(requested.title == "Requested")
        #expect(requested.identifier == ProfileViewController.requestedItemID)
        #expect(requested.accessibilityHint == "Withdraws your follow request.")
        #expect(screen.debugMuteBell == nil)
    }

    /// ⚠️ THE CORNER NEVER WEARS THE BELL (#2302, the owner 2026-11-11):
    /// followed, the bar is `[coins]` alone, scrolled or not — no bell, no
    /// Follow, no Following up here: the bell is the header's.
    @Test func aFollowedProfilesCornerIsEmpty() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .other(isFollowing: true, isBlocked: false))
        try #require(await settle { screen.followButtonState == .following && viewModel.canModerate })
        try #require(await settle { screen.debugMuteBell != nil }, "guard: the header has its bell")
        for away in [false, true] {
            screen.debugSetTrayScrolledAway(away)
            let items = screen.navigationItem.rightBarButtonItems ?? []
            #expect(items.map(\.accessibilityLabel) == ["Balance"], "away=\(away): \(items.map(\.accessibilityLabel))")
            #expect(!items.contains { $0.image == UIImage(systemName: "bell") || $0.image == UIImage(systemName: "bell.slash") },
                    "a bell in the bar, away=\(away)")
            #expect(screen.debugBarRelationshipItem == nil, "a Follow item on a followed profile, away=\(away)")
            #expect(!items.contains { $0.title == "Following" }, "a Following item in the bar")
        }
    }

    /// Two items, two identifiers: UIKit tells them apart and morphs one
    /// into the other (#1679, R3).
    @Test func theCornerItemsHaveTheirOwnIdentifiers() {
        #expect(ProfileViewController.followItemID != ProfileViewController.requestedItemID)
    }

    /// No Follow where following is impossible or meaningless: blocked, a
    /// profile that blocks the viewer, the viewer's own.
    @Test(arguments: [
        ProfileRelationship.other(isFollowing: false, isBlocked: true),
        .cannotFollow,
    ])
    func noFollowWhereNoFollowApplies(relationship: ProfileRelationship) async throws {
        let (screen, viewModel, _) = makeScreen(relationship: relationship)
        try #require(await settle { viewModel.isRelationshipSettled })
        screen.debugSetTrayScrolledAway(true)
        #expect(screen.debugBarRelationshipItem == nil, "\(relationship)")
        #expect(screen.debugMuteBell == nil, "\(relationship)")
    }

    /// The bar's Follow is the tray's Follow — `headerView.onFollowTapped`,
    /// the member gate, the optimistic flip — so both turn at once.
    @Test func theBarsFollowFollowsThroughTheTraysPath() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        var trayCalls = 0
        let trayPath = screen.headerView.onFollowTapped
        screen.headerView.onFollowTapped = {
            trayCalls += 1
            trayPath?()
        }
        screen.debugSetTrayScrolledAway(true)
        let follow = try #require(screen.debugBarRelationshipItem)
        follow.primaryAction?.performWithSender(nil, target: nil)
        #expect(trayCalls == 1, "the bar's Follow went around the tray's path")
        try #require(await settle { screen.followButtonState == .following }, "the bar's Follow did not follow")
        #expect(screen.headerView.debugTrayItems.first == .bell, "the tray was left behind")
        #expect(screen.debugBarRelationshipItem == nil, "Follow stayed once followed")
    }

    /// Follow from the bar: one ANIMATED write of the group takes it out —
    /// no bell comes in its place (#2302) — on a bar at rest; the header's
    /// Follow is the bell now.
    @Test func followFromTheBarLeavesTheCornerAnimated() async throws {
        let (screen, viewModel, _, _, window) = hostedOnScreen(
            relationship: .other(isFollowing: false, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.followButtonState == .follow && screen.transitionCoordinator == nil })
        try #require(viewModel.canMute)
        screen.debugSetTrayScrolledAway(true)
        let follow = try #require(screen.debugBarRelationshipItem)
        let before = screen.debugBarWrites.count

        // The optimistic flip recomposes the bar on this same turn.
        follow.primaryAction?.performWithSender(nil, target: nil)

        #expect(screen.debugMuteBell != nil, "following from the bar brought no bell to the header")
        #expect(screen.navigationItem.rightBarButtonItems?.map(\.accessibilityLabel) == ["Balance"],
                "the corner is not empty once followed")
        #expect(screen.debugBarRelationshipItem == nil, "Follow stayed once followed")
        #expect(screen.debugBarWrites.count > before, "the bar was never written")
        #expect(screen.debugBarWrites.last == true, "Follow left the corner unanimated")
    }

    /// ⚠️ NEVER MID-PUSH (#756): Follow coming in while a child is being
    /// pushed over the profile waits for the bar to rest.
    ///
    /// ⚠️ THE PAGE IS SCROLLED FOR REAL (#2260). An earlier version forced
    /// the tray's state (`debugSetTrayScrolledAway`) without moving the page,
    /// and any layout pass of the covered profile recomputed that state from
    /// the real offset (`heroPageHeaderDidMove`, travelled 0) and took Follow
    /// back — under CI load that pass landed inside the wait. Here the
    /// gallery's own scroll view moves past the dock line, so every pass
    /// reads the same travel the finger would have left.
    @Test func followArrivingMidPushWaitsForRest() async throws {
        let (screen, _, _, navigation, window) = hostedOnScreen(
            relationship: .other(isFollowing: false, isBlocked: false)
        )
        defer { window.isHidden = true }
        try #require(await settle { screen.followButtonState == .follow && screen.transitionCoordinator == nil })
        let page = try #require(screen.heroPager.activePage, "guard: the gallery has a page")
        #expect(screen.debugBarRelationshipItem == nil, "guard: at rest the tray carries Follow")

        // ⚠️ THE PUSH RUNS FAST, NOT ON THE RUNNER'S CLOCK: on a starved CI
        // runner the real-time push outlived the settle below. The window's
        // layers run 50× faster: the push is still a running transition when
        // the page moves, and its end comes in a few frames whatever the load.
        window.layer.speed = 50
        defer { window.layer.speed = 1 }
        navigation.pushViewController(UIViewController(), animated: true)
        try #require(screen.transitionCoordinator != nil, "guard: the push is running")

        // The page's own offset, past the dock line: the travel the header
        // reads is the page's `verticalOffset`, whatever insets it counts.
        let scroller = page.scrollView
        let target = screen.headerTravel + 60
        scroller.contentOffset.y += target - page.verticalOffset
        try #require(abs(page.verticalOffset - target) < 1, "guard: the page did not move (\(page.verticalOffset))")
        #expect(screen.debugBarRelationshipItem == nil, "Follow came in mid-push")

        #expect(await settle { navigation.transitionCoordinator == nil }, "the push never ended")
        #expect(await settle { screen.debugBarRelationshipItem != nil }, "Follow never came in")
    }

    /// ⚠️ AT REST THE TRAY IS ON SCREEN: a push placed the header before it
    /// had laid out, read the tray as gone, and the bar's relationship showed
    /// over a profile that had not moved (the owner, on a device,
    /// 2026-10-15). Not followed, so Follow is what would show.
    @Test func aProfileAtRestWearsNoRelationshipInTheBar() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        screen.debugApplyHeaderOffset(0)
        #expect(screen.debugBarRelationshipItem == nil, "Follow showed at rest")
        screen.debugApplyHeaderOffset(-40)
        #expect(screen.debugBarRelationshipItem == nil, "Follow showed on a pull")
    }

    /// ⚠️ HISTORY'S DAY GOES TRAILING (#1590), innermost of the screen's own
    /// trailing items: `[Follow][space][coins][sep][day]` — the corner
    /// keeps Follow.
    @Test func historysDayIsTheInnermostTrailingItem() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        screen.debugSetTrayScrolledAway(true)
        screen.debugApplyPinnedSection(PostGridPinnedSection(index: 1, title: "Yesterday"))
        let day = try #require(screen.debugSectionItem, "the day is not trailing")
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.last === day, "the day is not the innermost trailing item")
        #expect(items[0] === screen.debugBarRelationshipItem, "Follow lost the corner")
        #expect(!(screen.navigationItem.leftBarButtonItems ?? []).contains { $0 === day }, "the day went leading")

        screen.debugApplyPinnedSection(nil)
        #expect(screen.debugSectionItem == nil, "the day stayed after the list went back to the top")
    }

    /// The @handle, native and leading (#2248): `navigationItem.title` with
    /// the `.browser` style — no title view, no leading item. ⚠️ NOT AT REST
    /// (#2268): the header shows it; whole once the tray has scrolled away.
    @Test func aPushedProfileIsTitledWithItsHandleLeading() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.navigationItem.title == nil, "the bar was titled at rest")
        screen.debugSetTrayScrolledAway(true)
        try #require(await settle { screen.navigationItem.title == "@lena" }, "the bar is not titled with the handle")
        #expect(screen.navigationItem.style == .browser, "the title does not lead")
        #expect(screen.navigationItem.titleView == nil, "a custom title view")
        #expect(screen.navigationItem.backButtonDisplayMode == .minimal)
        #expect(screen.navigationItem.largeTitleDisplayMode == .never)
        #expect(screen.navigationItem.leftItemsSupplementBackButton)
        // No banner on this profile: the see-through bar's title wears the
        // page's ink, not the white it wears over a picture.
        #expect(screen.debugRestingTitleInk == .label, "a white title over a page with no banner")
        screen.debugSetTrayScrolledAway(false)
        #expect(screen.navigationItem.title == nil, "the title stayed with the tray back")
    }

    /// ⚠️ FOLLOW AND THE BLUR COME AND GO TOGETHER (#2268, the owner
    /// 2026-11-10): one trigger, the tray going under the bar — with the
    /// @handle whole by then (#2334). The blur is UIKit's soft top edge on
    /// the pager, which spans the bar.
    @Test func followTheHandleAndTheBlurAreInSync() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow && screen.navigationItem.title == nil })
        let paging = try #require(screen.galleryPager.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(screen.debugBarRelationshipItem == nil)
        #expect(!screen.galleryPager.hasSoftTopEdge && paging.topEdgeEffect.isHidden, "a bar-tall blur at rest")

        screen.debugSetTrayScrolledAway(true)
        #expect(screen.debugBarRelationshipItem != nil, "no Follow")
        #expect(screen.navigationItem.title == "@lena", "no handle")
        #expect(screen.galleryPager.hasSoftTopEdge, "no blur")
        #expect(!paging.topEdgeEffect.isHidden && paging.topEdgeEffect.style == .soft, "the blur is not UIKit's soft edge")

        screen.debugSetTrayScrolledAway(false)
        #expect(screen.debugBarRelationshipItem == nil)
        #expect(screen.navigationItem.title == nil)
        #expect(!screen.galleryPager.hasSoftTopEdge && paging.topEdgeEffect.isHidden, "the blur stayed")
    }

    /// ⚠️ THE @HANDLE FOLLOWS THE SCROLL (#2334), as a large title does:
    /// while the header's @handle line passes under the bar, the bar's own
    /// native title comes in by steps — its ink at the passage's alpha, a
    /// few points low and climbing — and goes the same way down. Never from
    /// nothing to whole in one step; whole, it is the plain title in the
    /// bar's dress. Only the title moves: Follow and the blur wait for the
    /// tray (#2268).
    @Test func theHandleFollowsTheScrollThroughItsLine() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow && screen.navigationItem.title == nil })
        #expect(screen.navigationItem.attributedTitle == nil)

        // The way up, a step at a time.
        var opacities: [CGFloat] = []
        for step in 1...19 {
            screen.debugSetHandlePassage(CGFloat(step) / 20)
            opacities.append(screen.debugBarTitleOpacity)
            #expect(screen.navigationItem.title == "@lena", "step \(step): no handle")
            let attributed = try #require(screen.navigationItem.attributedTitle, "step \(step): not scrubbed")
            #expect(String(attributed.characters) == "@lena")
            let ink = try #require(attributed.uiKit.foregroundColor, "step \(step): no ink")
            var alpha: CGFloat = 0
            ink.resolvedColor(with: screen.traitCollection).getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #expect(abs(alpha - CGFloat(step) / 20) < 0.02, "step \(step): alpha \(alpha)")
            #expect(screen.navigationItem.titleView == nil, "a custom title view")
            #expect(screen.debugBarRelationshipItem == nil, "Follow came with the handle")
            #expect(!screen.galleryPager.hasSoftTopEdge, "the blur came with the handle")
        }
        #expect(opacities == opacities.sorted() && opacities.first! < 0.1, "not a gradual arrival: \(opacities)")

        // Whole: the plain native title, in the bar's own dress.
        screen.debugSetHandlePassage(1)
        #expect(screen.navigationItem.title == "@lena")
        #expect(screen.navigationItem.attributedTitle == nil, "a whole title kept its own ink")
        #expect(screen.debugBarTitleOpacity == 1)
        #expect(screen.debugBarRelationshipItem == nil && !screen.galleryPager.hasSoftTopEdge, "Follow or the blur left the tray's trigger")

        // The tray under the bar: Follow and the blur, the handle unchanged.
        screen.debugSetTrayScrolledAway(true)
        #expect(screen.debugBarRelationshipItem != nil && screen.galleryPager.hasSoftTopEdge)
        #expect(screen.navigationItem.title == "@lena" && screen.navigationItem.attributedTitle == nil)

        // The way down: the tray back, the line half way, then none.
        screen.debugSetTrayScrolledAway(false)
        #expect(screen.debugBarRelationshipItem == nil && !screen.galleryPager.hasSoftTopEdge)
        screen.debugSetHandlePassage(0.5)
        #expect(screen.navigationItem.title == "@lena")
        #expect(screen.navigationItem.attributedTitle != nil, "the way down is not scrubbed")
        #expect(screen.debugBarTitleOpacity == 0.5)
        screen.debugSetHandlePassage(0)
        #expect(screen.navigationItem.title == nil, "the title stayed with the line back")
        #expect(screen.navigationItem.attributedTitle == nil)
        #expect(screen.debugBarTitleOpacity == 0)
    }

    /// The tab root (the viewer's own) wears no handle however far its line
    /// has gone (#1642, #2334).
    @Test func theOwnProfilesHandleLineTitlesNothing() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        try #require(await settle { viewModel.isOwnProfile && viewModel.profile != nil })
        screen.debugSetHandlePassage(0.5)
        #expect(screen.navigationItem.title == nil && screen.navigationItem.attributedTitle == nil)
        screen.debugSetHandlePassage(1)
        #expect(screen.navigationItem.title == nil && screen.navigationItem.attributedTitle == nil)
    }

    /// Follow wears the primary colour (the bar's `.prominent`); Requested
    /// stays plain (#2268).
    @Test func followIsProminentAndRequestedPlain() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        screen.debugSetTrayScrolledAway(true)
        let follow = try #require(screen.debugBarRelationshipItem)
        #expect(follow.title == "Follow")
        #expect(follow.style == .prominent, "Follow is not in the primary colour")

        let (asked, _, _) = makeScreen(relationship: .requested)
        try #require(await settle { asked.followButtonState == .requested })
        asked.debugSetTrayScrolledAway(true)
        let requested = try #require(asked.debugBarRelationshipItem)
        #expect(requested.title == "Requested")
        #expect(requested.style == .plain, "Requested wears the colour")
        #expect(!DebugFlags.all.contains { $0.argument == "-profile-follow-prominent" }, "the flag is still listed")
    }

    /// The tab root (the viewer's own) keeps no title and the stock style:
    /// its leading group is the bell and the day (#1642).
    @Test func theOwnProfileWearsNothing() async throws {
        let (screen, viewModel, _) = makeScreen(relationship: .me, own: true)
        try #require(await settle { viewModel.isOwnProfile && viewModel.profile != nil })
        screen.debugSetTrayScrolledAway(true)
        #expect(screen.debugBarRelationshipItem == nil)
        #expect(screen.navigationItem.title == nil, "the tab root is titled")
        #expect(screen.navigationItem.style == .navigator)
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
}

// MARK: - The avatar's relation mark (#2014, #2050)

extension ProfileBellAndMapMenuTests {
    /// ONE MARK EVERYWHERE, THE "+" INCLUDED (#2050, the owner 2026-11-02,
    /// reversing #2014's "no '+'"): the one mapping, whole — "+", the
    /// clock, the check, friends. Nothing for someone blocked, the viewer's
    /// own profile or one not followable; the skeleton's badge for one not
    /// read yet (#2098), never on the viewer's own. A guest is not an
    /// exception: their relation reads as not followed, so the "+" (behind
    /// the member gate), as the author pill shows a guest.
    @Test func theAvatarWearsTheWholeMark() {
        typealias Header = ProfileHeaderView
        #expect(Header.avatarMark(for: .follow, mutual: false, blocked: false, isOwnProfile: false) == .follow)
        #expect(Header.avatarMark(for: .requested, mutual: false, blocked: false, isOwnProfile: false) == .pending)
        #expect(Header.avatarMark(for: .following, mutual: false, blocked: false, isOwnProfile: false) == .following)
        #expect(Header.avatarMark(for: .following, mutual: true, blocked: false, isOwnProfile: false) == .friends)
        for state in [ProfileViewModel.FollowButton.follow, .requested, .following] {
            #expect(Header.avatarMark(for: state, mutual: true, blocked: true, isOwnProfile: false) == PersonPill.Badge.none, "\(state)")
            #expect(Header.avatarMark(for: state, mutual: false, blocked: false, isOwnProfile: false)
                    == Header.relationBadge(for: state, mutual: false), "the avatar left the one mapping")
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

    /// Friends on the avatar: the two people and the accent ring.
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

    /// Not followed, the avatar wears the "+"; the tray's Follow brings the
    /// check.
    @Test func theTraysFollowBringsTheAvatarsCheck() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        #expect(screen.headerView.relationMark == .follow, "no + on the profile's avatar")
        #expect(screen.headerView.debugRelationSymbol == PersonPill.Badge.follow.symbolName)
        #expect(screen.headerView.debugTapFollow())
        try #require(await settle { screen.followButtonState == .following }, "the tray did not follow")
        #expect(screen.headerView.relationMark == .following, "the tray's Follow left the avatar behind")
    }

    /// THE AVATAR'S "+" IS THE TRAY'S FOLLOW (#2050): the check comes, and
    /// the tray's Follow turns into the bell with it (#2302) — one
    /// relationship, two places.
    @Test func theAvatarsPlusFollows() async throws {
        let (screen, _, _) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        let badge = try #require(screen.headerView.debugRelationBadge)
        #expect(badge.isUserInteractionEnabled, "the + takes no touches")
        badge.sendActions(for: .primaryActionTriggered)
        try #require(await settle { screen.followButtonState == .following }, "the avatar's + did not follow")
        #expect(screen.headerView.relationMark == .following)
        #expect(screen.headerView.debugTrayItems.first == .bell, "the tray was left behind")
        #expect(!badge.isUserInteractionEnabled, "the check takes touches")
    }

    /// Refused, the "+" comes back, as the tray's Follow does.
    @Test func aRefusedPlusComesBack() async throws {
        let (screen, _, repository) = makeScreen(relationship: .other(isFollowing: false, isBlocked: false))
        try #require(await settle { screen.followButtonState == .follow })
        repository.refusesFollowChange = true
        screen.headerView.debugRelationBadge?.sendActions(for: .primaryActionTriggered)
        try #require(await settle { screen.followButtonState == .following }, "no optimistic flip")
        try #require(await settle { screen.followButtonState == .follow }, "the refusal was not put back")
        #expect(screen.headerView.relationMark == .follow, "the + did not come back")
    }

    /// Only the "+" calls the follow: the check, friends and the clock do
    /// nothing — unfollowing stays in the tray. VoiceOver reads the badge as
    /// a button, "Follow", only while it is the "+".
    @Test func onlyThePlusCallsTheFollow() throws {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        var follows = 0
        header.onFollowTapped = { follows += 1 }
        let badge = try #require(header.debugRelationBadge)
        for mark in [PersonPill.Badge.following, .friends, .pending, .none] {
            header.setRelationMark(mark, animated: false)
            badge.sendActions(for: .primaryActionTriggered)
            #expect(follows == 0, "\(mark) called the follow")
            #expect(!badge.accessibilityTraits.contains(.button), "\(mark) reads as a button")
        }
        #expect(badge.accessibilityLabel == nil && !badge.isAccessibilityElement, "none is read")
        header.setRelationMark(.friends, animated: false)
        #expect(badge.accessibilityLabel == "Friends")
        header.setRelationMark(.pending, animated: false)
        #expect(badge.accessibilityLabel == "Requested")
        header.setRelationMark(.follow, animated: false)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(follows == 1, "the + did not call the follow")
        #expect(badge.isAccessibilityElement && badge.accessibilityTraits.contains(.button))
        #expect(badge.accessibilityLabel == "Follow")
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
