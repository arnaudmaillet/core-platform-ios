import MapsInterface
import PostGrid
import UIKit

/// Builds the profile screen's menus from plain inputs (#846): the see-more
/// menu, its Map submenu and rows, the nav bar's mute bell menu, and a gallery
/// card's "..." rows.
///
/// Every input is a value the controller reads off the view model at OPEN time
/// (the menus are deferred, uncached elements), and every action is a handler
/// the controller hands in — presenting a sheet, confirming a block, toggling a
/// rail. So which rows exist, in what order, ticked or not, is decided here
/// and tested here, without a view controller.
@MainActor
enum ProfileMenuBuilder {
    // MARK: - See-more menu

    /// What the see-more menu depends on, read when it opens.
    struct MoreMenuState: Equatable {
        /// Sharing needs a loaded handle (`ProfileViewModel.shareCard`).
        var canShare: Bool
        var mapPin: ProfileViewModel.MapPinButton
        /// Someone else's profile, once the relationship says so
        /// (`ProfileViewModel.canModerate`).
        var canModerate: Bool
        /// A guest: no account to block or restrict from.
        var isGuest: Bool
        var canRestrict: Bool
        var isRestricted: Bool
        var isBlocked: Bool
    }

    /// What the see-more menu's rows do.
    struct MoreMenuHandlers {
        var share: () -> Void
        var copyLink: () -> Void
        var toggleMapCategory: (MapFavoriteCategory) -> Void
        var report: () -> Void
        var toggleRestrict: () -> Void
        var unblock: () -> Void
        var confirmBlock: () -> Void
    }

