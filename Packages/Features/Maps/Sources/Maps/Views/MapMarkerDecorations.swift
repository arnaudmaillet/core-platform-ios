import UIKit

// MARK: - Flag border

/// A marker's border painted in its country's flag colours (`FlagPalette`):
/// a gradient running the way the flag reads — France blue → white → red left
/// to right, Germany black → red → gold top to bottom — under a hairline that
/// keeps a white or black band visible on a map of the same tone.
///
/// ⚠️ **IT TRACKS THE CARD THROUGH A FLIGHT, AND THAT IS WHY IT IS BUILT THIS
/// WAY.** The flying card animates its frame and corner radius inside UIKit
/// animation blocks and its children follow by autoresizing, which applies
/// synchronously from inside `setBounds` — so anything posed there sweeps on
/// the card's own curve for free. The ring's MASK is not a subview and is never
/// autoresized, so it is re-posed from this view's own `bounds` setter (inside
/// the same block) rather than from `layoutSubviews`, which UIKit defers to
/// the end of the turn and which would snap the ring to its landing size on
/// the flight's first frame. The radius is written by the card's
/// `setCornerRadius`, which the flight also calls inside its blocks.
final class MapFlagBorderView: UIView {
    /// The flag border is a point heavier than the neutral ring, like the
    /// hierarchy rings it replaces: a place reads at a glance.
    nonisolated static let lineWidth: CGFloat = 3
    /// How far the hairline reaches inside the ring's inner edge.
    private static let hairlineReach: CGFloat = 0.75

    private let hairline = UIView()
    private let ring = GradientView()
    /// The ring's mask: a border and nothing inside it.
    private let ringShape = UIView()
    private(set) var flagCode: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for view in [hairline, ring] {
            view.isUserInteractionEnabled = false
            // Top-left anchored, like every full-bleed child of the card —
            // see the register note in `PinCardView.init`.
            view.layer.anchorPoint = .zero
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        hairline.layer.borderWidth = Self.lineWidth + Self.hairlineReach
        ringShape.backgroundColor = .clear
        ringShape.layer.borderColor = UIColor.black.cgColor
        ringShape.layer.borderWidth = Self.lineWidth
        ringShape.frame = bounds
        ring.mask = ringShape
        ring.onBoundsChange = { [weak self] bounds in self?.ringShape.frame = bounds }
        applyHairlineColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyHairlineColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A dark hairline on the light map, a light one on the dark map: a white
    /// band (Japan, France's middle) never melts into light tiles, nor a black
    /// one (Germany) into dark ones.
    private static let hairlineColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.3)
            : UIColor(white: 0, alpha: 0.22)
    }

    private func applyHairlineColor() {
        hairline.layer.borderColor = Self.hairlineColor.resolvedColor(with: traitCollection).cgColor
    }

    /// Paints the flag of `code`, or clears it.
    func setFlag(_ code: String?) {
        guard code != flagCode else { return }
        flagCode = code
        guard let code else {
            ring.gradient.colors = nil
            return
        }
        let entry = FlagPalette.entry(for: code)
        // Each colour HOLDS for a stretch before it turns into the next, so
        // the border reads as bands of the flag rather than as a wash.
        let colors = entry.colors
        let step = 1 / Double(colors.count)
        var stops: [NSNumber] = []
        var cgColors: [CGColor] = []
        for (index, color) in colors.enumerated() {
            let start = Double(index) * step
            stops += [NSNumber(value: start + step * 0.2), NSNumber(value: start + step * 0.8)]
            cgColors += [color.cgColor, color.cgColor]
        }
        ring.gradient.type = .axial
        ring.gradient.colors = cgColors
        ring.gradient.locations = stops
        switch entry.axis {
        case .horizontal:
            ring.gradient.startPoint = CGPoint(x: 0, y: 0.5)
            ring.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        case .vertical:
            ring.gradient.startPoint = CGPoint(x: 0.5, y: 0)
            ring.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }

    /// The ring's shape — the card's radius and curve, written alongside the
    /// card's own (and inside the same animation, when there is one).
    func setShape(radius: CGFloat, curve: CALayerCornerCurve) {
        for layer in [hairline.layer, ringShape.layer] {
            layer.cornerRadius = radius
            layer.cornerCurve = curve
        }
    }

    #if DEBUG
    var debugGradientColors: [CGColor] { (ring.gradient.colors as? [CGColor]) ?? [] }
    var debugGradientIsVertical: Bool { ring.gradient.startPoint.x == 0.5 }
    var debugRingShape: UIView { ringShape }
    #endif

    /// A view backed by its gradient, reporting its bounds the moment they
    /// are set (see the type's note).
    private final class GradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradient: CAGradientLayer { layer as! CAGradientLayer }
        var onBoundsChange: ((CGRect) -> Void)?
        override var bounds: CGRect {
            didSet { if bounds != oldValue { onBoundsChange?(bounds) } }
        }
        override var frame: CGRect {
            didSet { onBoundsChange?(bounds) }
        }
    }
}

