import CoreNavigation
import MediaPlayback
import UIKit

/// The single source of truth for how a post renders as a rounded media card:
/// the map pin's face *and* the hero transition's flying card are both this
/// exact component. That is what makes the transition's frame-0 handshake
/// pixel-identical by construction — there are no per-surface copies of the
/// radius, border, or crop rules left to drift apart.
///
/// Layer order (bottom → top): arrival cover image, DEPARTURE cover image,
/// live video surface, text face, border ring. The card itself clips and
/// rounds; the ring draws the pin's border above whichever media surface is
/// showing, so a live-previewing pin keeps its ring too. During a flight the
/// animator animates `frame`, `setCornerRadius`, `ringView.alpha` and — only
/// when a departure picture was handed in — the blend alphas; everything else
/// tracks via autoresizing.
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
    /// The FALLBACK face for a text post, and only that.
    ///
    /// It was `text.alignleft` — a description of the post's kind, which is
    /// what the marker used to be about. A text marker now wears its author
    /// (`MapPin.authorAvatarURL`), so the symbol is what stands in while that
    /// face is loading, or for an author who has none: an account glyph, so the
    /// stand-in is the same KIND of thing as what replaces it rather than a
    /// different statement about the post.
    static let textSymbolName = "person.crop.circle.fill"
    /// Point size of that glyph inside the 44pt circle — ~40% of the diameter,
    /// which reads at pin size while leaving a ring of the neutral ground
    /// visible as its own signal.
    static let textSymbolPointSize: CGFloat = 18

    /// The post's cover image, full-bleed aspect-fill. During a frame-animated
    /// flight the crop *morphs* between the pin's square and the page's
    /// full-bleed rect — CoreAnimation re-applies the fill gravity every frame.
    let imageView = UIImageView()
    /// The DEPARTURE post's cover — the blend's second operand, empty and
    /// hidden until a flight hands one in (`setDeparturePicture`).
    ///
    /// ABOVE the arrival cover because the blend only ever moves the alpha of
    /// whichever operand is on TOP and leaves the other fully opaque beneath
    /// (see `applyBlend`). BELOW the live surface because on a dismissal that
    /// surface is the departing page's own moving picture and this still is
    /// nothing but its poster — burying the video under a still would fly a
    /// frozen frame for the whole flight, which is the regression the live
    /// media work exists to prevent.
    private let departureCoverView = UIImageView()
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

        departureCoverView.contentMode = .scaleAspectFill
        departureCoverView.clipsToBounds = true
        // OPAQUE ground, and the same one the arrival cover wears. A blend
        // operand that is see-through anywhere sums with the other one to a
        // half-drawn frame, which is precisely what the fade law forbids; the
        // matching ground also makes the two crop and letterbox identically at
        // every size the card passes through.
        departureCoverView.backgroundColor = .secondarySystemBackground
        departureCoverView.isHidden = true
        departureCoverView.frame = bounds
        departureCoverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(departureCoverView)

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
        /// A symbol on a neutral ground: a text-only post has no cover to show.
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
    /// This is the ARRIVAL face, and it stays a plain switch: even with a
    /// departure picture loaded, the face alone decides `side`, `cornerRadius`
    /// and the background. Only the DRAWN CONTENT becomes a pair, and which of
    /// the two operands the blend fades follows from the face rather than being
    /// a second thing to configure — see `applyBlend`. With no departure
    /// picture the re-apply below restores exactly the alphas this method has
    /// always left behind.
    ///
    /// Idempotence is the CALLER's business (an annotation view re-configures
    /// every surviving marker on each reconcile), but this is safe to call
    /// repeatedly — it only sets state.
    /// The author's face for a TEXT marker — see `PinTextFaceView.setAvatar`.
    /// A no-op on a media face, which has a cover of its own.
    func setTextAvatar(_ image: UIImage?) {
        textFaceView.setAvatar(image)
    }

    /// The author face this card is wearing, so a transition can carry it —
    /// see `MapPinRevealSource.marker`. Reading it back rather than being told
    /// again is what keeps the flying card and the marker the same picture.
    var textAvatar: UIImage? { textFaceView.avatarImage }

    func setFace(_ face: Face) {
        self.face = face
        textFaceView.isHidden = face != .text
        // The media ground is black so a letterboxed cover reads as framed; a
        // text card's ground is the face's own tint, and the black would show
        // through its corner curve.
        backgroundColor = face == .text ? .clear : .black
        setCornerRadius(face.cornerRadius)
        applyBlend()
    }

    // MARK: - Departure blend

    /// How far the card has blended toward its ARRIVAL content: 0 draws the
    /// departure picture, 1 the marker's own face.
    ///
    /// 1 at rest, because a marker that was never handed a departure picture is
    /// only ever itself.
    private var blend: CGFloat = 1

    /// Hands the card the picture it is flying FROM, as the blend's second
    /// operand. The card keeps drawing its own face; this only gives the blend
    /// something to draw against.
    ///
    /// `nil` means there is no second operand: the blend channel goes inert and
    /// the card renders exactly as it did before this existed, byte for byte.
    /// That is how the row of the product rule that must NOT blend gets there —
    /// a dismissal onto the SAME media post is one picture at both ends, and a
    /// blend could only soften it.
    ///
    /// An operand that is not a photograph is still fine as long as it is an
    /// opaque IMAGE: a departure with no picture of its own can hand in the
    /// flat ground its page was drawn on, and the fade then runs from that
    /// colour to the marker. What must never arrive here is its TEXT — blending
    /// two runs of text draws both of them, which is the law this whole channel
    /// is built around.
    ///
    /// ⚠️ CALLER CONTRACT: pass nil whenever the card's live surface belongs to
    /// the ARRIVAL marker rather than to the departing page. The blend carries
    /// that surface with the departure operand (it is the same picture in
    /// motion, which is why it sits above this one), and a card that mirrored
    /// the landing pin's own preview would then fade out the very thing it is
    /// landing on.
    func setDeparturePicture(_ image: UIImage?) {
        departureCoverView.image = image
        departureCoverView.isHidden = image == nil
        if image == nil { departureBaseSize = nil }
        // Autoresizing and a transform do not compose; the cover is positioned
        // by hand from here on.
        departureCoverView.autoresizingMask = []
        setNeedsLayout()
        applyBlend()
    }

    /// The departure size carried between layout passes — see
    /// `DepartureCoverLayout.apply`, which owns what it means.
    private var departureBaseSize: CGSize?

    /// The shared rule — see `DepartureCoverLayout`, which states why the
    /// cover is scaled uniformly rather than re-fitted to the card.
    private func layoutDepartureCover() {
        departureBaseSize = DepartureCoverLayout.apply(
            to: departureCoverView, in: bounds, departureBase: departureBaseSize
        )
    }

    /// The blend channel: `t == 0` is the departure picture, `t == 1` the
    /// arrival content. Alpha-only, so calling this inside an animation block
    /// sweeps it with the rest of the flight.
    ///
    /// ⚠️ DELIBERATELY NOT PART OF `setContentOpacity`. That channel owns the
    /// ring as well as the cover, and it owns it for a reason of its own (a
    /// border reads as an outline drawn around the whole screen at full size,
    /// so it has to be gone well before the window is — see the note there).
    /// A blend riding it would drag the ring's fade onto the pictures' clock.
    /// That direction still holds: nothing here touches the ring.
    ///
    /// The other direction does not, and deliberately so — `setContentOpacity`
    /// re-aims this blend whenever a departure picture is loaded, because the
    /// reveal has only that one ramp to hand a picture over on. See the note
    /// there. A card with no departure picture is unaffected either way.
    func setBlend(_ t: CGFloat) {
        blend = min(max(t, 0), 1)
        applyBlend()
    }

    /// Applies `blend` to whichever operand is on top.
    ///
    /// ⚠️ EXACTLY ONE operand's alpha ever moves; the other stays fully opaque
    /// underneath it. That is the whole argument for why this blend is allowed
    /// where the flight's other fades are not. Two half-drawn layers over the
    /// card's own ground is the "two half-drawn overlays" that
    /// `ZoomFlight.poseInterpolated` rules out for the chrome alphas and that
    /// `RevealTransition`'s window law rules out for the caption. With one
    /// opaque operand behind, every intermediate frame is an opaque sum of two
    /// photographs — a whole picture, never two transparent ones.
    ///
    /// ⚠️ And it is legal only because both operands are PICTURES. The
    /// objection those two laws raise is about TEXT and LINE ART, and it does
    /// reach the media→icon row: the arrival operand there is `textFaceView` AS
    /// A WHOLE — the disc AND the glyph, one opaque unit. Fading the glyph
    /// alone (which is exactly what `setContentOpacity` does, for its own
    /// reasons) would blend a symbol over a see-through ground and draw the two
    /// half-finished drawings the law forbids.
    private func applyBlend() {
        guard departureCoverView.image != nil else {
            // No second operand. Every channel back to its resting value, which
            // is the un-blended card exactly as it was.
            departureCoverView.alpha = 1
            videoRenderView.alpha = 1
            textFaceView.alpha = 1
            return
        }
        switch face {
        case .media:
            // The departure stack sits on top of the marker's own cover, so it
            // is the half that fades. The live surface goes with it: on a
            // dismissal that surface is the departing page's picture and this
            // cover is its poster.
            textFaceView.alpha = 1
            departureCoverView.alpha = 1 - blend
            videoRenderView.alpha = 1 - blend
        case .text:
            // The marker's disc sits on top of the departure picture, so it is
            // the half that fades — in, as one opaque unit.
            departureCoverView.alpha = 1
            videoRenderView.alpha = 1
            textFaceView.alpha = blend
        }
    }

    /// Rounds the card and its ring together. Both properties are
    /// UIView-animatable, so calling this inside an animation block sweeps the
    /// radius smoothly (pin 12pt ↔ device display corners).
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDepartureCover()
    }

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

