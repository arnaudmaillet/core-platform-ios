import MapsInterface
import PostGrid
import Testing
import UIKit
@testable import Profile

// The profile's menus from plain inputs (#846): no view controller.

/// Records which handler a row fired.
@MainActor
private final class Taps {
    var fired: [String] = []
    var toggledCategories: [MapFavoriteCategory] = []
    var toggledScopes: [MuteScope] = []

    var handlers: ProfileMenuBuilder.MoreMenuHandlers {
        ProfileMenuBuilder.MoreMenuHandlers(
            share: { self.fired.append("share") },
            copyLink: { self.fired.append("copyLink") },
            toggleMapCategory: { self.toggledCategories.append($0) },
            report: { self.fired.append("report") },
            toggleRestrict: { self.fired.append("toggleRestrict") },
            unblock: { self.fired.append("unblock") },
            confirmBlock: { self.fired.append("confirmBlock") }
        )
    }
}

private func state(
    canShare: Bool = true,
    mapPin: ProfileViewModel.MapPinButton = .hidden,
    canModerate: Bool = true,
    isGuest: Bool = false,
    canRestrict: Bool = true,
    isRestricted: Bool = false,
    isBlocked: Bool = false
) -> ProfileMenuBuilder.MoreMenuState {
    ProfileMenuBuilder.MoreMenuState(
        canShare: canShare, mapPin: mapPin, canModerate: canModerate, isGuest: isGuest,
        canRestrict: canRestrict, isRestricted: isRestricted, isBlocked: isBlocked
    )
}

/// Each inline group's row titles, in order.
@MainActor
private func groups(_ elements: [UIMenuElement]) -> [[String]] {
    elements.map { element in
        (element as? UIMenu)?.children.map(\.title) ?? [element.title]
    }
}

@MainActor
private func action(_ title: String, in elements: [UIMenuElement]) -> UIAction? {
    for element in elements {
        if let action = element as? UIAction, action.title == title { return action }
        if let menu = element as? UIMenu, let found = action(title, in: menu.children) { return found }
    }
    return nil
}

@MainActor
struct ProfileMenuBuilderTests {
    // MARK: See-more menu