    static func moreMenuElements(_ state: MoreMenuState, handlers: MoreMenuHandlers) -> [UIMenuElement] {
        // Sharing needs a loaded handle; until then the menu is honestly empty
        // rather than offering an action that would no-op.
        var groups: [UIMenuElement] = []
        if state.canShare {
            groups.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    handlers.share()
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    handlers.copyLink()
                }
            ]))
        }
        // The map's rails (#689), where the star beside Message used to be.
        if let map = mapFavoriteSubmenu(state.mapPin, onToggle: handlers.toggleMapCategory) {
            groups.append(UIMenu(options: .displayInline, children: [map]))
        }
        // Own profile (and the pre-relationship window) offers no moderation:
        // you cannot block or report yourself, and guessing is worse than
        // waiting — the menu is rebuilt on the next open either way.
        guard state.canModerate else { return groups }

        let report = UIAction(
            title: "Report",
            image: UIImage(systemName: "flag"),
            attributes: .destructive
        ) { _ in handlers.report() }
        // A guest can report (anyone may flag illegal content, DSA Art. 16)
        // but has no account to block from.
        if state.isGuest {
            groups.append(UIMenu(options: .displayInline, children: [report]))
            return groups
        }

        // Mute is the nav bar's bell now (#689, `muteMenuElements`).
        if state.canRestrict {
            let restricted = state.isRestricted
            // Restrict (#416): their comments on your posts are seen only
            // by them and you.
            groups.append(UIMenu(options: .displayInline, children: [UIAction(
                title: restricted ? "Unrestrict" : "Restrict",
                image: UIImage(systemName: restricted ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus")
            ) { _ in handlers.toggleRestrict() }]))
        }

        let blocked = state.isBlocked
        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: blocked ? "Unblock" : "Block",
                image: UIImage(systemName: blocked ? "hand.raised.slash" : "hand.raised"),
                // Unblocking is a restorative action, so it sheds the
                // destructive red that blocking earns.
                attributes: blocked ? [] : .destructive
            ) { _ in
                // Unblocking is harmless and reversible — it goes straight
                // through; blocking asks first, and asks how far it reaches.
                if blocked {
                    handlers.unblock()
                } else {
                    handlers.confirmBlock()
                }
            },
            report
        ]))
        return groups
    }

    // MARK: - Map rails

    /// The mutual's rail menu: a two-row CHECKLIST, Friends and Following,
    /// each an independent toggle showing whether the profile is on that rail.
    ///
    /// Two rows, not three. Two rails have four states, and two checkmarks
    /// show all four and reach any of them in a tap — including "both", which
    /// an explicit Both row used to spell a second time. That row also had to
    /// mean two different things depending on state it could not itself show
    /// (add both, or clear both), which is exactly the ambiguity a checkmark
    /// does not have.
    ///
    /// `.keepsMenuPresented` because a checklist that closes after one tick
    /// makes setting both rails a two-open chore. The marks are updated in
    /// the open menu as the state changes (`refreshVisibleMapRows`), so they
    /// track what was just chosen.
    ///
    /// ⚠️ A SUBMENU OF SEE-MORE, NOT A STAR (#689, the owner's call
    /// 2026-10-08): the star left the header's row. Same rows, same rule —
    /// only a followed profile, Friends only for a mutual, only when the app
    /// wired a pinning service (`ProfileViewModel.MapPinButton`).
    static func mapFavoriteSubmenu(
        _ state: ProfileViewModel.MapPinButton,
        onToggle: @escaping (MapFavoriteCategory) -> Void
    ) -> UIMenu? {
        guard state != .hidden else { return nil }
        let rows = mapFavoriteMenuActions(state, onToggle: onToggle)
        return UIMenu(
            title: "Map",
            subtitle: mapFavoriteSubtitle(rows),
            image: UIImage(systemName: state.isFavorited ? "star.circle.fill" : "star.circle"),
            identifier: mapMenuIdentifier,
            children: rows
        )
    }

    /// The checklist's rows for the CURRENT state, apart from the menu that
    /// hosts them — the same split `moreMenuElements` uses, and for the same
    /// reason: a `UIMenu` opens on a tap, the simulator has none, and this is
    /// what `-profile-map-pin-audit` prints instead of guessing.
    static func mapFavoriteMenuActions(
        _ state: ProfileViewModel.MapPinButton,
        onToggle: @escaping (MapFavoriteCategory) -> Void
    ) -> [UIAction] {
        let current = state.categories
        var rows: [(MapFavoriteCategory, String, String)] = [
            (.dock, "Map Dock", "pin"),
            (.following, "Following Filter", "person.badge.plus")
        ]
        // Friends is OMITTED for someone who is not a mutual, not shown
        // disabled: a greyed row invites a tap that can never work and
        // explains nothing about why. The view model refuses the write anyway
        // — this is the same rule, said in the place the viewer reads.
        if state.includesFriends {
            rows.append((.friends, "Friends Filter", "person.2"))
        }
        return rows.map { category, title, symbol in
            let action = UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                identifier: mapRowIdentifier(category),
                state: current.contains(category) ? .on : .off
            ) { _ in
                onToggle(category)
            }
            action.attributes = .keepsMenuPresented
            return action
        }
    }

    /// Ticks the rail rows of an open menu to `current`: a row keeps the menu
    /// open, and its mark must follow.
    ///
    /// ⚠️ THE CONTROLLER'S BLOCK RUNS ONCE PER MENU ON SCREEN — the root, then
    /// the open Map submenu (simulator, 2026-10-09). Rebuilding the root's
    /// children in it put the whole see-more menu inside the Map submenu, so
    /// each run only re-ticks the rail rows it holds, by identifier, on copies.
    static func retickingMapRows(in menu: UIMenu, to current: Set<MapFavoriteCategory>) -> UIMenu {
        let reticked = menu.replacingChildren(menu.children.map { child in
            if let submenu = child as? UIMenu { return retickingMapRows(in: submenu, to: current) }
            guard let action = child as? UIAction,
                  let category = mapCategory(for: action.identifier),
                  let copy = action.copy() as? UIAction else { return child }
            copy.state = current.contains(category) ? .on : .off
            return copy
        })
        // The Map submenu's subtitle lists the rails it is on.
        if menu.identifier == mapMenuIdentifier {
            reticked.subtitle = mapFavoriteSubtitle(reticked.children.compactMap { $0 as? UIAction })
        }
        return reticked
    }

    static let mapMenuIdentifier = UIMenu.Identifier("profile.map")

    /// "Map Dock, Following Filter" — the ticked rows, or nothing.
    private static func mapFavoriteSubtitle(_ rows: [UIAction]) -> String? {
        let on = rows.filter { $0.state == .on }.map(\.title)
        return on.isEmpty ? nil : on.joined(separator: ", ")
    }

    /// Stable identities for the rail rows: how an open menu's rows are
    /// found again to re-tick them.
    private static func mapRowIdentifier(_ category: MapFavoriteCategory) -> UIAction.Identifier {
        switch category {
        case .dock: UIAction.Identifier("profile.map.dock")
        case .following: UIAction.Identifier("profile.map.following")
        case .friends: UIAction.Identifier("profile.map.friends")
        }
    }

    private static func mapCategory(for identifier: UIAction.Identifier) -> MapFavoriteCategory? {
        [MapFavoriteCategory.dock, .following, .friends].first { mapRowIdentifier($0) == identifier }
    }

    // MARK: - Mute bell

    /// One toggle per scope: muting is a set of quiet preferences, not one
    /// switch (backend #722). Titled "Mute", or "Muted" over a summary of
    /// what is.
    static func muteMenuElements(
        _ scopes: MuteScopes, onToggle: @escaping (MuteScope) -> Void
    ) -> [UIMenuElement] {
        [UIMenu(
            title: scopes.isEmpty ? "Mute" : "Muted",
            subtitle: scopes.isEmpty ? nil : scopes.summary,
            options: .displayInline,
            children: MuteScope.allCases.map { scope in
                UIAction(
                    title: scope.title,
                    state: scopes.contains(scope) ? .on : .off
                ) { _ in onToggle(scope) }
            }
        )]
    }

    // MARK: - Gallery card

    /// A gallery card's "..." rows.
    ///
    /// The viewer's OWN post offers what a post of one's own is for. Edit is
    /// named before it exists (its handler is empty); Delete sends the post
    /// to Recently Deleted for 30 days (#408). Anyone else's post: Report
    /// only, when the screen can file one.
    ///
    /// Unfollow is deliberately absent: this screen already centralises the
    /// relationship on the header's one control, and a second way to change it
    /// — sitting on a row, worded differently, reachable while the header says
    /// the opposite — is how two truths about one relationship end up on screen
    /// at once.
    static func galleryMenuActions(
        isViewerPost: Bool,
        canReport: Bool,
        onDelete: @escaping () -> Void,
        onReport: @escaping () -> Void
    ) -> [PostCardMenuAction] {
        if isViewerPost {
            return [.edit {}, .delete(perform: onDelete)]
        }
        guard canReport else { return [] }
        return [.report(perform: onReport)]
    }
}
