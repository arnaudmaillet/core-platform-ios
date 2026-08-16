import CoreNavigation
import MediaPlayback
import UIKit

/// The single source of truth for how a post renders as a rounded media card:
/// the map pin's face *and* the hero transition's flying card are both this
/// exact component. That is what makes the transition's frame-0 handshake
/// pixel-identical by construction — there are no per-surface copies of the
/// radius, border, or crop rules left to drift apart.
///
/// Layer order (bottom → top): cover image, live video surface, border ring.
/// The card itself clips and rounds; the ring draws the pin's border above
/// whichever media surface is showing, so a live-previewing pin keeps its ring
/// too. During a flight the animator animates `frame`, `setCornerRadius`, and
/// `ringView.alpha` — everything else tracks via autoresizing.
final class PinCardView: UIView {
    /// The radius a MEDIA card renders at pin size (and flies from/to). A text
    /// card is a circle instead — see `Face.cornerRadius`, which reads this and
    /// so must be able to from outside the main actor.
    nonisolated static let cornerRadius: CGFloat = 12
    // `nonisolated` like `cornerRadius` above: a UIView subclass's statics are
    // `@MainActor` by inference, and `MapMarkerRing` reads this from a
    // nonisolated default value.
    nonisolated static let ringWidth: CGFloat = 2

    /// The glyph a text-only post's marker shows in place of a cover. Product
    /// vocabulary for a text post elsewhere in the app is "Short"
    /// (`GalleryFilter.short`).
    static let textSymbolName = "text.alignleft"
    /// Point size of that glyph inside the 44pt circle — ~40% of the diameter,
    /// which reads at pin size while leaving a ring of the tinted ground
    /// visible as its own signal.
    static let textSymbolPointSize: CGFloat = 18

    /// The post's cover image, full-bleed aspect-fill. During a frame-animated
    /// flight the crop *morphs* between the pin's square and the page's
    /// full-bleed rect — CoreAnimation re-applies the fill gravity every frame.
    let imageView = UIImageView()
    /// The text-only face, above the (empty) cover and below the ring. Hidden
    /// for every media pin, so a recycled view must be told which face to wear
    /// on every configure — see `setFace(_:)`.
    private let textFaceView = PinTextFaceView()
    /// Live-preview surface above the image, hidden until playback attaches.
    let videoRenderView = VideoRenderView()
    /// The pin's border, drawn above the media so it survives live previews.
    /// The flight fades it out as the card leaves the pin (and back in on the
    /// way home).
    let ringView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoRenderView.clipsToBounds = true
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        textFaceView.frame = bounds
        textFaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textFaceView.isHidden = true
        addSubview(textFaceView)

        ringView.isUserInteractionEnabled = false
        ringView.layer.borderWidth = Self.ringWidth
        ringView.layer.borderColor = ringColor.cgColor
        ringView.layer.cornerRadius = Self.cornerRadius
        ringView.layer.cornerCurve = .continuous
        ringView.frame = bounds
        ringView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(ringView)

        // `borderColor` is a CGColor and doesn't follow dark/light on its own —
        // re-resolve whatever ring color is CURRENTLY worn (neutral, or a
        // hierarchy color; both are dynamic).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.ringView.layer.borderColor = self.ringColor.resolvedColor(
                with: self.traitCollection
            ).cgColor
        }
    }

    /// The ring's current color — neutral by default, a hierarchy color when
    /// the marker speaks for a city/region/country (see `MapMarkerRing`).
    /// Stored as the DYNAMIC color so trait changes can re-resolve it.
    private var ringColor: UIColor = .systemBackground

    /// Dresses the ring for the marker's hierarchy level. One call sets both
    /// halves so a marker can never wear one level's color at another's
    /// weight.
    func setRing(color: UIColor, width: CGFloat) {
        ringColor = color
        ringView.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
        ringView.layer.borderWidth = width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Which face the card wears — and, with it, the marker's whole resting
    /// geometry.
    ///
    /// Defined here, on the ONE component the pin, the cluster marker and the
    /// hero's flying card all render, so a text post looks the same on all
    /// three by construction rather than by three surfaces agreeing — the same
    /// reason the radius, border and crop rules live here. A surface that wants
    /// a marker's size asks the face; nothing re-derives 56 or 44 locally.
    enum Face: Equatable {
        /// The post's cover image, loaded into `imageView`.
        case media
        /// A symbol on a tinted ground: a text-only post has no cover to show.
        case text

        /// The marker's resting side. A text post carries no image worth
        /// showing at cover size, so its marker is deliberately smaller than a
        /// media pin — the map stays a field of photographs with text posts
        /// reading as lighter punctuation between them, rather than two equal
        /// squares competing for the same attention.
        var side: CGFloat {
            switch self {
            case .media: 56
            case .text: 44
            }
        }

        /// The resting corner radius. Half the side turns the square into a
        /// circle, which is what separates a text marker from a media one at a
        /// glance even before the glyph resolves.
        var cornerRadius: CGFloat {
            switch self {
            case .media: PinCardView.cornerRadius
            case .text: side / 2
            }
        }
    }

    /// The face currently worn. Its `cornerRadius` is the card's RESTING radius
    /// — read by the hero flight as the endpoint it sweeps to, so it has to be
    /// a constant of the face and never derived from the card's live bounds
    /// (mid-flight those are the page's).
    private(set) var face: Face = .media

    /// Poses the card for `face`, including its resting shape. Sizing the card
    /// itself stays with the caller — an annotation view owns its own frame,
    /// and the flight card is posed by the animator.
    ///
    /// Idempotence is the CALLER's business (an annotation view re-configures
    /// every surviving marker on each reconcile), but this is safe to call
    /// repeatedly — it only sets state.
    func setFace(_ face: Face) {
        self.face = face
        textFaceView.isHidden = face != .text
        // The media ground is black so a letterboxed cover reads as framed; a
        // text card's ground is the face's own tint, and the black would show
        // through its corner curve.
        backgroundColor = face == .text ? .clear : .black
        setCornerRadius(face.cornerRadius)
    }

    /// Rounds the card and its ring together. Both properties are
    /// UIView-animatable, so calling this inside an animation block sweeps the
    /// radius smoothly (pin 12pt ↔ device display corners).
    func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
        ringView.layer.cornerRadius = radius
    }

    /// The soft shadow that lifts a pin card off the map — one definition used
    /// by both the annotation view and the flight's stand-in shadow.
    static func applyPinShadow(to layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    // MARK: - Flight video mode

    /// Re-anchors the live video surface for a flight. An `AVPlayerLayer`
    /// whose *bounds* animate does not track the animation smoothly — its
    /// video rect snaps — so for the flight the surface is laid out once at
    /// the destination size and driven purely by a uniform-scale transform
    /// (plus an animated center), while the card's animating bounds do the
    /// crop morph. The layer's bounds never change, so rendering stays smooth.
    func prepareVideoForFlight(destinationSize: CGSize) {
        videoRenderView.autoresizingMask = []
        videoRenderView.bounds = CGRect(origin: .zero, size: destinationSize)
    }

}

