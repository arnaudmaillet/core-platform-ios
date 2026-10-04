import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One friend in For You's stories row: their face in a disc, a ring around it
/// while they have posts the viewer has not seen, and their name under it.
///
/// **The app's avatar contract** (`avatar-rendering-contract`): the initials
/// are the RENDERED state and the picture is an enhancement drawn over them,
/// never swapped for them — no empty disc at any point, and a recycled cell
/// guards its late picture by the friend's id, not only by cancelling.
///
/// **The disc is also a flight's source.** A tap flies the friend's posts out
/// of it (`ForYouViewController.openStory`), so the cell answers the three
/// questions a flight asks of a source: where the disc is (`discFrame`), what
/// it looks like right now (`renderedFace`), and "hide while your twin is in
/// the air" (`isDiscConcealed`). The RING is not part of the face: it is the
/// row's statement about unseen posts, and a flight carrying it into the page
/// would put a badge on a post.
final class ForYouStoryCell: UICollectionViewCell {
    static let reuseID = "ForYouStoryCell"

    /// ⚠️ NO FIXED FACE SIZE. The row sizes its cells from the screen's width
    /// (`ForYouRailsView.Metrics.storiesPerWidth`) so a face is always cropped
    /// at the right edge; the cell takes the disc as its width and derives the
    /// face from it (`faceDiameter`).
    enum Metrics {
        /// The unseen ring, and the air between it and the face — the ring
        /// reads as a frame around the picture, not as its edge.
        static let ringWidth: CGFloat = 2.5
        static let ringGap: CGFloat = 2.5
        static let nameGap: CGFloat = 4
        static let nameHeight: CGFloat = 16

        /// The face inside a disc `discSide` across: the disc less the ring
        /// and its air on both sides.
        static func faceDiameter(discSide: CGFloat) -> CGFloat {
            max(0, discSide - 2 * (ringWidth + ringGap))
        }

        /// The cell for a disc `discSide` across: exactly the disc's width —
        /// so a snap lining the cell up on a margin lines up the ring — and
        /// the name line under it, truncated to that width.
        static func size(discSide: CGFloat) -> CGSize {
            CGSize(width: discSide, height: discSide + nameGap + nameHeight)
        }
    }

    /// The warm gradient the ring wears while there is something unseen —
    /// the stories convention the viewer already reads, so it needs no legend.
    private static let ringColors: [CGColor] = [
        UIColor.systemYellow.cgColor, UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor
    ]

    private let disc = UIView()
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    /// Re-sized to the cell's disc in `layoutSubviews` — its own width and
    /// height constraints must agree with the frame given it there.
    private let monogram = MonogramAvatarView(diameter: Metrics.faceDiameter(discSide: 70))
    private let picture = AvatarImageView()
    private let nameLabel = UILabel()
    private var pictureTask: Task<Void, Never>?
    /// Whose face this cell is showing — the guard a late picture checks.
    private var shownAuthor: ProfileID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(disc)
        ring.colors = Self.ringColors
        ring.startPoint = CGPoint(x: 0, y: 1)
        ring.endPoint = CGPoint(x: 1, y: 0)
        ringMask.fillColor = UIColor.clear.cgColor
        ringMask.strokeColor = UIColor.black.cgColor
        ringMask.lineWidth = Metrics.ringWidth
        ring.mask = ringMask
        disc.layer.addSublayer(ring)

        monogram.translatesAutoresizingMaskIntoConstraints = true
        disc.addSubview(monogram)
        picture.isHidden = true
        monogram.addSubview(picture)