/// The face a text-only post's marker wears: a centred SF Symbol on a neutral
/// ground. Deliberately built from the same square, ring and shadow as a media
/// pin, so the hero flight's frame-0 handshake and the cluster grid's collision
/// size stay exactly as they were and only the *face* differs.
///
/// The ground is OPAQUE, never a translucent tint: a marker sits on map tiles
/// of any colour, and a see-through card makes the glyph unreadable over a park
/// or a motorway.
///
/// It is also colourless. It was an accent wash, and a blue disc on a map is a
/// place, a route or a transit line before it is a post — and since the reveal
/// lends this colour to the whole page for the length of an opening, a tinted
/// marker painted the screen with it. The glyph keeps the accent; the ground
/// does not.
///
/// Colours are `UIColor`s, not `CGColor`s, so dark/light follows the trait
/// change on its own — the trap `PinCardView.ringView` needs a registration to
/// work around.
private final class PinTextFaceView: UIView {
    /// The disc's opaque ground. Named for what it is now that it carries no
    /// tint — it was a translucent accent wash, and the name outlived it.
    private let disc = UIView()
    private let glyph = UIImageView()
    private let avatar = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        // NEUTRAL, and a tone rather than a hue.
        //
        // It was an accent wash at 0.22 — the marker read as a blue disc, and a
        // blue disc on a map is a place, a route or a transit line before it is
        // a post. Worse for the reveal: the page wears this colour for the
        // length of the opening, so a tinted marker painted the whole screen in
        // it for a third of a second.
        //
        // `secondarySystemBackground` keeps the disc distinguishable from the
        // page it opens into — that difference is what makes the ground tween
        // visible at all — without asserting a colour.
        disc.backgroundColor = .secondarySystemBackground
        disc.frame = bounds
        disc.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        disc.isUserInteractionEnabled = false
        addSubview(disc)

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