// MARK: - Corner badge

/// The small disc riding a marker's bottom-right corner, half over its edge
/// like an app icon's badge: the country's flag, a city's glyph, or a lock.
///
/// Opaque, with its own small shadow on an explicit path — legible over any
/// face and any map, and cheap under a field of animating markers.
final class MapMarkerBadgeView: UIView {
    /// The disc's diameter.
    nonisolated static let side: CGFloat = 20
    private static let rimWidth: CGFloat = 1.5

    private let disc = UIView()
    private let imageView = UIImageView()
    private(set) var badge: MapMarkerDress.Badge?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: frame.minX, y: frame.minY, width: Self.side, height: Self.side))
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 0.5)
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        disc.frame = bounds
        disc.layer.cornerRadius = Self.side / 2
        disc.layer.cornerCurve = .circular
        disc.layer.borderWidth = Self.rimWidth
        disc.clipsToBounds = true
        addSubview(disc)
        imageView.contentMode = .scaleAspectFit
        disc.addSubview(imageView)
        applyRim()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyRim()
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The rim takes the map's own ground, so the badge reads as cut out of
    /// whatever the marker shows rather than stuck on top of it.
    private func applyRim() {
        disc.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }

    /// The glyph's ink on a city or lock badge, and the disc it sits on.
    private static let glyphGround = UIColor(white: 0.16, alpha: 1)

    func setBadge(_ badge: MapMarkerDress.Badge?) {
        guard badge != self.badge else { return }
        self.badge = badge
        isHidden = badge == nil
        switch badge {
        case .flag(let code):
            disc.backgroundColor = .systemBackground
            imageView.image = FlagPalette.image(for: code)
            imageView.tintColor = nil
            // The flag fills the disc's width inside the rim: an emoji flag is
            // wider than tall, so it sits as a band across the middle.
            imageView.frame = bounds.insetBy(dx: Self.rimWidth + 1.5, dy: Self.rimWidth + 1.5)
        case .city, .lock:
            disc.backgroundColor = Self.glyphGround
            let name = badge == .city ? "building.2.fill" : "lock.fill"
            imageView.image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            )
            imageView.tintColor = .white
            imageView.contentMode = .center
            imageView.frame = bounds
            return
        case nil:
            imageView.image = nil
        }
        imageView.contentMode = .scaleAspectFit
    }

    /// Where the badge's centre sits for a card of `size` and corner
    /// `radius`: ON the corner's arc, at 45°, so it overlaps the edge the same
    /// way on a rounded square, a disc, or a bare icon's square.
    nonisolated static func center(in size: CGSize, cornerRadius radius: CGFloat) -> CGPoint {
        // The 45° point of the arc, measured in from the bounding corner. A
        // square corner (an icon) would put the badge's centre on the very
        // corner of a mark that rarely reaches it, so it comes in a little.
        let inset = max(3, radius * (1 - 1 / 2.squareRoot()))
        return CGPoint(x: size.width - inset, y: size.height - inset)
    }
}
