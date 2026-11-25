import CoreModels

/// What a list row's author band offers beside its "…" (#2419): the Follow
/// that took over from the face's "+", once the relation badge became
/// information only (Following and Friends, never a control).
///
/// ```
///   (◯) Name                 (Follow) •••
///       @handle · 2h
/// ```
///
/// A value, so a row and the reveal's stand-in that copies it (the band drawn
/// twice, `PostAuthorBandView`) draw the same button.
public enum AuthorFollowOffer: Equatable, Sendable {
    /// No button: the viewer's own post, an author the viewer blocks, a
    /// relation not known yet, a host with no follow, a bare band.
    case none
    /// "Follow": an author the viewer doesn't follow.
    case follow
    /// "Follow back": an author who follows the viewer, who doesn't follow
    /// back. Following back makes a friend.
    case followBack
    /// "Requested", quiet: the viewer asked a private account. It stays, and
    /// a tap offers to cancel the request. The badge no longer says it, so
    /// this is where it reads.
    case requested
    /// The viewer follows the author (a friend included): no button. Reached
    /// on screen from Follow or Follow back, the button says "✓ Following"
    /// for a moment, then folds away.
    case following

    /// The offer for where the viewer stands with the author. Nil (not known
    /// yet) offers nothing: the button fades in once the answer lands.
    public init(relation: FollowRelation?) {
        self = switch relation {
        case .notFollowing: .follow
        case .followedBy: .followBack
        case .requested: .requested
        case .following, .mutual: .following
        case .viewer, .blocked, nil: .none
        }
    }

    /// Whether a button stands in the band at rest.
    public var showsButton: Bool {
        switch self {
        case .follow, .followBack, .requested: true
        case .none, .following: false
        }
    }
}
