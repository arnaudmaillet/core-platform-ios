import DesignSystem
import MediaCore
import UIKit

/// A photoless group's face (#2214): up to three of its members' faces,
/// stacked inside the row's 48 pt disc — one alone fills it, two sit on a
/// diagonal, three in a triangle, as Messages draws a group.
///
/// Each face is the app's avatar (`AvatarView`), so it loads, skeletons and
/// dissolves like every other face; a thin ring of the row's background
/// keeps the overlaps readable. It is laid out by hand: the positions are
/// fractions of the disc, which no stack expresses.
final class GroupFacesView: UIView {
    private var faces: [AvatarView] = []
    private var urls: [URL] = []

    /// The side of a face when two or three share the disc.
    static let sharedFaceRatio: CGFloat = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // The ring is the row's background, which changes with the theme.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GroupFacesView, _) in
            for face in view.faces { face.layer.borderColor = UIColor.systemBackground.cgColor }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
    }

    /// Shows `urls` (the first three), or nothing for none. The same faces
    /// again keep what is drawn.
    func setFaces(_ urls: [URL], pipeline: ImagePipeline?) {
        let shown = Array(urls.prefix(ConversationIdentity.stackedFaces))
        guard shown != self.urls || faces.count != shown.count else { return }
        self.urls = shown
        faces.forEach { $0.removeFromSuperview() }
        faces = shown.map { url in
            let face = AvatarView(diameter: Self.diameter(forCount: shown.count), size: .avatar)
            face.setMonogram("")
            face.setPicture(url, pipeline: pipeline)
            face.layer.borderColor = UIColor.systemBackground.cgColor
            face.layer.borderWidth = shown.count > 1 ? 1.5 : 0
            face.clipsToBounds = true
            addSubview(face)
            return face
        }
        setNeedsLayout()
    }

    /// How many faces are drawn. Tests.
    var faceCount: Int { faces.count }

    static func diameter(forCount count: Int) -> CGFloat {
        let side = MonogramAvatarView.rowDiameter
        return count > 1 ? (side * sharedFaceRatio).rounded() : side
    }

    /// Where each face's top-left sits, as a fraction of the free space
    /// (disc side less face side) — leading to trailing, top to bottom.
    static func origins(forCount count: Int) -> [CGPoint] {
        switch count {
        case 0: []
        case 1: [.zero]
        case 2: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        default: [CGPoint(x: 0, y: 0.1), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let diameter = Self.diameter(forCount: faces.count)
        let free = max(0, side - diameter)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (face, origin) in zip(faces, Self.origins(forCount: faces.count)) {
            let x = rightToLeft ? (1 - origin.x) : origin.x
            face.frame = CGRect(x: x * free, y: origin.y * free, width: diameter, height: diameter)
            face.layer.cornerRadius = diameter / 2
        }
    }
}
