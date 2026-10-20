import UIKit

/// An avatar frame (#943, backend #913): a decorative ring the profile wears
/// on its avatar, bought with gems and seen by everyone. Keyed by the wallet
/// catalogue's item id (`frame.<name>`); an id this build does not know
/// draws no frame.
///
/// The ring lies ON the avatar's rim, inside its bounds: a frame never
/// changes the avatar's size, its layout, or what a host clips.
public enum AvatarFrame: String, CaseIterable, Sendable {
    case gold = "frame.gold"
    case neon = "frame.neon"
    case aurora = "frame.aurora"

    /// The frame for a profile's `avatar_frame_id`; nil for none (empty) or
    /// an id this build has no art for.
    public init?(id: String?) {
        guard let id, let frame = AvatarFrame(rawValue: id) else { return nil }
        self = frame
    }

    /// Its name, in the Shop and on the Equip screen.
    public var title: String {
        switch self {
        case .gold: "Gold"
        case .neon: "Neon"
        case .aurora: "Aurora"
        }
    }

    /// The ring's stops, swept from twelve o'clock (`Palette`).
    var stops: [UIColor] {
        switch self {
        case .gold: Palette.frameGold
        case .neon: Palette.frameNeon
        case .aurora: Palette.frameAurora
        }
    }

    /// A glow around the ring, if it has one.
    var glow: UIColor? {
        self == .neon ? Palette.frameNeonGlow : nil
    }

    /// The ring's width on an avatar `diameter` across: thin enough to keep
    /// the face, wide enough to read on a 36 pt row.
    public static func ringWidth(forDiameter diameter: CGFloat) -> CGFloat {
        max(2, (diameter * 0.07).rounded(.toNearestOrEven))
    }
}

/// Draws an `AvatarFrame` over an avatar of the same bounds, in its shape.
public final class AvatarFrameView: UIView {
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()

    /// The frame drawn; nil draws nothing.
    public var frameStyle: AvatarFrame? {
        didSet {
            guard frameStyle != oldValue else { return }
            apply()
        }
    }

    /// The avatar's outline: the ring follows it.
    public var shape: AvatarShape = .circle {
        didSet {
            guard shape != oldValue else { return }
            setNeedsLayout()
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        ring.fillColor = nil
        ring.strokeColor = UIColor.black.cgColor
        gradient.mask = ring
        layer.addSublayer(gradient)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        ring.frame = bounds
        let width = AvatarFrame.ringWidth(forDiameter: min(bounds.width, bounds.height))
        ring.lineWidth = width
        ring.path = shape.path(in: bounds.insetBy(dx: width / 2, dy: width / 2)).cgPath
        CATransaction.commit()
    }

    private func apply() {
        isHidden = frameStyle == nil
        guard let frameStyle else { return }
        // Fixed colours: no appearance or theme to follow.
        gradient.colors = frameStyle.stops.map(\.cgColor)
        if let glow = frameStyle.glow {
            layer.shadowColor = glow.cgColor
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.8
            layer.shadowOffset = .zero
        } else {
            layer.shadowOpacity = 0
        }
    }

    /// The ring's width and stops as drawn. Tests.
    public var drawnRingWidth: CGFloat { ring.lineWidth }
    public var drawnStops: [CGColor] { (gradient.colors as? [CGColor]) ?? [] }
}
