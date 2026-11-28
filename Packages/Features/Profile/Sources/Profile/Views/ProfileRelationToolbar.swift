import DesignSystem
import ProfileData
import UIKit

/// Someone's relationship actions as a BOTTOM TOOLBAR — ONE SOURCE for the
/// profile card (#1542, #1562) and someone else's profile (#2475, the owner
/// 2026-11-28), so the two screens can never draw one relationship two ways:
///
/// | Relation                    | Toolbar                      |
/// |-----------------------------|------------------------------|
/// | not followed (a guest too)  | `[——Follow——][💬][QR]`       |
/// | requested                   | `[——Requested——][💬][QR]`    |
/// | followed, a member          | `[🔔][——Message——][QR]`      |
/// | followed, no bell           | `[——Message——][QR]`          |
/// | not followable, not read yet | `[——Message——][QR]`         |
/// | the viewer's own (the card) | `[View Profile]`             |
///
/// - **Each action in its own bubble**: a zero-width space between two
///   items keeps UIKit from joining them in one shared platter.
/// - **The relationship's control** is the one rule the card always read
///   (`ProfileRelationControl`): Follow, Requested — the same item in two
///   states (#1668) — or the mute bell once followed (#2302).
///
/// ⚠️ ONLY THE ITEM THAT CHANGED MOVES (#2331): every item is kept by
/// identifier (`BarItemStore`) and dressed in place — Follow ↔ Requested is
/// one item whose word and prominence change, the bell takes its new glyph,
/// Message stretches or not — and the bar is handed the items only when the
/// list changes. No animation of ours (#1672): the bar draws every bubble.
@MainActor
final class ProfileRelationToolbar {
    /// One place of the toolbar. Pure, for tests.
    nonisolated enum Item: Equatable, Sendable {
        case follow, requested, openProfile, message, bell, qr
    }

    /// What the items do, and the scopes the bell's menu reads as it opens.
    struct Actions {
        var follow: () -> Void
        var message: () -> Void
        var qrCode: () -> Void
        var openProfile: () -> Void
        var muteScopes: () -> MuteScopes
        var toggleMute: (MuteScope) -> Void
    }

    private let actions: Actions
    /// The toolbar's items, kept by identifier (#2331).
    private let toolbarStore = BarItemStore()
    /// The glyph the bell wears now.
    private var shownBellSymbol: String?
    /// What the toolbar last showed: handed to the bar only when it changes.
    private(set) var shownItems: [Item]?

    init(actions: Actions) {
        self.actions = actions
    }

    // MARK: - The rules (pure)

    /// The toolbar's items for a relationship (the table above).
    /// `showsBell`: a member who can mute (`ProfileRelationControl.showsMuteBell`);
    /// `showsQR`: a share card to show (or the profile not loaded yet).
    nonisolated static func items(
        for followButton: ProfileViewModel.FollowButton, showsBell: Bool = true, showsQR: Bool = true
    ) -> [Item] {
        let qr: [Item] = showsQR ? [.qr] : []
        switch followButton {
        // A private profile asked: its request is withdrawn from its item.
        case .follow, .following, .requested:
            let control: [Item] = switch ProfileRelationControl.control(for: followButton, showsBell: showsBell) {
            case .follow?: [.follow]
            case .requested?: [.requested]
            case .bell?: [.bell]
            case nil: []
            }
            return control + [.message] + qr
        // Not followable (#726), or unknown yet: what does not depend on it.
        case .unavailable, .hidden: return [.message] + qr
        // The viewer's own profile, reached by id: nothing to do here but
        // open it.
        case .edit: return [.openProfile]
        }
    }

    /// The item that takes the toolbar's free width (#1542): Follow while
    /// the viewer does not follow, Requested once asked in the same slot
    /// (#1668), Message once followed or not followable. Nil: nothing
    /// stretches (the viewer's own profile).
    nonisolated static func wideItem(in items: [Item]) -> Item? {
        if items.contains(.follow) { return .follow }
        if items.contains(.requested) { return .requested }
        if items.contains(.message) { return .message }
        return nil
    }

    /// The identity UIKit matches an item by across a rebuild: by what it
    /// DOES, so Follow and Requested are one item in two states, Message
    /// stays Message as a glyph or a word, and Follow is never taken for the
    /// bell that replaces it once followed (#1678). One identifier per
    /// action on both screens (R2).
    nonisolated static func barIdentifier(for item: Item) -> String {
        switch item {
        case .follow, .requested: "profile.relation.follow"
        case .message: "profile.relation.message"
        case .openProfile: "profile.relation.openProfile"
        case .bell: "profile.relation.bell"
        case .qr: "profile.relation.qr"
        }
    }

    // MARK: - The bar

