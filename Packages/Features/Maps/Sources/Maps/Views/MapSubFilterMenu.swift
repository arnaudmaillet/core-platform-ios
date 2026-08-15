import UIKit

/// What a sub-filter pill actually stands for, resolved from its option.
///
/// `MapSubFilter` only says how to query — a profile id or a category token.
/// The long-press menu needs to know what the viewer is holding: a PERSON has
/// an account behind it (a profile to open, a thread to start, a mute flag),
/// a PLACE is a client-side vocabulary token with none of that.
///
/// The generic case is not padding. A `.profile` refinement whose `MapFavorite`
/// never hydrated is a real state — the pill renders from the sub-filter alone
/// — and offering "View Profile" for a person the bar can't name would open an
/// empty screen. Anything the bar can't identify falls back to the two verbs
/// that need no identity.
enum MapSubFilterEntity: Equatable {
    case person(MapFavorite)
    /// The category token (`"cafes"`, `"parks"`), not a display name.
    case place(String)
    case generic

    init(option: MapSubFilterOption) {
        if let favorite = option.favorite {
            self = .person(favorite)
        } else if case .placeCategory(let token) = option.subFilter {
            self = .place(token)
        } else {
            self = .generic
        }
    }
}

extension MapSubFilterEntity {
    /// The name the menu is headed by.
    ///
    /// Taken from the PROFILE for a person — display name, falling back to the
    /// `@handle` — rather than from the pill's presentation. The pill has no
    /// text at all since it became a bare avatar circle, and this menu is the
    /// only place the viewer is told whose face they are holding; sourcing it
    /// from anything the pill draws would make that dependent on how the pill
    /// happens to be styled today.
    ///
    /// `fallback` is the pill's own accessibility label, which is the right
    /// answer for the cases with no profile behind them: a place category is
    /// named by its label ("Cafés"), and a pill the bar cannot identify has
    /// nothing better to offer.
    func menuTitle(fallback: String) -> String {
        guard case .person(let favorite) = self else { return fallback }
        if !favorite.title.isEmpty { return favorite.title }
        if let handle = favorite.handle, !handle.isEmpty { return "@\(handle)" }
        return fallback
    }
}

/// The person at the top of a pill's menu, as a tappable entry rather than a
/// caption.
///
/// UIKit gives a menu title no weight and no touch: it is small grey text,
/// and there is no attributed-title API to make it otherwise (checked against
/// the SDK — `UIMenuElement` exposes `subtitle` and `image`, nothing about
/// font). So the header is a real ACTION in its own section, which is how it
/// gets both: a two-line row with a face reads as the subject of the menu
/// rather than one more verb in the ladder, and it can open the profile.
///
/// Only a person has one. A place category has no profile to open, so it
/// keeps the plain caption — see `MapSubFilterEntity.menuTitle(fallback:)`.
struct MapSubFilterMenuHeader: Equatable {
    let title: String
    /// The `@handle`, and nil when the title IS the handle — a row reading
    /// "@kenji" over "@kenji" says nothing twice.
    let subtitle: String?
    /// What tapping the header does. Named so the routing is assertable
    /// without reaching into a `UIAction`'s handler.
    let action: MapSubFilterMenuAction = .viewProfile
}

extension MapSubFilterEntity {
    func menuHeader(fallback: String) -> MapSubFilterMenuHeader? {
        guard case .person(let favorite) = self else { return nil }
        let title = menuTitle(fallback: fallback)
        let handle = favorite.handle.flatMap { $0.isEmpty ? nil : "@\($0)" }
        return MapSubFilterMenuHeader(
            title: title,
            subtitle: handle == title ? nil : handle
        )
    }
}

/// One entry in a pill's long-press menu.
///
/// A descriptor rather than a built `UIMenu`: `UIAction` closures cannot be
/// invoked from a test, so a menu assembled inline would only ever be
/// assertable on its titles. Keeping the ladder as values means the ROUTING —
/// which action reaches which callback — is testable directly, and the view is
/// left with nothing but the translation into UIKit.
enum MapSubFilterMenuAction: String, CaseIterable {
    case viewProfile
    case sendMessage
    case toggleMute
    case viewDetails
    case share
    case unpin

    /// Removing a refinement from the bar is the only one that destroys
    /// anything the viewer arranged; the rest navigate or toggle.
    var isDestructive: Bool { self == .unpin }

    /// Mute is the one entry whose wording depends on live state, so its title
    /// and glyph take the current flag. Everything else ignores it.
    func title(isMuted: Bool) -> String {
        switch self {
        case .viewProfile: "View Profile"
        case .sendMessage: "Message"
        case .toggleMute: isMuted ? "Unmute" : "Mute"
        case .viewDetails: "View Details"
        case .share: "Share"
        case .unpin: "Remove"
        }
    }

    func symbolName(isMuted: Bool) -> String {
        switch self {
        case .viewProfile: "person.crop.circle"
        case .sendMessage: "message"
        case .toggleMute: isMuted ? "bell" : "bell.slash"
        case .viewDetails: "info.circle"
        case .share: "square.and.arrow.up"
        case .unpin: "pin.slash"
        }
    }

    /// The menu for an entity, in thumb order — see the ordering note in
    /// `MapSubFilterBarView.menu(for:)`. The toggles, then the removal, with
    /// Share last.
    ///
    /// A person's ladder has no View Profile: their name is the header, and
    /// the header opens the profile (`MapSubFilterMenuHeader`). Keeping both
    /// would offer the same destination twice in one menu. A GENERIC pill —
    /// a profile refinement the bar could not name — has no header to tap, so
    /// nothing is lost there either: it never offered View Profile, because
    /// it has no identity to open.
    ///
    /// ⚠️ Remove is no longer the farthest entry from the thumb; Share is.
    /// The ladder used to end on the destructive verb deliberately, so a
    /// mis-aimed press near the finger could not delete a pill. It reads
    /// better grouped with the other verbs that act on the ROW — and the
    /// removal is undone in one tap from the same sheet.
    static func actions(for entity: MapSubFilterEntity) -> [MapSubFilterMenuAction] {
        switch entity {
        case .person: [.sendMessage, .toggleMute, .unpin, .share]
        case .place: [.viewDetails, .unpin, .share]
        case .generic: [.unpin, .share]
        }
    }
}