// MARK: - Text face

/// The face a text-only post's marker wears: a centred SF Symbol on a tinted
/// ground. First iteration of the custom text marker — deliberately built from
/// the same 56pt square, ring and shadow as a media pin, so the hero flight's
/// frame-0 handshake and the cluster grid's collision size stay exactly as they
/// were and only the *face* differs.
///
/// The ground is opaque (an accent wash over the system background) rather than
/// a translucent tint: a marker sits on map tiles of any colour, and a
/// see-through card makes the glyph unreadable over a park or a motorway.
///
/// Colours are `UIColor`s, not `CGColor`s, so dark/light follows the trait
/// change on its own — the trap `PinCardView.ringView` needs a registration to
/// work around.
private final class PinTextFaceView: UIView {
    private let wash = UIView()
    private let glyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        wash.backgroundColor = UIColor.tintColor.withAlphaComponent(0.22)
        wash.frame = bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wash.isUserInteractionEnabled = false
        addSubview(wash)

        glyph.image = UIImage(systemName: PinCardView.textSymbolName)?
            .withConfiguration(UIImage.SymbolConfiguration(
                pointSize: PinCardView.textSymbolPointSize, weight: .semibold
            ))
        glyph.tintColor = .tintColor
        glyph.contentMode = .center
        glyph.frame = bounds
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - ZoomFlightCard

/// The pin's face IS the hero's flying card, which is what makes the frame-0
/// handshake exact rather than agreed. The shared machinery poses it through
/// this conformance and never names `PinCardView`.
extension PinCardView: ZoomFlightCard {
    /// The face's radius, not the card's current one: mid-flight the card is
    /// page-shaped, and this is the endpoint the sweep runs back to.
    var zoomRestingCornerRadius: CGFloat { face.cornerRadius }

    /// The pin's border, which must not survive into the page pose.
    var zoomRestingChrome: UIView? { ringView }

    var zoomLiveMediaSurface: UIView? { videoRenderView.isHidden ? nil : videoRenderView }

    var zoomLiveMediaNativeSize: CGSize? { videoRenderView.nativeVideoSize }

    /// Same rule as the grid's flight card: a pin flying without live media
    /// shows its cover, which is always drawing; one flying with live media is
    /// only "drawing" while that surface is actually visible.
    var zoomLiveMediaIsDrawing: Bool {
        videoRenderView.isHidden ? true : videoRenderView.isRenderingVisibly
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(videoRenderView) else { return }
        // Poster covers the (usually sub-frame) gap until the mirrored layer
        // reports its first frame.
        videoRenderView.setPoster(imageView.image)
        videoRenderView.isHidden = false
    }

    func setZoomCornerRadius(_ radius: CGFloat) {
        setCornerRadius(radius)
    }

    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        prepareVideoForFlight(destinationSize: destinationSize)
    }

    /// A pin lifts off the map, so its flight carries the same drop shadow.
    func applyZoomRestingShadow(to layer: CALayer) {
        Self.applyPinShadow(to: layer)
    }
}