    /// Hands `items` to `controller`'s toolbar, each item kept and dressed
    /// for now — the bell for `muteScopes`, enabled or not. The bar is told
    /// only when the list changed (`BarItemStore.apply`).
    func apply(
        _ items: [Item], muteScopes: MuteScopes, bellEnabled: Bool = true,
        to controller: UIViewController, animated: Bool
    ) {
        shownItems = items
        var bar: [UIBarButtonItem] = []
        let wide = Self.wideItem(in: items)
        for kind in items {
            // Each in its own bubble: the zero-width fixed space, kept with
            // the item it stands before.
            let id = Self.barIdentifier(for: kind)
            if !bar.isEmpty { bar.append(toolbarStore.separator(before: id)) }
            bar.append(item(for: kind, wide: kind == wide, muteScopes: muteScopes, bellEnabled: bellEnabled))
        }
        toolbarStore.apply(toolbar: bar, to: controller, animated: animated)
    }

    /// The kept item for `kind`, dressed for now.
    private func item(
        for kind: Item, wide: Bool, muteScopes: MuteScopes, bellEnabled: Bool
    ) -> UIBarButtonItem {
        let id = Self.barIdentifier(for: kind)
        switch kind {
        case .follow, .requested:
            // One item in two states (#1668): its word and its prominence
            // change in place. It always takes the free width (`wideItem`).
            return toolbarStore.item(id) {
                let made = BarItems.stretched(id: id, title: "Follow", prominent: true) { [actions] in actions.follow() }
                made.label.accessibilityIdentifier = id
                return made.item
            } update: { item in
                BarItems.update(stretched: item, title: kind == .follow ? "Follow" : "Requested", prominent: kind == .follow)
                (item.customView as? StretchedBarLabel)?.stretches = wide
                item.customView?.accessibilityHint = kind == .requested ? "Withdraws your follow request." : nil
            }
        case .message:
            // The same item whether it takes the free width (followed, or
            // not followable) or stands beside Follow: only its stretch
            // changes (#2331). A plain view in the bar's bubble either way.
            return toolbarStore.item(id) {
                let made = BarItems.stretched(id: id, title: "Message") { [actions] in actions.message() }
                made.label.accessibilityIdentifier = id
                return made.item
            } update: { item in
                (item.customView as? StretchedBarLabel)?.stretches = wide
            }
        case .bell:
            return toolbarStore.item(id) {
                BarItems.icon(id: id, image: nil, label: "Notifications", menu: UIMenu(children: [
                    UIDeferredMenuElement.uncached { [actions] completion in
                        completion(ProfileMenuBuilder.muteMenuElements(actions.muteScopes()) { scope in
                            actions.toggleMute(scope)
                        })
                    },
                ]))
            } update: { [self] item in
                // Its glyph in place (R7), written only when the scope moves
                // it; the menu reads the scopes as it opens.
                let symbol = ProfileRelationControl.bellSymbol(for: muteScopes)
                if item.image == nil || shownBellSymbol != symbol {
                    item.image = UIImage.symbol(named: symbol)
                    shownBellSymbol = symbol
                }
                item.accessibilityValue = ProfileRelationControl.bellAccessibilityValue(for: muteScopes)
                // A handle or link route has no one to mute until its read
                // names someone else.
                if item.isEnabled != bellEnabled { item.isEnabled = bellEnabled }
            }
        case .qr:
            return toolbarStore.item(id) {
                BarItems.icon(id: id, image: UIImage(systemName: "qrcode"), label: "QR Code") { [actions] in
                    actions.qrCode()
                }
            }
        case .openProfile:
            return toolbarStore.item(id) {
                BarItems.title(id: id, title: "View Profile", prominent: true) { [actions] in actions.openProfile() }
            }
        }
    }

    /// Shows the stack's toolbar for `screen` — riding the push or pop that
    /// brings it in.
    static func show(for screen: UIViewController, animated: Bool) {
        screen.navigationController?.setToolbarHidden(false, animated: animated)
    }

    /// Puts the stack's toolbar away as `screen` leaves, unless the screen
    /// taking over brings items of its own (it adopts the shared bar in its
    /// own `viewWillAppear`).
    static func hide(leaving screen: UIViewController, animated: Bool) {
        guard let navigation = screen.navigationController,
              navigation.topViewController?.toolbarItems?.isEmpty ?? true
        else { return }
        navigation.setToolbarHidden(true, animated: animated)
    }

    #if DEBUG
    /// How many times the toolbar was handed its items. Tests.
    var debugWrites: Int { toolbarStore.debugWrites }
    /// The glyph the bell wears, while the toolbar shows it. Tests.
    var debugBellSymbol: String? { shownItems?.contains(.bell) == true ? shownBellSymbol : nil }
    #endif
}

extension UIViewController {
    /// The toolbar's item for `kind` (`ProfileRelationToolbar`), when it
    /// shows one — what a test and a QA probe read.
    func relationToolbarItem(_ kind: ProfileRelationToolbar.Item) -> UIBarButtonItem? {
        let id = ProfileRelationToolbar.barIdentifier(for: kind)
        return (toolbarItems ?? []).first { $0.identifier == id }
    }

    /// The item taking the toolbar's free width, its view.
    var relationToolbarWideLabel: StretchedBarLabel? {
        (toolbarItems ?? []).lazy.compactMap { $0.customView as? StretchedBarLabel }.first { $0.stretches }
    }
}
