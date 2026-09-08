import CoreNavigation
import MediaCore
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
    /// ⚠️ RENDERED LARGE AND SCALED TO FILL, because the fallback stands in
    /// for a PICTURE.
    ///
    /// It used to be 18pt centred in the 44pt disc — about 40% of the diameter,
    /// leaving a ring of neutral ground around it. That reads as an icon
    /// sitting on a marker, and what it replaces is an author's face, which
    /// fills the marker edge to edge. A stand-in that occupies less than the
    /// thing it stands in for makes the marker change SIZE when the avatar
    /// arrives.
    ///
    /// The size here is only the raster's: the image view scales it to the
    /// bounds, so this is chosen for crispness on the largest thing the face
    /// ever becomes — a full-screen flight card — not for the 44pt pin.
    static let textSymbolPointSize: CGFloat = 96

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
    /// The animated-icon face, above the text face and below the ring. Hidden
    /// for every other face, so a recycled card must be told on every configure.
    private let iconFaceView = AnimatedIconView()
    /// The baked media preview, over the cover and under the live video surface.
    ///
    /// UNDER the video on purpose: if a real decoder ever attaches to this
    /// marker it is the better picture and must win, and the sheet is then the
    /// poster it replaces. The two are alternatives, not a stack — but the
    /// order decides which one a viewer sees if both are ever set, and leaving
    /// that to chance is how a marker ends up showing a frozen grid over live
    /// footage.
    private let previewSheetView = AnimatedIconView()
    /// Live-preview surface above the image, hidden until playback attaches.
    /// ⚠️ SILENCED. This surface is a marker's, and a flight borrows it — it is
    /// never the page the viewer lands on, which keeps its own indicator.
    let videoRenderView: VideoRenderView = {
        let view = VideoRenderView()
        view.suppressesCatchUpIndicator = true
        return view
    }()
    /// Hosts a live surface DONATED by the other screen — the departing page's
    /// own moving picture, which a dismissal's card carries home.
    ///
    /// ⚠️ A CONTAINER RATHER THAN THE SURFACE ITSELF, and the rule is stated on
    /// `ZoomFlightCard.setZoomLandingLiveMedia`: a live surface's alpha belongs
    /// to its own reveal machinery, which holds it at 0 until there is a frame
    /// to show. The blend needs an alpha of its own to fade that picture out
    /// across the return, so it gets the container's and the two drivers never
    /// meet on one property.
    private let donatedMediaHost = UIView()
    /// The surface inside that host. Weak: the flight owns the card, the card
    /// owns the host, and a finished flight must not keep a page's render
    /// surface alive.
    private weak var donatedSurface: VideoRenderView?

    /// The pin's border, drawn above the media so it survives live previews.
    /// The flight fades it out as the card leaves the pin (and back in on the
    /// way home).
    let ringView = UIView()

    #if DEBUG
    /// The stacked faces, BY NAME.
    ///
    /// ⚠️ The suites used to reach them as `card.subviews[4]`, and that made two
    /// completely different mistakes indistinguishable: adding a subview to this
    /// card reddened four tests whose subject is alpha, reporting a blend defect
    /// that did not exist. An index is not a name.
    var debugPreviewSheetFace: UIView { previewSheetView }
    var debugDepartureCover: UIView { departureCoverView }
    var debugLiveSurface: UIView { videoRenderView }
    var debugTextFace: UIView { textFaceView }
    /// The two things the disc can DRAW — the author's picture and the fallback
    /// mark. Its ground is the container and is deliberately not one of them.
    var debugTextFaceGlyph: UIView { textFaceView.debugGlyph }
    var debugTextFaceAvatar: UIView { textFaceView.debugAvatar }
    var debugIconFace: UIView { iconFaceView }
    /// Where a donated surface is hosted; its alpha is the blend's channel for
    /// the departing page's moving picture.
    var debugDonatedMediaHost: UIView { donatedMediaHost }
    #endif

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
        // ⚠️ ABOVE the arrival cover and BELOW the departure one, which is the
        // only position the blend law allows.
        //
        // Placed above the departure cover it stayed opaque while that cover
        // faded, hiding the blend completely — the flight would have handed over
        // to a picture nobody could see. It is the marker's OWN content, so it
        // belongs in the arrival stack: the departure picture fades over it,
        // exactly as it fades over the cover.
        previewSheetView.frame = bounds
        previewSheetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewSheetView.isHidden = true
        addSubview(previewSheetView)

        departureCoverView.frame = bounds
        departureCoverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(departureCoverView)

        videoRenderView.frame = bounds
        videoRenderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoRenderView.clipsToBounds = true
        videoRenderView.isHidden = true
        addSubview(videoRenderView)

        // Same z-position as the card's own surface — the two are alternatives,
        // never a stack — and above the departure still, which is only this
        // video's poster.
        donatedMediaHost.frame = bounds
        donatedMediaHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        donatedMediaHost.clipsToBounds = true
        donatedMediaHost.isHidden = true
        addSubview(donatedMediaHost)

        textFaceView.frame = bounds
        textFaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textFaceView.isHidden = true
        addSubview(textFaceView)

        iconFaceView.frame = bounds
        // ⚠️ NO autoresizing mask: `layoutSubviews` centres it at marker size.
        // A mark is line art authored for a 44pt face; the reveal lays its
        // stand-in out at the WINDOW's frame, so a filling icon was blown up to
        // several hundred points as the window opened.
        iconFaceView.isHidden = true
        addSubview(iconFaceView)

        // ⚠️ TOP-LEFT ANCHORED, and this is a REGISTER fix rather than a layout
        // preference.
        //
        // `card.frame = …` is `bounds` + `position`, and autoresizing turns it
        // into the same pair on every full-bleed child. The flight animates the
        // card with `UISpringTimingParameters(dampingRatio:initialVelocity:)`,
        // whose CGVector does not seed every property alike: `position` rides a
        // spring seeded with the vector, `bounds` one seeded with dx — which is
        // 0 here. Two curves through the same endpoints, so mid-flight a
        // child's top edge (`position.y - bounds.height/2`) is not the card's:
        // measured off the film at 4, 12, 14, 14, 12, 9 device px, zero at both
        // ends and humping in the middle, on the vertical axis only because dx
        // is 0.
        //
        // What showed in the gap was the card's own opaque ground, as a hard
        // black bar across the top inside the card's rounded mask — reported,
        // reasonably, as content escaping the transition window.
        //
        // With the anchor at the top-left a child's `position` is the constant
        // (0, 0): there is nothing on the positional channel to diverge, only
        // `bounds`, which is the card's own property and therefore its own
        // curve. Registration is then exact at every instant, whatever the
        // spring does.
        //
        // ⚠️ NOT for a view the FLIGHT poses by `center` — `videoRenderView`
        // and a donated surface are both centred by `ZoomFlight`, and under a
        // zero anchor `center` would move their top-left corner instead. Nor
        // for `iconFaceView`, which `layoutIconFace` centres by hand.
        for child in [imageView, previewSheetView, departureCoverView, donatedMediaHost,
                      textFaceView, videoRenderView] {
            child.layer.anchorPoint = .zero
            child.frame = bounds
        }

        ringView.isUserInteractionEnabled = false
        ringView.layer.borderWidth = Self.ringWidth
        ringView.layer.borderColor = ringColor.cgColor
        ringView.layer.cornerRadius = Self.cornerRadius
        ringView.layer.cornerCurve = .continuous
        // Same register fix as the covers above — and the ring is the view the
        // defect was measured on: mid-flight its top border sat 4.7pt below the
        // card's edge and its bottom border was pushed past the card's and
        // clipped, while its left and right borders stayed exactly put. A pure
        // vertical translation, which is what a `dx = 0` vector produces.
        ringView.layer.anchorPoint = .zero
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
    enum Face: Equatable, CaseIterable {
        /// The post's cover image, loaded into `imageView`.
        case media
        /// A symbol on a neutral ground: a text-only post has no cover to show.
        case text
        /// A text post wearing baked animated artwork instead of a face.
        ///
        /// Same box as `.text` and a DIFFERENT shape inside it: the artwork
        /// owns the whole square, alpha included, where an avatar is cropped to
        /// a disc. That is a product decision, and it also deletes the most
        /// expensive thing this feature could have done — a rounded mask on a
        /// layer whose contents change every frame costs an offscreen pass per
        /// marker per frame, which at 128 markers outweighs everything else in
        /// the design put together.
        case icon

        /// The marker's resting side. A text post carries no image worth
        /// showing at cover size, so its marker is deliberately smaller than a
        /// media pin — the map stays a field of photographs with text posts
        /// reading as lighter punctuation between them, rather than two equal
        /// squares competing for the same attention.
        var side: CGFloat {
            switch self {
            case .media: 56
            case .text, .icon: 44
            }
        }

        /// The resting corner radius. Half the side turns the square into a
        /// circle, which is what separates a text marker from a media one at a
        /// glance even before the glyph resolves.
        var cornerRadius: CGFloat {
            switch self {
            case .media: PinCardView.cornerRadius
            case .text: side / 2
            // THIS ONE LINE IS "no circle". The disc was never in the image or
            // in the face view — it is the card's own corner radius, and an
            // icon simply does not ask for it.
            case .icon: 0
            }
        }

        /// The face a pin wears.
        ///
        /// ⚠️ ONE helper, because resolving this inline is a ternary and a
        /// ternary does not fail to compile when a case is added. Six sites
        /// chose a face by hand before `.icon` existed — the pin, the cluster,
        /// two zoom sources, the flight card and the presentation choice — and
        /// every one of them would have kept building, silently never showing
        /// an icon on that surface.
        static func of(_ pin: MapPin) -> Face {
            if pin.hasAnimatedIcon { return .icon }
            return pin.isText ? .text : .media
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
        // ⚠️ THE GREY BOX. `imageView` is the cover host and it is never
        // hidden — it carries an opaque `.secondarySystemBackground` ground so
        // a letterboxed photograph reads as framed. Under the TEXT face that
        // ground is invisible because the disc above it is opaque; under an
        // icon, whose alpha IS its shape, it shows through as a grey square
        // exactly the size of the marker. An icon pin is a text post and has no
        // cover to host, so the whole layer goes away.
        imageView.isHidden = face == .icon
        // The media ground is black so a letterboxed cover reads as framed; a
        // text card's ground is the face's own tint, and the black would show
        // through its corner curve. An icon has NO ground at all — its alpha is
        // its shape, and any ground behind it would be the square the product
        // asked not to see.
        backgroundColor = face == .media ? .black : .clear
        // Hidden, not faded. The ring is a 2pt border on the card's rectangle;
        // at radius 0 behind transparent artwork it draws a visible box.
        // A preview belongs to a MEDIA face and nothing else — a recycled card
        // that last wore one must take it off, or a text marker inherits
        // somebody's footage.
        if face != .media { setPreviewSheet(nil) }
        setCornerRadius(face.cornerRadius)
        // ⚠️ AFTER `setCornerRadius`, which writes the ring's radius from the
        // face. Called before it, the floor's round ring was overwritten by the
        // icon face's 0 one line later — the assertion said 0 and the marker
        // drew a squircle around a disc.
        applyFaceVisibility()
        applyBlend()
    }

    /// The animated icon this card wears, with the phase that reproduces its
    /// exact frame. `nil` clears it.
    ///
    /// Art and phase travel TOGETHER, always: the flight card is a different
    /// `PinCardView` instance built from what the marker is wearing, and frame
    /// zero matches only if it is handed both.
    func setIcon(_ icon: (art: AnimatedIconArt, phase: Int)?) {
        wornIcon = icon
        iconFaceView.setArt(icon?.art, phase: icon?.phase ?? 0)
        // The floor moves with the art, so this has to re-run here as well as
        // in `setFace` — the two callers write the art on OPPOSITE sides of the
        // face (a pin faces then strips, a cluster strips then faces), so a
        // rule evaluated in only one of them is right for one of them.
        applyFaceVisibility()
        // And which unit the blend fades follows the same fact, so art landing
        // mid-flight has to re-point the channel rather than leave it fading a
        // view nobody can see.
        applyBlend()
    }

    /// Which unit of the card is drawn — and the ICON FACE'S FLOOR.
    ///
    /// ⚠️ `Face.of` promises `.icon` on the strength of an ID, and `.icon` hides
    /// the cover host because an icon's alpha IS its shape and the host's opaque
    /// ground would otherwise be a grey square. So an icon whose art never
    /// arrives — a cold catalogue, a decode failure, a memory-pressure eviction,
    /// or a fleet build where the id resolves to nothing — used to leave the
    /// card drawing NOTHING AT ALL.
    ///
    /// The fix is not to make the face follow the art. The face is read from
    /// outside (the flight's resting radius, the reveal origin, the cluster's
    /// idempotence key) and, decisively, `MapClusterAnnotationView` gates the
    /// icon FETCH on `face == .icon` — so a face derived from a cold cache would
    /// never ask for the artwork, store `.text` as its key, and compare equal
    /// forever after. The icon would never appear at all, and a cold cache is
    /// every first paint.
    ///
    /// Instead the face stays a pure function of the model and gains a FLOOR:
    /// under `.icon` with no art the text disc shows, and it goes the instant
    /// art lands. Mutually exclusive, never stacked — a disc left underneath
    /// would show through the icon's own alpha as the circle the product asked
    /// not to see.
    private func applyFaceVisibility() {
        let iconIsBare = face == .icon && wornIcon == nil
        // A reveal may have borrowed the disc as the icon's container; re-facing
        // or re-dressing the card takes it back.
        textFaceView.alpha = 1
        textFaceView.isHidden = !(face == .text || iconIsBare)
        iconFaceView.isHidden = face != .icon
        // ⚠️ AN ICON'S FACE IS THE ICON, and the cover under it is not part of
        // it. The rule was never written down because at rest it cannot be
        // seen: the card is 44pt and the mark fills it exactly.
        //
        // A REVEAL WINDOW is not 44pt. `layoutIconFace` deliberately caps the
        // mark at its authored size and centres it, so in a window several
        // hundred points across everything around the mark is whatever else the
        // card is holding — and `MapPinRevealSource.marker` dresses every
        // stand-in with `imageView.image = cover`, an icon post's wire
        // thumbnail included. Filmed as a photograph appearing from nowhere
        // behind the icon as the window closed.
        //
        // ⚠️ `!= .media`, NOT `== .icon`. The first cut of this rule named the
        // face that was filmed, and a rule that names one case is a rule that
        // has to be rediscovered for the next one: a TEXT face carries the same
        // cover, and it is hidden there only by an opaque disc that happens to
        // fill the window. The cover is `.media`'s content, and nothing else's.
        imageView.isHidden = face != .media
        // The ring belongs to the disc, so it follows the disc rather than the
        // face: a bare icon wearing the text floor should look like a text
        // marker, ring included.
        ringView.isHidden = face == .icon && !iconIsBare
        // ⚠️ AND IT MUST TAKE THE DISC'S SHAPE. `ringView` draws the marker's
        // border on the CARD's rectangle, which under `.icon` is a square with
        // radius 0 — that is the whole meaning of "no circle". Left alone it
        // framed the round floor in a squircle: rounded, obviously wrong, and
        // invisible to a test that only asked whether the face was hidden. Only
        // the simulator showed it.
        //
        // `.circular`, because a `.continuous` curve at half the side is a
        // superellipse rather than a circle.
        // The floor and the ring both take the CARD's radius when it has one —
        // in a reveal window that is the mask's, which grows toward the page's,
        // so the stand-in FILLS the window instead of being an ellipse inside
        // it. Only when the card is square (an icon at rest, radius 0 by
        // design) does the floor supply its own disc.
        let cardRadius = layer.cornerRadius
        let floorRadius = cardRadius > 0 ? cardRadius : min(bounds.width, bounds.height) / 2
        textFaceView.floorCornerRadius = (iconIsBare || face == .text) ? floorRadius : 0
        // ⚠️ ONLY the square card overrides the ring. Everywhere else the ring
        // already wears whatever `setCornerRadius` last wrote — in a reveal
        // window that is the mask's radius, growing toward the page's — and
        // re-asserting `face.cornerRadius` here would undo it one line later.
        if iconIsBare, cardRadius == 0 {
            ringView.layer.cornerRadius = floorRadius
            ringView.layer.cornerCurve = .circular
        } else {
            // The card's LIVE radius, not the face's constant: in a reveal
            // window that is the mask's, and asserting the face's would undo
            // what `setCornerRadius` wrote one line earlier. At rest the two
            // are the same value, so the dressed icon still goes back to 0.
            ringView.layer.cornerRadius = cardRadius
            ringView.layer.cornerCurve = face == .text ? .circular : .continuous
        }
    }

    /// Read back rather than remembered elsewhere — the same reason
    /// `textAvatar` exists: it is what keeps the flying card and the marker the
    /// same picture.
    private(set) var wornIcon: (art: AnimatedIconArt, phase: Int)?

    /// Re-installs playback after anything that strips animations: a foreground
    /// transition does, and so does a motion-policy change.
    func reinstallIconPlayback() {
        iconFaceView.reinstall()
    }

    /// The baked preview this card is playing, with its phase. `nil` clears it.
    ///
    /// Phase comes from the pin's identity, so two markers showing the same clip
    /// are on different frames — a field of identical previews all in lockstep
    /// reads as one video tiled, not as many posts.
    func setPreviewSheet(_ preview: (art: AnimatedIconArt, phase: Int)?) {
        wornPreview = preview
        previewSheetView.setArt(preview?.art, phase: preview?.phase ?? 0)
        previewSheetView.isHidden = preview == nil
        // ⚠️ THE COVER UNDER A PREVIEW IS THE PREVIEW'S OWN FIRST FRAME.
        //
        // The fallback ladder for a video marker is: the sheet animating, then
        // the sheet's frame zero, then whatever cover the wire gave. The middle
        // rung did not exist — under Reduce Motion, or while the catalogue was
        // still resolving, or after an eviction, the marker showed a PHOTOGRAPH
        // and then swapped to a clip, which is two claims about one post and
        // the swap is visible. Frame zero is the same picture the animation
        // starts from, so stopping looks like pausing rather than changing.
        if let art = preview?.art, let frameZero = art.firstFrame() {
            imageView.image = frameZero
        }
    }

    private(set) var wornPreview: (art: AnimatedIconArt, phase: Int)?

    func reinstallPreviewPlayback() {
        previewSheetView.reinstall()
    }

    #if DEBUG
    var presentedIconTick: Double? { iconFaceView.presentedTick ?? previewSheetView.presentedTick }
    /// The icon face's floor, read back for the tests that pin it.
    var debugTextFaceIsVisible: Bool { !textFaceView.isHidden }
    /// The face worn, and whether it is standing on the floor.
    var debugFaceName: String {
        switch face {
        case .media: "media"
        case .text: "text"
        case .icon: wornIcon == nil ? "icon-BARE" : "icon"
        }
    }
    var debugIconFaceIsVisible: Bool { !iconFaceView.isHidden }
    var isPlayingPreviewSheet: Bool { wornPreview != nil }

    /// The preview sheet's presentation-layer fingerprint, and ONLY the preview's.
    ///
    /// `presentedIconTick` falls back to the icon face first, so on a marker
    /// wearing both it would report the icon's motion as though it were the
    /// sheet's. The worst-case measurement turns on telling those apart.
    var presentedPreviewTick: Double? { previewSheetView.presentedTick }
    #endif

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
        // ⚠️ A DONATED SURFACE IS A BLEND OPERAND IN ITS OWN RIGHT, which is why
        // this sits ABOVE the guard rather than inside a branch of it.
        //
        // The guard below asks whether a departure STILL was handed in, and on
        // a dismissal that lands where it took off the answer is no — one post,
        // one picture, nothing to blend. That reasoning was complete only while
        // the card's pictures were stills. A donated surface is the departing
        // PAGE in motion, arriving over the marker's own cover: it must fade out
        // across the return, or the video is still at full opacity when the card
        // reaches a marker showing something else, and the swap is a cut.
        //
        // Inert on every other flight: the host is hidden and its alpha is not
        // drawn.
        donatedMediaHost.alpha = 1 - blend
        guard departureCoverView.image != nil else {
            // No second operand. Every channel back to its resting value, which
            // is the un-blended card exactly as it was.
            departureCoverView.alpha = 1
            videoRenderView.alpha = 1
            textFaceView.alpha = 1
            iconFaceView.alpha = 1
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
        case .icon:
            // Same law, same shape: the icon face is ONE unit and fades as one.
            //
            // ⚠️ Never the plate and the mark separately. The mark is line art
            // by nature, and a mark drifting out from under a still-visible
            // ground is precisely the two half-drawn overlays the note above
            // rules out. `AnimatedIconView` is a single view for this reason.
            departureCoverView.alpha = 1
            videoRenderView.alpha = 1
            // ⚠️ WHICHEVER UNIT IS ACTUALLY DRAWN is the one that fades. With
            // art that is the icon; standing on the floor it is the disc,
            // exactly as under `.text`. Fading only `iconFaceView` left a bare
            // icon's disc opaque at 1 for the whole flight while an invisible
            // face faded in behind it — so a dismissal onto a marker whose
            // artwork had not resolved COVERED the departing page in one step
            // instead of crossfading over it. That is the arrival reading
            // itself: what the viewer sees must be what the blend moves.
            let isBare = wornIcon == nil
            iconFaceView.alpha = isBare ? 1 : blend
            textFaceView.alpha = isBare ? blend : 1
        }
    }

    /// Rounds the card and its ring together. Both properties are
    /// UIView-animatable, so calling this inside an animation block sweeps the
    /// radius smoothly (pin 12pt ↔ device display corners).
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDepartureCover()
        layoutIconFace()
    }

    /// The mark keeps its authored size and stays centred; only the CONTAINER
    /// grows.
    ///
    /// A photograph can be scaled to any window because it is a picture of
    /// something. A mark cannot: it is line art drawn for a 44pt face, and the
    /// reveal — which lays its stand-in out at the window's own frame — was
    /// blowing it up to fill several hundred points as the window opened.
    /// Capping it at the icon face's side means the window opens AROUND a mark
    /// that was already legible when it left the marker.
    private func layoutIconFace() {
        let side = min(Face.icon.side, min(bounds.width, bounds.height))
        iconFaceView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        iconFaceView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
        ringView.layer.cornerRadius = radius
        // The floor tracks the card. The reveal drives this every frame with
        // the mask's radius, and a floor that kept the marker's disc while the
        // card opened into a window is the ellipse-in-a-rect that was filmed.
        applyFaceVisibility()
    }

    /// The soft shadow that lifts a pin card off the map — one definition used
    /// by both the annotation view and the flight's stand-in shadow.
    ///
    /// ⚠️ Takes the FACE, and must be re-applied on every face change rather
    /// than once at init: these views are recycled across faces, so a card that
    /// last wore an icon would keep its shadow setting for the photograph that
    /// dequeues it next.
    ///
    /// An icon gets none. This shadow is PATHLESS, so Core Animation derives
    /// its silhouette from the layer's composited alpha — free today only
    /// because a marker's contents never change, and re-derived every frame on
    /// every marker the moment they do. At 128 markers that is the single
    /// largest cost this feature could incur. A rectangular `shadowPath` is not
    /// the fix either: behind transparent artwork it draws a visible box.
    /// ⚠️ `hasArt` matters only for `.icon`, and it is the difference between a
    /// lift and a smear. An icon gets NO shadow because a pathless shadow is
    /// re-derived from the composited alpha every frame once the contents
    /// animate — the largest cost this feature could incur — and a rectangular
    /// path behind transparent artwork draws a box. Neither objection applies to
    /// a BARE icon: it is drawing the text disc, which is opaque and still, so
    /// it should lift exactly like the text marker it is standing in for.
    /// Suppressing the shadow there made the fallback look sunken into the map.
    static func applyPinShadow(to layer: CALayer, face: Face = .media, hasArt: Bool = true) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = (face == .icon && hasArt) ? 0 : 0.25
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
        // ⚠️ NOTHING TO PREPARE ANY MORE, and the empty body is the fix.
        //
        // This used to lay the surface out at the PAGE's size with autoresizing
        // off, so the flight could drive it by transform and centre. That is
        // the contract behind `zoomLiveMediaTracksCardBounds == false`, and it
        // has a defect this card cannot live with: those poses are computed
        // from `card.layer.presentation()` on a display link, so the surface
        // renders ONE FRAME BEHIND the card. Measured on the present, surface
        // width against the card's in the same frame: -47.6%, -34.9%, -13.8%,
        // -4.0%, -1.1%, 0 — the deficit tracks how fast the card is growing.
        //
        // The viewer sees the card's cover in the strip the video has not
        // reached yet: a hard vertical seam between a sharp video on the left
        // and a blurred still on the right, filmed and reported as the player
        // being badly attached to its container.
        //
        // The surface is full-bleed with an autoresizing mask instead, so
        // CoreAnimation sizes it from the card's own bounds — the same property
        // on the same curve, in the same frame — and `resizeAspectFill`
        // recomputes the crop continuously as the card morphs.
        let surface: UIView = donatedSurface ?? videoRenderView
        surface.transform = .identity
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.frame = (surface === videoRenderView ? self : donatedMediaHost).bounds
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
    /// The shape the floor clips itself to — SET BY THE CARD, not assumed.
    ///
    /// ⚠️ It was `min(width, height) / 2`, unconditionally. Right at 44x44,
    /// where the floor stands in for a text marker and must be a disc. Wrong
    /// everywhere else, and the reveal is everywhere else: `RevealTransition`
    /// lays the stand-in out at the WINDOW's frame, so the same view found
    /// itself 300pt wide by 700 tall and clipped to a 150pt radius — a vertical
    /// capsule, which is exactly what a viewer filmed. The card knows its own
    /// radius; the floor's job is to agree with it.
    var floorCornerRadius: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = floorCornerRadius
        // `.circular`, not `.continuous`: at a radius of half the side the
        // latter is a superellipse rather than a circle.
        layer.cornerCurve = .circular
        layer.masksToBounds = floorCornerRadius > 0
    }

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
        // Fills the disc exactly as `avatar` does, so the two are the same
        // shape and the swap is a change of picture rather than of layout.
        glyph.contentMode = .scaleAspectFill
        glyph.clipsToBounds = true
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
    #if DEBUG
    /// The two things the disc can DRAW, by name — the ground it sits on is the
    /// container and is deliberately not one of them.
    var debugGlyph: UIView { glyph }
    var debugAvatar: UIView { avatar }
    #endif

    func setContentOpacity(_ alpha: CGFloat) {
        // ⚠️ BOTH, and for a long time it was only the glyph.
        //
        // The disc draws whichever of the two it has — the author's picture
        // when one has loaded, the fallback mark when none has. Fading one of
        // them is fading the content only in the case that happens to be
        // showing, which is the definition of a rule that works until it does
        // not.
        //
        // It did not, twice over. A TEXT marker's reveal kept the author's
        // photograph at full opacity while the ring, the cover and the glyph
        // all left. And an ICON marker BORROWS this disc as its container
        // (`PinCardView.setContentOpacity`) and asks for its content to be
        // silent — so a post with no media at all closed onto a photograph,
        // which is what was filmed and reported as impossible. It was the
        // AUTHOR's face, riding in on a channel that had never been told to
        // take it.
        glyph.alpha = alpha
        avatar.alpha = alpha
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
        // ⚠️ UNDER A DRESSED ICON THIS CHANNEL MOVES NOTHING BUT THE FURNITURE.
        //
        // A mark is not a picture of a place — it is the thing the author chose
        // to say, and it reads at 44pt or not at all. So it does not grow with
        // the window and it does not fade in: it is already drawn, centred, at
        // its authored size, from the first frame, and there is nothing around
        // it. A window closing onto such a marker ends on the map.
        //
        // ⚠️ IT USED TO BORROW THE TEXT DISC AS A CONTAINER — "what arrives
        // gradually is the DISC AROUND IT" — and that borrow was a SECOND GREY
        // of the very colour this route exists to refuse.
        //
        // The lines that stood here un-hid `textFaceView` — `.systemBackground`
        // wrapped around a full-bleed `.secondarySystemBackground` disc, given
        // `floorCornerRadius = 0` under a dressed icon, i.e. a hard opaque
        // SQUARE at the window's own size — and drove its alpha with this
        // channel. `applyFaceVisibility` sets the same `isHidden` back to true,
        // so which of the two won was a CALL-ORDER ACCIDENT that differed per
        // leg: the present and the chevron run `RevealStage.apply` last and the
        // disc stayed hidden, the finger drag runs `setContentOpacity` last and
        // it did not. The "container assembling itself around the mark" this
        // comment used to promise was therefore never delivered on any leg —
        // it only ever appeared as a grey block, on one.
        //
        // `MapPinRevealSource` had already ruled the other way one commit
        // earlier: a dressed icon has no ground, so a window closing onto it
        // must end on nothing. One driver for `textFaceView.isHidden` now, and
        // it is `applyFaceVisibility`.
        if face == .icon, wornIcon != nil {
            iconFaceView.alpha = 1
            ringView.alpha = alpha
            imageView.alpha = alpha
            return
        }
        textFaceView.alpha = 1
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

    /// The surface the flight poses — a donated one first, because when a page
    /// has handed its picture over that IS what the card is flying.
    var zoomLiveMediaSurface: UIView? {
        if let donatedSurface, !donatedMediaHost.isHidden { return donatedSurface }
        return videoRenderView.isHidden ? nil : videoRenderView
    }

    var zoomLiveMediaNativeSize: CGSize? {
        (donatedSurface ?? videoRenderView).nativeVideoSize
    }

    /// The pin's own thumbnail — autoresized to the card, aspect-filled. On a
    /// present this is what the viewer is looking at for most of the flight.
    var zoomCoverSurface: UIView? { imageView }

    var zoomLiveMediaContentRect: CGRect? {
        (donatedSurface ?? videoRenderView).debugVideoRect
    }

    /// The whole media chain in one line, for `-grab-geometry` — see the probe
    /// in `ZoomFlight.poseFloating`. CoreNavigation cannot ask a
    /// `VideoRenderView` anything directly, so the card reports it.
    var zoomLiveMediaDebugState: String {
        let surface: UIView? = donatedSurface ?? (videoRenderView.isHidden ? nil : videoRenderView)
        let host = donatedMediaHost
        let native = (donatedSurface ?? videoRenderView).nativeVideoSize
        return "host=\(NSCoder.string(for: host.bounds))"
            + " hostHidden=\(host.isHidden ? "Y" : "n")"
            + " surface=\(surface.map { NSCoder.string(for: $0.frame) } ?? "nil")"
            + " sBounds=\(surface.map { NSCoder.string(for: $0.bounds) } ?? "-")"
            + " sXf=\(surface.map { NSCoder.string(for: $0.transform) } ?? "-")"
            + " sAnchor=\(surface.map { NSCoder.string(for: $0.layer.anchorPoint) } ?? "-")"
            + " donated=\(donatedSurface == nil ? "n" : "Y")"
            + " native=\(native.map { NSCoder.string(for: $0) } ?? "nil")"
            // ⚠️ THE COVER, BESIDE THE SURFACE, because during a present the
            // cover IS the picture and the surface is not yet.
            //
            // Measured: a scale sweep on the growing card showed the visible
            // content tracking the card exactly (best match at s=1.00), while
            // the sampler reported the live surface presenting the page's full
            // width from the second frame. Both readings were right, about
            // different objects — and a sampler that watches only the invisible
            // one will approve a change that makes the visible one jump.
            + " cover=\(NSCoder.string(for: imageView.bounds.size))"
            + " coverPres=\(imageView.layer.presentation().map { NSCoder.string(for: $0.bounds.size) } ?? "nil")"
            + " coverHidden=\(imageView.isHidden ? "Y" : "n")"
            + String(format: " coverAlpha=%.2f", imageView.alpha)
            + " coverAnims=\(imageView.layer.animationKeys()?.count ?? 0)"
            // And the player's own container and gravity, so "the surface is in
            // the wrong place" can be told apart from "the surface is right and
            // the video inside it is drawn somewhere else".
            + " layer=\((surface as? VideoRenderView)?.debugLayerClass ?? "-")"
            + " gravity=\((surface as? VideoRenderView)?.debugVideoGravity ?? "-")"
            + " videoRect=\((surface as? VideoRenderView)?.debugVideoRect.map { NSCoder.string(for: $0) } ?? "-")"
            + " onHost=\(surface?.superview === donatedMediaHost ? "Y" : "n")"
            + " onCard=\(surface?.superview === self ? "Y" : "n")"
            // The two that actually decide what is on screen.
            + " sPres=\(surface?.layer.presentation().map { NSCoder.string(for: $0.bounds) } ?? "nil")"
            + " sAnim=[\(surface?.layer.animationKeys()?.joined(separator: ",") ?? "-")]"
            + " hPres=\(host.layer.presentation().map { NSCoder.string(for: $0.bounds) } ?? "nil")"
            + " hAnim=[\(host.layer.animationKeys()?.joined(separator: ",") ?? "-")]"
    }

    /// Same rule as the grid's flight card: a pin flying without live media
    /// shows its cover, which is always drawing; one flying with live media is
    /// only "drawing" while that surface is actually visible.
    /// ⚠️ TRUE, so the flight leaves this surface's transform and centre alone.
    ///
    /// The alternative — a surface laid out at page size and driven by a
    /// uniform scale — is posed from `card.layer.presentation()` on a display
    /// link, which is a frame behind by construction. On a card that grows from
    /// 56pt to a full page in 420ms that lag was measured at up to 47.6% of the
    /// card's width, and what shows in the gap is the card's own cover: the
    /// vertical seam between sharp video and blurred still that was filmed.
    ///
    /// Tracking the card's bounds hands the sizing to CoreAnimation, which
    /// applies it in the same frame and on the same curve as the card's own
    /// bounds, and lets `resizeAspectFill` recompute the crop at every instant
    /// rather than showing the page's crop at every size.
    var zoomLiveMediaTracksCardBounds: Bool { true }

    var zoomLiveMediaIsDrawing: Bool {
        if let donatedSurface, !donatedMediaHost.isHidden {
            return donatedSurface.isRenderingVisibly
        }
        return videoRenderView.isHidden ? true : videoRenderView.isRenderingVisibly
    }

    /// Takes a surface the other screen is ALREADY rendering, in place of
    /// mirroring one of this card's own.
    ///
    /// ⚠️ THIS WAS MISSING, and its absence was silent. `ZoomFlight.build` tries
    /// the donation FIRST on every leg, and `ZoomFlightCard` defaults this to
    /// nothing — so on a dismissal the feed page handed over a surface already
    /// carrying a decoded frame and the card dropped it on the floor, then fell
    /// through to mirroring a second layer that had none. What the viewer saw
    /// was the grab flying a still.
    ///
    /// No poster: the surface is already showing video, and a poster over it
    /// could only be a chance to flash. `revealOnFirstFrame` — not
    /// `isHidden = false` — because a surface with nothing to show must not
    /// replace the cover underneath it, which is the picture the viewer has.
    func adoptZoomLiveMediaView(_ view: UIView) {
        guard let surface = view as? VideoRenderView else { return }
        donatedSurface = surface
        surface.frame = donatedMediaHost.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.layer.anchorPoint = .zero
        surface.frame = donatedMediaHost.bounds
        surface.clipsToBounds = true
        donatedMediaHost.addSubview(surface)
        donatedMediaHost.isHidden = false
        // The card may already be part-way through a blend when this arrives.
        applyBlend()
        surface.revealOnFirstFrame()
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(videoRenderView) else { return }
        // Poster covers the (usually sub-frame) gap until the mirrored layer
        // reports its first frame.
        videoRenderView.setPoster(imageView.image)
        videoRenderView.isHidden = false
    }

    /// The arriving page's picture comes UP over the marker's, which stays
    /// fully drawn underneath — this card's cover is the source content.
    ///
    /// ⚠️ THE POSTER HAS TO GO FIRST, and it is not an optimisation. The poster
    /// this card just seeded is a COPY of the cover directly behind the
    /// surface, so fading it in changes nothing on screen: the transition would
    /// look exactly as it did before, and the video would still arrive as a cut
    /// when the poster retires. What must fade in is the VIDEO.
    ///
    /// Nothing is shown until there is a decoded frame to show; if none ever
    /// arrives the surface simply stays at zero and the card lands on its
    /// cover, which is the picture the viewer was already looking at.
    func fadeInAdoptedLiveMedia(over duration: TimeInterval) {
        videoRenderView.setPoster(nil)
        videoRenderView.fadeInOnFirstFrame(over: duration)
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
    ///
    /// ⚠️ Its OWN face, not the `.media` default. A flying icon was getting the
    /// media shadow — a box behind transparent artwork — because the argument
    /// was simply never passed, and the default is the one face for which the
    /// answer is always wrong.
    func applyZoomRestingShadow(to layer: CALayer) {
        Self.applyPinShadow(to: layer, face: face, hasArt: wornIcon != nil)
    }
}
