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
    /// `MapSubFilterBarView.menu(for:)`. Navigation first, then the toggles,
    /// then the removal, with Share last.
    ///
    /// ⚠️ Remove is no longer the farthest entry from the thumb; Share is.
    /// The ladder used to end on the destructive verb deliberately, so a
    /// mis-aimed press near the finger could not delete a pill. It reads
    /// better grouped with the other verbs that act on the ROW — and it is
    /// still four entries away, with an undo one tap away in the sheet.
    static func actions(for entity: MapSubFilterEntity) -> [MapSubFilterMenuAction] {
        switch entity {
        case .person: [.viewProfile, .sendMessage, .toggleMute, .unpin, .share]
        case .place: [.viewDetails, .unpin, .share]
        case .generic: [.unpin, .share]
        }
    }
}
