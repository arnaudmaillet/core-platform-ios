import Foundation
import ProfileSettings

/// The relationship's one control on someone else's profile, beside Message:
/// Follow, Requested, or — once followed — the mute bell.
///
/// ⚠️ ONE RULE FOR THE PAGE AND THE CARD (#2302, the owner 2026-11-11). The
/// card's toolbar read `[——Follow——][Message][QR]` → `[bell][——Message——][QR]`
/// since #1562; the page's header kept Following and stood the bell in the
/// top bar. The page follows the card now, and both read the control from
/// here — the header's row (`ProfileHeaderView.trayItems`) and the card's
/// toolbar (`ProfileCardViewController.toolbarItems`) — so the two can no
/// longer show one relationship two ways.
///
/// | Relation                          | Control   |
/// |-----------------------------------|-----------|
/// | not followed (a guest reads so)   | Follow    |
/// | requested                         | Requested |
/// | followed, a member who can mute   | the bell  |
/// | followed, no bell                 | nothing   |
/// | not followable, the viewer's own, not read yet | nothing |
///
/// Once followed, Following is gone: the avatar's mark says it (the check,
/// or friends' two people, #2049 / #2050), and Unfollow leads the "…" menu
/// (`ProfileMenuBuilder.moreMenuElements`).
///
/// The bell is a MUTE bell (#689), an opt-out: a menu of one toggle per scope
/// (`ProfileMenuBuilder.muteMenuElements`), `bell`, or `bell.slash` once
/// anything is muted.
nonisolated enum ProfileRelationControl: Equatable, Sendable {
    case follow
    case requested
    case bell

    /// The control for a relationship. `showsBell`: the bell's own rule
    /// (`showsMuteBell`). Pure, for tests.
    static func control(for followButton: ProfileViewModel.FollowButton, showsBell: Bool) -> ProfileRelationControl? {
        switch followButton {
        case .follow: .follow
        case .requested: .requested
        case .following: showsBell ? .bell : nil
        case .unavailable, .hidden, .edit: nil
        }
    }

    /// Whether the bell stands: a profile the viewer FOLLOWS (#1398 — nothing
    /// of theirs to mute before), in a composition that can mute, for a
    /// member (a guest has no account to mute from). Pure, for tests.
    static func showsMuteBell(followButton: ProfileViewModel.FollowButton, canMute: Bool, isGuest: Bool) -> Bool {
        followButton == .following && canMute && !isGuest
    }

    /// The bell's glyph for the muted scopes.
    static func bellSymbol(for scopes: MuteScopes) -> String {
        scopes.isEmpty ? "bell" : "bell.slash"
    }

    /// What VoiceOver hears of the bell's state.
    static func bellAccessibilityValue(for scopes: MuteScopes) -> String {
        scopes.isEmpty ? "Nothing muted" : "Muted: " + scopes.summary
    }
}