        // ABOVE the glyph, because it replaces it rather than decorating it: a
        // text post wearing its author's face says whose it is, and the symbol
        // is what is left when there is no face to show.
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.frame = bounds
        avatar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        avatar.isUserInteractionEnabled = false
        avatar.isHidden = true
        addSubview(avatar)
    }

    /// The author's face, or nil to fall back to the glyph.
    ///
    /// Nil is an ordinary answer and always will be in production until
    /// `RadarPin` carries an author (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`) —
    /// and it stays one afterwards, for an author who has no avatar.
    var avatarImage: UIImage? { avatar.image }

    func setAvatar(_ image: UIImage?) {
        avatar.image = image
        avatar.isHidden = image == nil
        glyph.isHidden = image != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glyph alone. The WASH stays: it is the disc's colour, and the colour
    /// is what the page is wearing on the other side of the hand-off.
    func setContentOpacity(_ alpha: CGFloat) {
        glyph.alpha = alpha
    }

    /// The disc's colour, for a page to wear while a reveal opened from this
    /// marker is running.
    ///
    /// One value rather than a composite now that the wash is opaque and
    /// neutral: what the marker shows IS this colour, and the page can simply
    /// be told it. (It was a hand-composited blend while the wash was a
    /// translucent tint — a page's `backgroundColor` is a single colour, and a
    /// translucent one there let the transition's dim through and read as dirty
    /// grey rather than as the marker.)
    static let ground: UIColor = .secondarySystemBackground
}

