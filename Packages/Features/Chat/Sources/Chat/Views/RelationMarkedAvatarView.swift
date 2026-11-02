import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A conversation row's face wearing the relation mark (#2049, the owner
/// 2026-11-02): the one mark the author pill and the profile wear, scaled to
/// the row's 48 pt disc — the badge on the rim at 45°, bottom-trailing, cut
/// into the face (`RelationMark.cutout`), and the ring behind the face while
/// following (grey) or friends (the accent).
///
/// All five states, the "+" and the clock included; only the "+" takes
/// touches (`onFollowTapped`). The face itself draws at once; the mark
/// arrives when the relation is known, through the badge's replace and the
/// ring's fade, and moves nothing: the ring and the badge are drawn outside
/// the disc's 48 pt, which is all the row lays out.
final class RelationMarkedAvatarView: UIView {
    static let metrics = RelationMarkMetrics(faceDiameter: MonogramAvatarView.rowDiameter)

    /// How far the ring's band runs under the face's edge, hiding its inner
    /// edge (the pill's `ringTuck`).
    private static let ringTuck: CGFloat = 1

    /// The app's avatar (#943): the picture over the initials.
    private let avatar = AvatarView(size: .avatar)
    /// The ring's disc, behind the face, in its own view so its path is laid
    /// out round the face's bounds.
    private let ring = UIView()
    private let ringShape = CAShapeLayer()
    private let faceCutout = CAShapeLayer()
    let badge = RelationBadgeView(metrics: RelationMarkedAvatarView.metrics)

    /// The mark on show.
    private(set) var mark: PersonPill.Badge = .none

    /// Told when the "+" is tapped — never for a state mark.
    var onFollowTapped: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let outset = Self.metrics.ringWidth
        ring.isUserInteractionEnabled = false
        ring.layer.addSublayer(ringShape)
        ringShape.fillColor = UIColor.clear.cgColor
        ring.constrain(in: self) { parent in
            ring.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: -outset)
            ring.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: outset)
            ring.topAnchor.constraint(equalTo: parent.topAnchor, constant: -outset)
            ring.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: outset)
        }
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
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, AccentThemeTrait.self]
        ) { (view: RelationMarkedAvatarView, _: UITraitCollection) in
            view.drawRing()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCutout()
        drawRing()
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

    /// Wears `mark`: through the badge's replace and the ring's fade when
    /// `animated` and on screen, at once otherwise.
    func setMark(_ mark: PersonPill.Badge, animated: Bool) {
        guard mark != self.mark else { return }
        self.mark = mark
        let onScreen = animated && window != nil
        badge.show(mark, animated: onScreen)
        let from = ringShape.presentation()?.fillColor ?? ringShape.fillColor
        applyCutout()
        drawRing()
        if onScreen {
            let fade = CABasicAnimation(keyPath: "fillColor")
            fade.fromValue = from
            fade.toValue = ringShape.fillColor
            fade.duration = 0.25
            ringShape.add(fade, forKey: "fillColor")
        }
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

    /// The ring's band, less the badge's cutout, in its resolved ink.
    private func drawRing() {
        let bounds = ring.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringShape.frame = bounds
        if RelationMark.hasRing(mark), bounds.width > 0 {
            let inset = Self.metrics.ringWidth + Self.ringTuck
            var band = CGPath(ellipseIn: bounds, transform: nil)
                .subtracting(CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil))
            if let cutout = cutoutCircle(in: ring) { band = band.subtracting(cutout.cgPath) }
            ringShape.path = band
        } else {
            ringShape.path = nil
        }
        ringShape.fillColor = RelationMark.ringInk(for: mark).resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    #if DEBUG
    /// The ring's ink as drawn — clear for none. Tests.
    var drawnRingColor: UIColor { UIColor(cgColor: ringShape.fillColor ?? UIColor.clear.cgColor) }
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
