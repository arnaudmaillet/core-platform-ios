import DesignSystem
import UIKit

/// THE FACE WEARING THE RELATION MARK (#2049, the owner 2026-11-02: one
/// mark, the same on every avatar that carries one): the app's avatar with
/// the badge on its rim at 45°, bottom-trailing, cut into the face
/// (`RelationMark.cutout`). No ring round the face (#2082, the owner
/// 2026-11-03): the badge alone.
///
/// Shared since #2300: the inbox rows and the message requests (Chat, at
/// 48 pt), a text page's caption row (Feed, at the row's Dynamic-Type
/// side) and a list card's author band (PostGrid, at 40 pt) are this view.
/// A new face with a relation adopts it; nobody assembles the mark by hand.
///
/// At ANY diameter: the badge's side comes from `RelationMarkMetrics`, and
/// `setDiameter` restates the face, the badge and its cutout together (a
/// face that follows Dynamic Type).
///
/// All five states, the "+" and the clock included; only the "+" takes
/// touches (`onFollowTapped`). The face itself draws at once; until the
/// relation is known the badge is a skeleton bone, its cutout already taken
/// out of the face (#2098), and the mark lands in its place through the
/// badge's replace. Nothing moves: the badge is drawn past the disc, which is
/// all its host lays out.
public final class RelationMarkedAvatarView: UIView {
    /// The app's avatar (#943): the picture over the initials. Its host
    /// reaches it for what is an avatar's own — the frame, the decode size,
    /// an animated avatar's rounds.
    public let avatar: AvatarView
    private let faceCutout = FaceCutout()
    /// The badge, sized by the face's metrics.
    public let badge: RelationBadgeView
    /// The sizes the mark is drawn at, for the face's diameter now.
    public private(set) var metrics: RelationMarkMetrics
    private var badgeTrailing: NSLayoutConstraint?
    private var badgeBottom: NSLayoutConstraint?

    /// The mark on show.
    public private(set) var mark: PersonPill.Badge = .none

    /// Told when the "+" is tapped — never for a state mark.
    public var onFollowTapped: (() -> Void)?

    /// Whether the face itself takes no touch, only its "+" does: a host
    /// whose own control or container holds the face's taps (a list card's
    /// author band) keeps being the hit view everywhere else.
    public var takesOnlyBadgeTouches = false

    /// - Parameters:
    ///   - diameter: the face's side; `setDiameter` changes it later. The
    ///     inbox row's 48 pt by default.
    ///   - size: the bucket the picture is decoded at.
    public init(diameter: CGFloat = MonogramAvatarView.rowDiameter, size: ImageBucket = .avatar) {
        metrics = RelationMarkMetrics(faceDiameter: diameter)
        avatar = AvatarView(diameter: diameter, size: size)
        badge = RelationBadgeView(metrics: metrics)
        super.init(frame: .zero)
        addSubview(avatar)
        avatar.pin(to: self)
        let offset = metrics.cornerOffset
        // Edge to edge, never centre to trailing: only an edge offset mirrors
        // under right-to-left. Kept, so a new diameter moves the badge.
        addSubview(badge)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let trailing = badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: offset)
        let bottom = badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: offset)
        NSLayoutConstraint.activate([trailing, bottom])
        badgeTrailing = trailing
        badgeBottom = bottom
        badge.addAction(UIAction { [weak self] _ in
            guard let self, mark == .follow else { return }
            onFollowTapped?()
        }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyCutout()
    }

    /// The "+" answers past the face's bounds — its grown touch area, and the
    /// part of it the rim leaves outside the disc.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let badge = tappableBadge, badge.point(inside: convert(point, to: badge), with: event) { return true }
        return super.point(inside: point, with: event)
    }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        if let badge = tappableBadge, badge.point(inside: convert(point, to: badge), with: event) { return badge }
        let hit = super.hitTest(point, with: event)
        return takesOnlyBadgeTouches && hit != nil ? nil : hit
    }

    // MARK: - The face

    /// Resizes the face — its initials, the badge's side and its cutout
    /// with it, from `RelationMarkMetrics`.
    public func setDiameter(_ diameter: CGFloat) {
        avatar.setDiameter(diameter)
        // The disc's size constraints changed inside the face: ask the host
        // for a pass, so the face itself takes the new size.
        avatar.setNeedsLayout()
        setNeedsLayout()
        superview?.setNeedsLayout()
        let metrics = RelationMarkMetrics(faceDiameter: diameter)
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        badge.setMetrics(metrics)
        badgeTrailing?.constant = metrics.cornerOffset
        badgeBottom?.constant = metrics.cornerOffset
        setNeedsLayout()
    }

    public func setMonogram(_ monogram: String) {
        avatar.setMonogram(monogram)
    }

    /// Shows the picture at `url` over the initials, or clears back to them.
    public func setPicture(_ url: URL?, pipeline: ImagePipeline?) {
        avatar.setPicture(url, pipeline: pipeline)
    }

    /// A picture still being looked up: the skeleton until `setPicture`.
    public func awaitPicture() {
        avatar.awaitPicture()
    }

    /// The picture on show, nil while the initials are — for tests.
    public var shownPicture: UIImage? { avatar.shownPicture }

    // MARK: - The mark

    /// Wears `mark`: through the badge's replace when `animated` and on
    /// screen, at once otherwise.
    public func setMark(_ mark: PersonPill.Badge, animated: Bool) {
        guard mark != self.mark else { return }
        self.mark = mark
        badge.show(mark, animated: animated && window != nil)
        if !mark.cutsTheFace { faceCutout.close(avatar.layer, animated: animated && window != nil) }
        applyCutout()
    }

    /// The badge, when it takes a touch now: the "+" alone. A host whose
    /// bounds end before the badge's asks it first, so its grown touch area
    /// works beyond the disc's bounds and the stack around it.
    public var tappableBadge: UIView? {
        mark == .follow && badge.isUserInteractionEnabled && !badge.isHidden ? badge : nil
    }

    /// The face loses the badge's disc and its gap (#1912) — the skeleton's
    /// too (#2098) — cut from the face's own side, never the badge's frame,
    /// which may not be laid out yet.
    private func applyCutout() {
        guard mark.cutsTheFace, bounds.width > 0 else {
            if !faceCutout.isClosing { faceCutout.close(avatar.layer, animated: false) }
            return
        }
        let centre = metrics.badgeCentre(
            inFaceOfSide: bounds.width, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        faceCutout.cut(avatar.layer, centre: convert(centre, to: avatar), metrics: metrics)
    }

    #if DEBUG
    /// Whether anything is drawn round the face: no, ever (#2082). Tests.
    public var drawsRing: Bool { subviews.contains { $0 !== avatar && $0 !== badge } || layer.borderWidth > 0 }
    /// Whether the face has the badge's cutout taken out. Tests.
    public var faceIsCutOut: Bool { faceCutout.isCut(avatar.layer) }
    #endif
}