        nameLabel.font = .appFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = false
        nameLabel.textAlignment = .center
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)

        isAccessibilityElement = true
        accessibilityTraits = .button
        // ⚠️ NO PRESS FEEDBACK (2026-09-29). The give-and-dim fired on the
        // touch-down that starts every scroll of the row, and the product call
        // is no feedback at all under a finger: a tap opens, a long press
        // lifts the native preview (`ForYouRailsView`'s context menu).
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        disc.frame = CGRect(x: 0, y: 0, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = disc.bounds
        ringMask.frame = disc.bounds
        ringMask.path = UIBezierPath(
            ovalIn: disc.bounds.insetBy(dx: Metrics.ringWidth / 2, dy: Metrics.ringWidth / 2)
        ).cgPath
        CATransaction.commit()
        let inset = Metrics.ringWidth + Metrics.ringGap
        monogram.setDiameter(Metrics.faceDiameter(discSide: side))
        monogram.frame = disc.bounds.insetBy(dx: inset, dy: inset)
        picture.frame = monogram.bounds
        nameLabel.frame = CGRect(
            x: 0, y: disc.frame.maxY + Metrics.nameGap,
            width: bounds.width, height: Metrics.nameHeight
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pictureTask?.cancel()
        pictureTask = nil
        shownAuthor = nil
        picture.image = nil
        picture.isHidden = true
        monogram.isCovered = false
        isDiscConcealed = false
    }

    func configure(with story: ForYouViewModel.FriendStory, imagePipeline: ImagePipeline) {
        shownAuthor = story.authorID
        nameLabel.text = story.name.split(separator: " ").first.map(String.init) ?? story.name
        nameLabel.font = .scaledFont(forTextStyle: .caption1, weight: story.hasUnseen ? .semibold : .regular)
        nameLabel.textColor = story.hasUnseen ? .label : .secondaryLabel
        ring.isHidden = !story.hasUnseen
        monogram.setMonogram(MonogramAvatarView.monogram(name: story.name, handle: story.handle))
        accessibilityLabel = story.name
        accessibilityValue = story.hasUnseen ? "New posts" : nil

        picture.image = nil
        picture.isHidden = true
        monogram.isCovered = false
        guard let url = story.avatarURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            showPicture(cached)
            return
        }
        let author = story.authorID
        pictureTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled,
                  let self, shownAuthor == author else { return }
            showPicture(image)
        }
    }

    private func showPicture(_ image: UIImage) {
        picture.image = image
        picture.isHidden = false
        // The initials stay underneath, covered rather than removed — the
        // contract's "drawn over, never swapped".
        monogram.isCovered = true
    }

    // MARK: - As a flight's source

    /// The face alone — no ring, no name — which a long press lifts into the
    /// context menu's preview.
    var faceView: UIView { monogram }

    /// The face's rect — the disc without its ring — in `space`, AT REST:
    /// with no transform between the face and `row` counted.
    ///
    /// ⚠️ NOT `monogram.convert(monogram.bounds, to:)`. A press (or anything
    /// else) that scales the disc makes UIKit's conversion report the SCALED
    /// rect, and a flight measuring that lands a few points inside and off
    /// centre of the face it is returning to — filmed on a close. Where a
    /// flight goes is where the face RESTS; see `ForYouRailsView.restingFrame`.
    func discFrame(in space: UICoordinateSpace, restingBelow row: UIView) -> CGRect {
        ForYouRailsView.restingFrame(of: monogram, below: row, in: space)
    }

    /// The face exactly as drawn: the picture when it has landed, the initials
    /// on their plate when it has not — so a flight starts as this disc's
    /// twin whichever state it is in.
    func renderedFace() -> UIImage {
        layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: monogram.bounds)
        return renderer.image { context in
            // Clipped by hand: `render(in:)` does not honour every mask a
            // live layer wears, and a square corner on a disc's twin is the
            // one frame a flight would show it.
            context.cgContext.addEllipse(in: monogram.bounds)
            context.cgContext.clip()
            monogram.layer.render(in: context.cgContext)
        }
    }

    /// Hides the face (and its ring) while a flight carries its twin.
    var isDiscConcealed = false {
        didSet { disc.isHidden = isDiscConcealed }
    }
}
