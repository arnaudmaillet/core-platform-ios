import UIKit

/// The app's identity disc: initials on a fixed light grey plate (#2051),
/// clipped to a circle at any diameter.
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

    /// The initials, drawn into a layer's contents (`drawInitials`).
    let initials = CALayer()
    private var monogramText: String?
    /// The plate: the avatar's `shape` (an oval by default) filled with a RESOLVED colour — see
    /// `drawPlate` for why it is not the view's background.
    let plate = CAShapeLayer()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    public init(diameter: CGFloat = MonogramAvatarView.rowDiameter) {
        super.init(frame: .zero)
        clipsToBounds = true
        layer.insertSublayer(plate, at: 0)
        initials.contentsGravity = .center
        layer.insertSublayer(initials, above: plate)
        widthConstraint = widthAnchor.constraint(equalToConstant: diameter)
        heightConstraint = heightAnchor.constraint(equalToConstant: diameter)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        setRound(diameter)
        drawPlate(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        // ⚠️ NOT FOR THE APPEARANCE (#2051): nothing the disc draws depends on
        // it. It redrew for `userInterfaceStyle`, and that is how one person
        // wore a light disc in one bar and a dark one in the next. Only the
        // scale, for the initials' bitmap.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: MonogramAvatarView, _: UITraitCollection) in
            view.drawInitials()
        }
    }

    /// ⚠️ THE INITIALS ARE A BITMAP, NOT A LABEL (#2051). Inside a Liquid
    /// Glass bar item UIKit draws a `UILabel` as VIBRANT content, whatever
    /// its colour: on the snap feed's dark bar the author pill's dark grey
    /// initials came out a light grey on the light plate, nearly invisible
    /// (the iPhone 18 Pro simulator, dark mode) — and white over the light
    /// plate in the owner's first film. A layer's contents are drawn as they
    /// are, so the ink is the one the plate was chosen for.
    func drawInitials() {
        let side = heightConstraint.constant
        guard let text = monogramText, !text.isEmpty, side > 0 else {
            initials.contents = nil
            return
        }
        let scale = max(traitCollection.displayScale, 1)
        let image = Self.initialsImage(text, side: side, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        initials.contents = image.cgImage
        initials.contentsScale = scale
        initials.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        initials.position = initialsCentre
        CATransaction.commit()
    }

    /// Where the initials sit: the bounds' centre, as the label pinned to
    /// them did — the constraint's before the first layout.
    private var initialsCentre: CGPoint {
        bounds.width > 0
            ? CGPoint(x: bounds.midX, y: bounds.midY)
            : CGPoint(x: heightConstraint.constant / 2, y: heightConstraint.constant / 2)
    }

    /// Drawn once per change of initials, side or scale (`setMonogram`
    /// ignores the same initials again): a 48 pt disc is a few kilobytes,
    /// and no cache of images lives outside the pipeline (#894).
    private static func initialsImage(_ text: String, side: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: monogramFont(side),
            .foregroundColor: Surface.avatarInitials
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            (text as NSString).draw(
                at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2),
                withAttributes: attributes
            )
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
    /// An oval PATH filled with a fixed colour (#2051) is a shape, not a fill
    /// to be reinterpreted: nothing a container does to corners, masks or
    /// vibrancy can make an oval path square.
    private func drawPlate(in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = rect
        plate.path = shape.path(in: CGRect(origin: .zero, size: rect.size)).cgPath
        plate.fillColor = currentPlateColor.cgColor
        CATransaction.commit()
    }

    private var currentPlateColor: UIColor { showsFinalInitials ? Self.initialsPlateColor : Self.plateColor }

    /// Whether the initials are the face's FINAL state — no picture, or one
    /// that failed — rather than the floor a picture is loading on (#1912).
    /// Final, the plate wears its own grey (`initialsPlateColor`), so the
    /// face stands apart from the following ring and the badge's disc, which
    /// are the loading floor's grey; loading, it stays `Surface.avatarGround`.
    /// The change is a cross-fade, never a flash.
    public var showsFinalInitials = false {
        didSet {
            guard showsFinalInitials != oldValue else { return }
            let target = currentPlateColor.cgColor
            if window != nil {
                let fade = CABasicAnimation(keyPath: "fillColor")
                fade.fromValue = plate.presentation()?.fillColor ?? plate.fillColor
                fade.toValue = target
                fade.duration = 0.2
                plate.add(fade, forKey: "fillColor")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.fillColor = target
            CATransaction.commit()
        }
    }

    /// The final initials' grey (#1912): `Surface.avatarInitialsGround`, the
    /// light appearance's `systemGray4` in BOTH appearances (#2051: the dark
    /// grey must not exist). A step darker than the loading floor, apart
    /// from the badge's quiet disc and the following ring.
    public static let initialsPlateColor = Surface.avatarInitialsGround

    /// The plate's colour as drawn now. Tests.
    public var drawnPlateColor: UIColor { UIColor(cgColor: plate.fillColor ?? UIColor.clear.cgColor) }

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
        setRound(diameter)
        drawInitials()
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
        if initials.position != initialsCentre {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            initials.position = initialsCentre
            CATransaction.commit()
        }
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
            initials.isHidden = isCovered
            CATransaction.commit()
        }
    }

    /// The avatar's ground (#2051): the plate is the floor an avatar's
    /// picture loads on, so it wears the avatar's bone's own grey — a face
    /// that never arrives sits on the colour its skeleton had. Fixed light,
    /// whatever the appearance.
    public static let plateColor = Surface.avatarGround

    /// The initials' ink. Tests.
    public var drawnInitialsColor: UIColor? { monogramText == nil ? nil : Surface.avatarInitials }

    /// Initials on the app's rule: the display name when there is one, the
    /// handle when there is not — the first letter of the first two words,
    /// "?" when there is nothing to read.
    ///
    /// A sigil is never an initial, on either side (#811): Search's Recent
    /// stores `displayName ?? handle` as its name, so "@grace" can arrive as a
    /// NAME and must read "G" like the same person's Suggestion row. A name
    /// that is nothing but sigils falls back to the handle.
    ///
    /// Two surfaces read the rule with a twist, stated here rather than in a
    /// private copy of their own (#811). The defaults are the rule above.
    /// - `separators`: characters that also break words, besides the space,
    ///   in whichever of the two is read. The followers/following lists pass
    ///   "." and "_" so the handle "lena_klein" reads "LK".
    /// - `maxLetters`: how many initials at most (never fewer than one). The
    ///   share sheet's quick targets pass 1: their disc holds one 22pt letter.
    nonisolated public static func monogram(
        name: String,
        handle: String,
        splittingOn separators: Set<Character> = [],
        maxLetters: Int = 2
    ) -> String {
        let trimmed = name.trimmingCharacters(in: sigilAndSpace)
        let source = trimmed.isEmpty ? handle.trimmingCharacters(in: sigilAndSpace) : trimmed
        let initials = source
            .split(whereSeparator: { $0 == " " || separators.contains($0) })
            .prefix(max(maxLetters, 1))
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// Built once: the rule runs in cell configuration.
    nonisolated private static let sigilAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))

    public func setMonogram(_ monogram: String) {
        guard monogram != monogramText else { return }
        monogramText = monogram
        drawInitials()
    }

    #if DEBUG
    /// The initials on the plate, for probes looking for copies of it.
    public var debugMonogramText: String? { monogramText }
    #endif
}
