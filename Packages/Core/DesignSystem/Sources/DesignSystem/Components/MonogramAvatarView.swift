import UIKit

/// The app's identity disc: initials on a translucent fill, clipped to a
/// circle at any diameter.
///
/// Lives here rather than in a feature because every person row in the app is
/// the same disc at the same size — the chat inbox, the message requests list,
/// the compose picker, the follow suggestions, and the profile's follower /
/// following lists. Two features drawing their own would drift apart, and the
/// lists read as different products the moment they do.
///
/// Initials, not an image, is the *default* state on purpose: `chat.v1` members
/// and `social_graph.v1` edges carry ids only, so a row can always render an
/// identity even before (or without) an avatar fetch. Callers that do have a
/// URL overlay an `AvatarImageView` pinned to this view, leaving the monogram
/// behind it as the permanent fallback.
public final class MonogramAvatarView: UIView {
    /// The list-row diameter, shared by every surface that shows a person.
    public static let rowDiameter: CGFloat = 48

    private let label = UILabel()
    /// The plate: the avatar's `shape` (an oval by default) filled with a RESOLVED colour — see
    /// `drawPlate` for why it is not the view's background.
    let plate = CAShapeLayer()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    public init(diameter: CGFloat = MonogramAvatarView.rowDiameter) {
        super.init(frame: .zero)
        clipsToBounds = true
        layer.insertSublayer(plate, at: 0)
        label.font = Self.monogramFont(diameter)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.pin(to: self)
        widthConstraint = widthAnchor.constraint(equalToConstant: diameter)
        heightConstraint = heightAnchor.constraint(equalToConstant: diameter)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        setRound(diameter)
        drawPlate(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: MonogramAvatarView, _: UITraitCollection) in
            view.drawPlate(in: view.bounds)
        }
    }

    /// ⚠️ THE PLATE IS NOT THE VIEW'S BACKGROUND, and the author pill is why.
    ///
    /// It was `backgroundColor = .tertiarySystemFill`, a system FILL. Inside a
    /// Liquid Glass bar item UIKit does not draw a fill as a plain layer
    /// background: the view's layer carries NO background colour and a
    /// `_UIMultiLayer` sublayer paints the fill instead (measured with
    /// `-pill-probe`). When the item first materialised inside a push's bar
    /// transition, that fill was drawn as a rounded SQUARE — the corner
    /// radius AND the oval mask on this view notwithstanding — and stayed so
    /// until the item was installed again (filmed on a device; reproduced on
    /// the iPhone 18 Pro simulator with an author who has no picture).
    ///
    /// An oval PATH filled with a colour resolved against this view's traits
    /// is a shape, not a fill to be reinterpreted: nothing a container does to
    /// corners, masks or vibrancy can make an oval path square.
    private func drawPlate(in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = rect
        plate.path = shape.path(in: CGRect(origin: .zero, size: rect.size)).cgPath
        plate.fillColor = Self.plateColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    /// ⚠️ ROUND FROM BIRTH, not from the first layout pass. The diameter is
    /// known here, and a disc whose radius waits for `layoutSubviews` is a
    /// SQUARE wherever it is drawn before one runs — a copy of the bars taken
    /// for a flight, a bar item's first frame on a device. Reported as "a kind
    /// of square" in the feed's author pill, where every other avatar was
    /// round.
    private func setRound(_ diameter: CGFloat) {
        AvatarShapeMask.round(self, as: shape, side: diameter)
    }

    /// The outline — a disc unless a surface asks for its rounded square
    /// (`AvatarShape`). The corner, the mask and the plate all follow it.
    public var shape: AvatarShape = .circle {
        didSet {
            guard shape != oldValue else { return }
            let side = heightConstraint.constant
            setRound(side)
            drawPlate(in: bounds.width > 0 ? bounds : CGRect(x: 0, y: 0, width: side, height: side))
            setNeedsLayout()
        }
    }

    /// Resizes the disc, initials included — for a row whose disc is sized
    /// from its text and follows Dynamic Type.
    public func setDiameter(_ diameter: CGFloat) {
        guard diameter > 0, heightConstraint.constant != diameter else { return }
        widthConstraint.constant = diameter
        heightConstraint.constant = diameter
        label.font = Self.monogramFont(diameter)
        setRound(diameter)
    }

    private static func monogramFont(_ diameter: CGFloat) -> UIFont {
        .systemFont(ofSize: diameter * 0.375, weight: .semibold)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Still refreshed from the bounds, for a host that sizes the disc
        // itself — never to zero, which is how the square got drawn.
        let side = min(bounds.width, bounds.height)
        AvatarShapeMask.round(self, as: shape, side: side)
        AvatarShapeMask.apply(shape, to: self)
        if plate.frame != bounds { drawPlate(in: bounds) }
    }

    /// Whether a picture covers the disc. A covered disc draws NOTHING, no
    /// plate and no initials: an avatar is the picture alone. Where a
    /// container reshaped the plate, it showed around the picture as a grey
    /// rim (seen on a device in the feed's author pill).
    public var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.isHidden = isCovered
            CATransaction.commit()
            label.isHidden = isCovered
        }
    }

    private static let plateColor = UIColor.tertiarySystemFill

    /// Initials on the app's rule: the display name when there is one, the
    /// handle when there is not — the first letter of the first two words,
    /// "?" when there is nothing to read.
    nonisolated public static func monogram(name: String, handle: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) : trimmed
        let initials = source
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    public func setMonogram(_ monogram: String) {
        label.text = monogram
    }

    #if DEBUG
    /// The initials on the plate, for probes looking for copies of it.
    public var debugMonogramText: String? { label.text }
    #endif
}
