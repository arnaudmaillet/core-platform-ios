import CoreModels
import Foundation
import MediaCore
import UIKit

/// The app's person pill as a bar item (#1451): the post page's identity —
/// the face, the name and @handle, and the relation as a badge on the face
/// whose "+" follows. Feed builds it; another feature (the profile's bar)
/// wears it through its composition root, so the profile shows the SAME
/// view, never a second configuration of `PersonPill`.
@MainActor
public protocol PersonBarItem: AnyObject {
    /// The view to host as the bar item's custom view.
    var view: UIView { get }
    /// A tap on the pill outside the badge, with the person shown.
    var onPersonTapped: ((ProfileID) -> Void)? { get set }
    /// A tap on the "+", with the person shown. Never for a state mark.
    var onFollowTapped: ((ProfileID) -> Void)? { get set }
    /// What the badge says now.
    var followBadge: PersonPill.Badge { get }
    /// Shows `name` and `meta` (the @handle), and the face at `avatarURL`.
    /// The same person again changes in place.
    func setPerson(id: ProfileID?, name: String, meta: String, avatarURL: URL?, pipeline: ImagePipeline)
    /// The relation; a change on screen is an SF Symbols replace.
    func setFollowBadge(_ badge: PersonPill.Badge, animated: Bool)
    /// The widest the pill is drawn: the room its bar leaves it.
    func setWidthBudget(_ budget: CGFloat?)
    /// Shadows for a bar over media; none over a plain ground.
    func setOverMedia(_ overMedia: Bool)
}
