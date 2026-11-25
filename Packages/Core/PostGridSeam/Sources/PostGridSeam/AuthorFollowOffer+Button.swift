import Foundation

/// What every Follow button draws for an offer, and when it confirms: one
/// rule for a list row's button (`AuthorFollowButton`, #2419) and the
/// full-screen page's bar item (#2409), so the two never word or time it
/// differently.
extension AuthorFollowOffer {
    /// How long "✓ Following" stays before the button folds away.
    public static let confirmationDuration: TimeInterval = 1

    /// The words on the button; nil when the offer draws none.
    public var buttonTitle: String? {
        switch self {
        case .follow: "Follow"
        case .followBack: "Follow back"
        case .requested: "Requested"
        case .following, .none: nil
        }
    }

    /// Whether a change from `old` to this offer, seen on screen, says
    /// "✓ Following" before the button folds: a follow made from the
    /// button's own invitation. A private account's Requested replaces it.
    public func confirmsFollow(from old: AuthorFollowOffer) -> Bool {
        self == .following && (old == .follow || old == .followBack)
    }
}