// MARK: - RevealStandInShaping

/// The pin's face is ALSO what a reveal's window opens as and closes onto — the
/// same argument that makes it the hero's flying card, applied to the other
/// transition. `setCornerRadius` is already the shape channel; this adds the
/// content one, so the two can be handed over separately.
extension PinCardView: RevealStandInShaping {
    /// The marker's CONTENT, which the page repeats none of: the glyph, the
    /// cover, and the ring that draws the marker's edge. Not the ground under
    /// them — that is the fill, faded by the view's own alpha, and it is the
    /// colour the page is wearing on the other side of the hand-off.
    ///
    /// The ring goes with the content on purpose. It reads as a marker's border
    /// at 44pt and as an outline drawn around the screen at full size, so it
    /// has to be gone well before the window is.
    func setContentOpacity(_ alpha: CGFloat) {
        textFaceView.setContentOpacity(alpha)
        imageView.alpha = alpha
        ringView.alpha = alpha
        // ⚠️ WITH A DEPARTURE PICTURE, THIS CHANNEL IS ALSO THE BLEND.
        //
        // A window closing onto a marker now hands its stand-in the picture it
        // is leaving, so that the media SCALES with the window instead of being
        // clipped by it. But the card's face is opaque at rest — it would sit
        // over that picture from frame 0 and nothing would have been gained.
        // The reveal has exactly one content ramp, and it means the same thing
        // the blend means: 0 is what is being left, 1 is the marker.
        //
        // Only when there IS a second operand. Without one this is the channel
        // it has always been, byte for byte.
        if departureCoverView.image != nil { setBlend(alpha) }
    }

    /// The colour a page wears while a reveal opened from a TEXT marker is
    /// running — the disc's own ground, composited to one opaque value.
    static var textRevealGround: UIColor { PinTextFaceView.ground }
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

    /// The pin's face is the flight's `t == 1` end and the page's picture its
    /// `t == 0` end, which is already what `setBlend` means — the marker is the
    /// arrival on a dismissal and the departure on a present, but either way
    /// "1" is the card's own content and "0" is the picture at the other end.
    ///
    /// Inert until a departure picture has been handed in, so every flight that
    /// does not need a blend is untouched by this.
    func setZoomContentBlend(_ t: CGFloat) {
        setBlend(t)
        // ⚠️ THE COVER IS POSED HERE, and it has to be, because a layout pass
        // is not an animation.
        //
        // Autoresizing used to carry the cover, and autoresizing is applied
        // synchronously from inside `setBounds` — so it swept with an animated
        // `card.frame` for free. The uniform scale replaced it with
        // `layoutSubviews`, which UIKit DEFERS to the end of the runloop turn,
        // outside whatever animation block set the frame. The cover then
        // snapped to its landing size on the flight's first frame and sat
        // there, a small patch on a card still filling the screen.
        //
        // The reveal never showed it because `RevealStage.apply` already calls
        // `layoutIfNeeded()` from inside its block for exactly this reason. The
        // flight has no such call, and every pose sets the card's bounds and
        // then calls this — so this is where the flight gets one.
        layoutDepartureCover()
        #if DEBUG
        // `-blend-frame-log`: whether the two operands are actually TRACKING the
        // card. A cover that stays put while the card's edge sweeps over it is
        // a truncation, and it looks exactly like an aspect-fill re-crop from
        // the outside — the numbers are the only way to tell them apart.
        if ProcessInfo.processInfo.arguments.contains("-blend-frame-log") {
            print("[blend-frame] t=\(String(format: "%.2f", t))"
                + " card=\(NSCoder.string(for: bounds))"
                + " arrival=\(NSCoder.string(for: imageView.frame))"
                + " departure=\(NSCoder.string(for: departureCoverView.frame))")
        }
        #endif
    }

    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        prepareVideoForFlight(destinationSize: destinationSize)
    }

    /// A pin lifts off the map, so its flight carries the same drop shadow.
    func applyZoomRestingShadow(to layer: CALayer) {
        Self.applyPinShadow(to: layer)
    }
}
