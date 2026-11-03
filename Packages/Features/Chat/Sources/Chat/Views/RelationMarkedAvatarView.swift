import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A conversation row's face wearing the relation mark (#2049, the owner
/// 2026-11-02): the one mark the author pill and the profile wear, scaled to
/// the row's 48 pt disc — the badge on the rim at 45°, bottom-trailing, cut
/// into the face (`RelationMark.cutout`). No ring round the face (#2082, the
/// owner 2026-11-03): the badge alone.
///
/// All five states, the "+" and the clock included; only the "+" takes
/// touches (`onFollowTapped`). The face itself draws at once; the mark
/// arrives when the relation is known, through the badge's replace, and
/// moves nothing: the badge is drawn past the disc's 48 pt, which is all
/// the row lays out.
final class RelationMarkedAvatarView: UIView {
    static let metrics = RelationMarkMetrics(faceDiameter: MonogramAvatarView.rowDiameter)

    /// The app's avatar (#943): the picture over the initials.
    private let avatar = AvatarView(size: .avatar)
    private let faceCutout = CAShapeLayer()
    let badge = RelationBadgeView(metrics: RelationMarkedAvatarView.metrics)

    /// The mark on show.
    private(set) var mark: PersonPill.Badge = .none

    /// Told when the "+" is tapped — never for a state mark.
    var onFollowTapped: (() -> Void)?

    init() {
        super.init(frame: .zero)
        addSubview(avatar)
        avatar.pin(to: self)
        let offset = Self.metrics.cornerOffset
        // Edge to edge, never centre to trailing: only an edge offset mirrors
        // under right-to-left.
        badge.constrain(in: self) { parent in
            badge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: offset)
            badge.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: offset)
        }
        badge.addAction(UIAction { [weak self] _ in
            guard let self, mark == .follow else { return }
            onFollowTapped?()
        }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCutout()
    }

    // MARK: - The face

    func setMonogram(_ monogram: String) {
        avatar.setMonogram(monogram)
    }

    /// Shows the picture at `url` over the initials, or clears back to them.
    func setPicture(_ url: URL?, pipeline: ImagePipeline?) {
        avatar.setPicture(url, pipeline: pipeline)
    }

    /// A picture still being looked up: the skeleton until `setPicture`.
    func awaitPicture() {
        avatar.awaitPicture()
    }

    /// The picture on show, nil while the initials are — for tests.
    var shownPicture: UIImage? { avatar.shownPicture }

    // MARK: - The mark

    /// Wears `mark`: through the badge's replace when `animated` and on
    /// screen, at once otherwise.
    func setMark(_ mark: PersonPill.Badge, animated: Bool) {
        guard mark != self.mark else { return }
        self.mark = mark
        badge.show(mark, animated: animated && window != nil)
        applyCutout()
    }

    /// The badge, when it takes a touch now: the "+" alone. The row's hit
    /// test asks it first, so its grown touch area works beyond the disc's
    /// bounds and the stack around it.
    var tappableBadge: UIView? {
        mark == .follow && badge.isUserInteractionEnabled && !badge.isHidden ? badge : nil
    }

    /// The badge's cutout as a disc in `view`'s space, nil with no mark.
    private func cutoutCircle(in view: UIView) -> UIBezierPath? {
        guard mark != .none, bounds.width > 0 else { return nil }
        let centre = Self.metrics.badgeCentre(
            inFaceOfSide: bounds.width, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        return RelationMark.cutout(centre: convert(centre, to: view), metrics: Self.metrics)
    }

    /// The face loses the badge's disc and its gap (#1912), cut from the
    /// face's own side, never the badge's frame, which may not be laid out
    /// yet.
    private func applyCutout() {
        guard let circle = cutoutCircle(in: avatar) else {
            avatar.layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceCutout.fillRule = .evenOdd
        faceCutout.frame = avatar.bounds
        faceCutout.path = RelationMark.faceMaskPath(cutout: circle)
        CATransaction.commit()
        avatar.layer.mask = faceCutout
    }

    #if DEBUG
    /// Whether anything is drawn round the face: no, ever (#2082). Tests.
    var drawsRing: Bool { subviews.contains { $0 !== avatar && $0 !== badge } || layer.borderWidth > 0 }
    /// Whether the face has the badge's cutout taken out. Tests.
    var faceIsCutOut: Bool { avatar.layer.mask === faceCutout }
    #endif
}

extension PersonPill.Badge {
    /// The mark for a relation (#2049): the author pill's mapping — "+" for
    /// someone not followed (a follower included: following back makes a
    /// friend), the clock for a request, the check, friends — and nothing for
    /// the viewer, someone blocked, or a relation not known yet.
    init(relation: FollowRelation?) {
        self = switch relation {
        case .notFollowing, .followedBy: .follow
        case .following: .following
        case .mutual: .friends
        case .requested: .pending
        case .viewer, .blocked, nil: .none
        }
    }
}