    @Test func yourOwnProfileOffersSharingAndNoModeration() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(canModerate: false), handlers: Taps().handlers)
        #expect(groups(menu) == [["Share", "Copy Link"]])
    }

    @Test func aProfileNotLoadedYetHasAnEmptyMenu() {
        let menu = ProfileMenuBuilder.moreMenuElements(
            state(canShare: false, canModerate: false), handlers: Taps().handlers
        )
        #expect(menu.isEmpty)
    }

    @Test func someoneElsesProfileOffersRestrictThenBlockAndReport() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(), handlers: Taps().handlers)
        #expect(groups(menu) == [["Share", "Copy Link"], ["Restrict"], ["Block", "Report"]])
        #expect(action("Block", in: menu)?.attributes == .destructive)
        #expect(action("Report", in: menu)?.attributes == .destructive)
    }

    @Test func restrictIsLeftOutWhereTheAppCannotRestrict() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(canRestrict: false), handlers: Taps().handlers)
        #expect(groups(menu) == [["Share", "Copy Link"], ["Block", "Report"]])
    }

    @Test func aRestrictedProfileOffersUnrestrict() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(isRestricted: true), handlers: Taps().handlers)
        #expect(groups(menu)[1] == ["Unrestrict"])
    }

    @Test func aBlockedProfileOffersAnUnblockThatIsNotRed() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(isBlocked: true), handlers: Taps().handlers)
        #expect(action("Unblock", in: menu)?.attributes == [])
        #expect(action("Block", in: menu) == nil)
    }

    @Test func aGuestCanReportButNotBlockOrRestrict() {
        let menu = ProfileMenuBuilder.moreMenuElements(state(isGuest: true), handlers: Taps().handlers)
        #expect(groups(menu) == [["Share", "Copy Link"], ["Report"]])
    }

    @Test func blockAsksFirstAndUnblockGoesStraightThrough() {
        let taps = Taps()
        action("Block", in: ProfileMenuBuilder.moreMenuElements(state(), handlers: taps.handlers))?
            .performWithSender(nil, target: nil)
        action("Unblock", in: ProfileMenuBuilder.moreMenuElements(state(isBlocked: true), handlers: taps.handlers))?
            .performWithSender(nil, target: nil)
        #expect(taps.fired == ["confirmBlock", "unblock"])
    }

    @Test func eachRowFiresItsOwnHandler() {
        let taps = Taps()
        let menu = ProfileMenuBuilder.moreMenuElements(state(), handlers: taps.handlers)
        for title in ["Share", "Copy Link", "Restrict", "Report"] {
            action(title, in: menu)?.performWithSender(nil, target: nil)
        }
        #expect(taps.fired == ["share", "copyLink", "toggleRestrict", "report"])
    }

    @Test func aFollowedProfileGetsAMapSubmenuBeforeModeration() {
        let menu = ProfileMenuBuilder.moreMenuElements(
            state(mapPin: .shown(categories: [], includesFriends: false)), handlers: Taps().handlers
        )
        #expect(groups(menu) == [["Share", "Copy Link"], ["Map"], ["Restrict"], ["Block", "Report"]])
    }

    // MARK: Map rails

    @Test func noMapSubmenuWhileTheStarIsNotOffered() {
        #expect(ProfileMenuBuilder.mapFavoriteSubmenu(.hidden) { _ in } == nil)
    }

    @Test func friendsIsOfferedToAMutualOnly() {
        let followed = ProfileMenuBuilder.mapFavoriteMenuActions(.shown(categories: [], includesFriends: false)) { _ in }
        let mutual = ProfileMenuBuilder.mapFavoriteMenuActions(.shown(categories: [], includesFriends: true)) { _ in }
        #expect(followed.map(\.title) == ["Map Dock", "Following Filter"])
        #expect(mutual.map(\.title) == ["Map Dock", "Following Filter", "Friends Filter"])
        #expect(mutual.allSatisfy { $0.attributes.contains(.keepsMenuPresented) })
    }

    @Test func theRailsTheProfileIsOnAreTickedAndNamed() throws {
        let submenu = try #require(ProfileMenuBuilder.mapFavoriteSubmenu(
            .shown(categories: [.dock, .following], includesFriends: true)
        ) { _ in })
        let rows = submenu.children.compactMap { $0 as? UIAction }
        #expect(rows.map(\.state) == [.on, .on, .off])
        #expect(submenu.subtitle == "Map Dock, Following Filter")
        #expect(submenu.image == UIImage(systemName: "star.circle.fill"))
    }

    @Test func anUnfavoritedProfileWearsTheOutlineStarAndNoSubtitle() throws {
        let submenu = try #require(ProfileMenuBuilder.mapFavoriteSubmenu(
            .shown(categories: [], includesFriends: false)
        ) { _ in })
        #expect(submenu.subtitle == nil)
        #expect(submenu.image == UIImage(systemName: "star.circle"))
    }

    @Test func aRailRowTogglesItsOwnCategory() {
        let taps = Taps()
        let rows = ProfileMenuBuilder.mapFavoriteMenuActions(.shown(categories: [], includesFriends: true)) {
            taps.toggledCategories.append($0)
        }
        rows.forEach { $0.performWithSender(nil, target: nil) }
        #expect(taps.toggledCategories == [.dock, .following, .friends])
    }

    @Test func reTickingAnOpenMenuFollowsTheNewRailsAndKeepsTheRest() throws {
        let root = UIMenu(children: ProfileMenuBuilder.moreMenuElements(
            state(mapPin: .shown(categories: [], includesFriends: false)), handlers: Taps().handlers
        ))
        let reticked = ProfileMenuBuilder.retickingMapRows(in: root, to: [.following])
        #expect(groups(reticked.children) == groups(root.children))
        #expect(action("Following Filter", in: reticked.children)?.state == .on)
        #expect(action("Map Dock", in: reticked.children)?.state == .off)
        let submenus = reticked.children.compactMap { ($0 as? UIMenu)?.children.first as? UIMenu }
        let map = try #require(submenus.first)
        #expect(map.subtitle == "Following Filter")
    }

    // MARK: Mute bell

    @Test func nothingMutedReadsMuteWithEveryScopeOff() throws {
        let menu = try #require(ProfileMenuBuilder.muteMenuElements(.none) { _ in }.first as? UIMenu)
        #expect(menu.title == "Mute")
        #expect(menu.subtitle == nil)
        #expect(menu.children.count == MuteScope.allCases.count)
        #expect(menu.children.allSatisfy { ($0 as? UIAction)?.state == .off })
    }

    @Test func aMutedScopeIsTickedUnderAMutedTitle() throws {
        let scopes = MuteScopes(posts: true)
        let menu = try #require(ProfileMenuBuilder.muteMenuElements(scopes) { _ in }.first as? UIMenu)
        #expect(menu.title == "Muted")
        #expect(menu.subtitle == scopes.summary)
        #expect((menu.children.first as? UIAction)?.state == .on)
    }

    @Test func aScopeRowTogglesItsScope() {
        let taps = Taps()
        let menu = ProfileMenuBuilder.muteMenuElements(.none) { taps.toggledScopes.append($0) }
        (menu.first as? UIMenu)?.children.forEach { ($0 as? UIAction)?.performWithSender(nil, target: nil) }
        #expect(taps.toggledScopes == MuteScope.allCases)
    }

    // MARK: Gallery card

    @Test func yourOwnPostOffersEditAndDelete() {
        let rows = ProfileMenuBuilder.galleryMenuActions(isViewerPost: true, canReport: true, onDelete: {}, onReport: {})
        #expect(rows.map(\.title) == ["Edit post", "Delete post"])
    }

    @Test func someoneElsesPostOffersReportWhereTheScreenCanFile() {
        let reportable = ProfileMenuBuilder.galleryMenuActions(isViewerPost: false, canReport: true, onDelete: {}, onReport: {})
        let unreportable = ProfileMenuBuilder.galleryMenuActions(isViewerPost: false, canReport: false, onDelete: {}, onReport: {})
        #expect(reportable.map(\.title) == ["Report"])
        #expect(unreportable.isEmpty)
    }

    @Test func deleteAndReportFireTheirHandlers() {
        let taps = Taps()
        let own = ProfileMenuBuilder.galleryMenuActions(
            isViewerPost: true, canReport: false,
            onDelete: { taps.fired.append("delete") }, onReport: { taps.fired.append("report") }
        )
        let other = ProfileMenuBuilder.galleryMenuActions(
            isViewerPost: false, canReport: true,
            onDelete: { taps.fired.append("delete") }, onReport: { taps.fired.append("report") }
        )
        for rows in [own, other] {
            let menu = PostCardMenu.menu(for: rows)
            menu?.children.forEach { ($0 as? UIAction)?.performWithSender(nil, target: nil) }
        }
        // Edit is named before it exists: its handler does nothing.
        #expect(taps.fired == ["delete", "report"])
    }
}
