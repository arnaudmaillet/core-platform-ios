import MediaPlayback
import UIKit

/// One overlay on the canvas: its picture, turned, sized and placed where its
/// placement says, and the gestures that move it.
///
/// ⚠️ **THE PICTURE IS THE RASTERISER'S, SO WHAT IS DRAGGED IS WHAT IS
/// PUBLISHED.** `OverlayRasterizer.image(for:outputWidth:scale:)` draws the
/// overlay for a picture as wide, in pixels, as the page's picture is on
/// screen; the view shows that image at the screen's scale and turns it. The
/// export composites the very same image at the film's width.
///
/// ⚠️ **AND A FALLBACK WHILE THE RASTERISER CANNOT DRAW IT.** Until the overlay
/// rasteriser lands (slice S3) `image(for:)` answers nil, and text is lettered
/// here with UIKit in the same face, ink and size rule instead — close, not
/// identical. A sticker has no picture of its own here: its frames come from
/// the sticker slice (S10), which hosts them in this view.
///
/// ⚠️ **SIZED AT PLACEMENT SCALE 1, SCALED BY ITS TRANSFORM.** The bounds are
/// the overlay's base size and `transform` carries the pinch and the turn, so a
/// pinch moves nothing but the transform; the picture is drawn again at the new
/// scale when the fingers lift, which keeps a word pinched large sharp.
///
/// ⚠️ **ITS TAPS COME BEFORE THE CANVAS'S.** A tap on an overlay selects it; the
/// canvas's own tap plays and pauses the clip. A recogniser that recognises
/// prevents an ancestor's only when UIKit happens to ask it first, so the item
/// says it outright: every tap recogniser above it must wait for this one to
/// fail (`shouldBeRequiredToFailBy`). A tap on an overlay never toggles
/// playback; a tap beside one still does.
@MainActor
final class MediaOverlayItemView: UIView, UIGestureRecognizerDelegate {
    typealias Rasterize = @MainActor (FrameOverlay.Content, CGFloat, Double) -> CGImage?

    /// Where a gesture is in its life.
    enum Phase {
        case began, changed, ended
    }

    /// The smallest target a finger is offered, in screen points.
    static let minimumTarget: CGFloat = 44

    private(set) var overlay: FrameOverlay
    var id: String { overlay.id }

    /// Who moves it. The layer the view sits in.
    weak var handler: MediaOverlayLayerView?

    private let rasterize: Rasterize
    private let picture = UIImageView()
    private let lettering = UILabel()
    private let outline = CAShapeLayer()

    /// The width of the page's picture, in points, the view was last laid for.
    private var mediaWidth: CGFloat = 0
    private var screenScale: CGFloat = 2
    /// The scale the current picture was drawn at.
    private var drawnScale: Double = 1
    private(set) var hasRasterPicture = false

    private(set) var isSelected = false

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var doubleTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        tap.numberOfTapsRequired = 2
        return tap
    }()

    init(
        overlay: FrameOverlay,
        rasterize: @escaping Rasterize = { OverlayRasterizer.image(for: $0, outputWidth: $1, scale: $2) }
    ) {
        self.overlay = overlay
        self.rasterize = rasterize
        super.init(frame: .zero)
        backgroundColor = .clear
        picture.contentMode = .scaleToFill
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(picture)
        lettering.numberOfLines = 0
        lettering.clipsToBounds = true
        lettering.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(lettering)
        outline.fillColor = nil
        outline.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        outline.lineDashPattern = [6, 4]
        outline.isHidden = true
        layer.addSublayer(outline)

        for recogniser in [pan, pinch, rotation, tap] as [UIGestureRecognizer] {
            recogniser.delegate = self
            addGestureRecognizer(recogniser)
        }
        pan.maximumNumberOfTouches = 2
        // ⚠️ **ONLY TEXT IS EDITED BY A DOUBLE TAP, SO ONLY TEXT MAKES A TAP WAIT
        // FOR ONE.** A sticker that made its tap wait for a double tap nobody
        // handles would select a quarter of a second late for nothing.
        if case .text = overlay.content {
            doubleTap.delegate = self
            addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Drawing

    /// Takes a new value for the overlay; draws again only when its content
    /// changed.
    func update(_ next: FrameOverlay) {
        let contentChanged = next.content != overlay.content
        overlay = next
        if contentChanged || next.placement.scale != drawnScale { draw() }
        place()
        describe()
    }

    /// Moves the view to `placement` — live, under a finger, when `redraw` is
    /// false; drawn again at the new scale when it is true.
    func setPlacement(_ placement: OverlayPlacement, redraw: Bool) {
        overlay.placement = placement
        if redraw, placement.scale != drawnScale { draw() }
        place()
    }

    /// Lays the view for a picture drawn in `mediaRect`, at `screenScale`.
    func lay(in mediaRect: CGRect, screenScale: CGFloat) {
        let widthChanged = abs(mediaRect.width - mediaWidth) > 0.5 || screenScale != self.screenScale
        self.screenScale = screenScale
        mediaWidth = mediaRect.width
        if widthChanged || (!hasRasterPicture && lettering.attributedText == nil) { draw() }
        place(in: mediaRect)
    }

    private var mediaRect: CGRect = .zero

    /// Puts the view where the placement says, turned and scaled.
    func place(in rect: CGRect? = nil) {
        if let rect { mediaRect = rect }
        guard mediaRect.width > 0 else { return }
        transform = .identity
        center = MediaOverlayGeometry.point(for: overlay.placement.centre, in: mediaRect)
        transform = MediaOverlayGeometry.transform(for: overlay.placement)
    }

    /// Draws the overlay's picture at its current scale.
    func draw() {
        guard mediaWidth > 0 else { return }
        let scale = overlay.placement.scale
        drawnScale = scale
        if let image = rasterize(overlay.content, mediaWidth * screenScale, scale) {
            hasRasterPicture = true
            picture.isHidden = false
            lettering.isHidden = true
            picture.image = UIImage(cgImage: image, scale: screenScale, orientation: .up)
            let drawn = CGSize(width: CGFloat(image.width) / screenScale, height: CGFloat(image.height) / screenScale)
            setBase(CGSize(width: drawn.width / scale, height: drawn.height / scale))
        } else {
            hasRasterPicture = false
            picture.image = nil
            picture.isHidden = true
            lettering.isHidden = false
            setBase(letter())
        }
    }

    private func setBase(_ size: CGSize) {
        let saved = transform
        transform = .identity
        bounds = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        picture.frame = bounds
        lettering.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -4, dy: -4), cornerRadius: 6).cgPath
        transform = saved
    }

    /// The UIKit lettering the view falls back on, sized at placement scale 1.
    private func letter() -> CGSize {
        lettering.backgroundColor = .clear
        lettering.layer.cornerRadius = 0
        switch overlay.content {
        case .text(let text):
            let size = MediaOverlayGeometry.textSizeFraction * mediaWidth
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = text.alignment.nsAlignment
            var attributes: [NSAttributedString.Key: Any] = [
                .font: text.font.editorFont(ofSize: size), .paragraphStyle: paragraph
            ]
            switch text.background {
            case .none:
                attributes[.foregroundColor] = text.colour.uiColor
            case .highlight:
                attributes[.backgroundColor] = text.colour.uiColor
                attributes[.foregroundColor] = text.colour.isLight ? UIColor.black : UIColor.white
            case .box:
                attributes[.foregroundColor] = text.colour.uiColor
                lettering.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                lettering.layer.cornerRadius = size * 0.3
            }
            lettering.attributedText = NSAttributedString(string: text.text, attributes: attributes)
            let fitted = lettering.sizeThatFits(CGSize(width: mediaWidth * 0.9, height: .greatestFiniteMagnitude))
            let pad = size * 0.4
            return CGSize(width: fitted.width + 2 * pad, height: fitted.height + pad)
        case .emoji(let emoji):
            let side = MediaOverlayGeometry.emojiSizeFraction * mediaWidth
            lettering.attributedText = NSAttributedString(
                string: emoji,
                attributes: [.font: UIFont.systemFont(ofSize: side * 0.8),
                             .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()]
            )
            return CGSize(width: side, height: side)
        case .sticker:
            // The sticker slice (S10) hosts the sticker's frames here.
            lettering.attributedText = NSAttributedString(string: "")
            let side = MediaOverlayGeometry.emojiSizeFraction * mediaWidth
            return CGSize(width: side, height: side)
        }
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        outline.isHidden = !selected
        describe()
    }

    // MARK: - Touches

    /// ⚠️ **AT LEAST 44 POINTS ON SCREEN, WHATEVER THE PINCH LEFT.** The bounds
    /// are in the view's own, scaled space, so the margin is worked out in
    /// screen points and divided back by the scale.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let scale = max(CGFloat(overlay.placement.scale), 0.01)
        let wide = max(0, (Self.minimumTarget / scale - bounds.width) / 2)
        let tall = max(0, (Self.minimumTarget / scale - bounds.height) / 2)
        return bounds.insetBy(dx: -wide, dy: -tall).contains(point)
    }

    @objc private func panned(_ recogniser: UIPanGestureRecognizer) {
        guard let handler, let phase = Self.phase(of: recogniser) else { return }
        let delta = recogniser.translation(in: handler)
        recogniser.setTranslation(.zero, in: handler)
        handler.item(self, panned: phase, by: delta, at: recogniser.location(in: handler))
    }

    @objc private func pinched(_ recogniser: UIPinchGestureRecognizer) {
        guard let handler, let phase = Self.phase(of: recogniser) else { return }
        let factor = Double(recogniser.scale)
        recogniser.scale = 1
        handler.item(self, pinched: phase, by: factor)
    }

    @objc private func rotated(_ recogniser: UIRotationGestureRecognizer) {
        guard let handler, let phase = Self.phase(of: recogniser) else { return }
        let radians = Double(recogniser.rotation)
        recogniser.rotation = 0
        handler.item(self, rotated: phase, by: radians)
    }

    @objc private func tapped() { handler?.itemTapped(self) }

    @objc private func doubleTapped() { handler?.itemWantsEditing(self) }

    private static func phase(of recogniser: UIGestureRecognizer) -> Phase? {
        switch recogniser.state {
        case .began: .began
        case .changed: .changed
        case .ended, .cancelled, .failed: .ended
        default: nil
        }
    }

    /// Pan, pinch and turn at once — with each other, and with nothing else.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let together: [UIGestureRecognizer] = [pan, pinch, rotation]
        return together.contains(gestureRecognizer) && together.contains(other)
    }

    /// Every tap ABOVE this view — the canvas's play/pause, chiefly — waits for
    /// this view's taps to fail. See the type's note.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === tap || gestureRecognizer === doubleTap,
              other is UITapGestureRecognizer,
              let owner = other.view, owner !== self
        else { return false }
        return isDescendant(of: owner)
    }

    // MARK: - VoiceOver

    /// What VoiceOver says, and what it offers while the overlay can be edited.
    func describe() {
        switch overlay.content {
        case .text(let text): accessibilityLabel = "Text, \(text.text)"
        case .emoji(let emoji): accessibilityLabel = "Emoji, \(Self.name(of: emoji))"
        case .sticker(let id): accessibilityLabel = "Sticker, \(id)"
        }
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        guard handler?.isEditable == true else {
            accessibilityCustomActions = nil
            return
        }
        var actions: [UIAccessibilityCustomAction] = []
        if case .text = overlay.content {
            actions.append(action("Edit") { $0.handler?.itemWantsEditing($0) })
        }
        actions += [
            action("Delete") { $0.handler?.itemWantsDeleting($0) },
            action("Bring to front") { $0.handler?.itemWantsFront($0) },
            action("Bigger") { $0.handler?.item($0, nudged: .bigger) },
            action("Smaller") { $0.handler?.item($0, nudged: .smaller) },
            action("Rotate left") { $0.handler?.item($0, nudged: .turnLeft) },
            action("Rotate right") { $0.handler?.item($0, nudged: .turnRight) },
            action("Move up") { $0.handler?.item($0, nudged: .move(dx: 0, dy: -0.05)) },
            action("Move down") { $0.handler?.item($0, nudged: .move(dx: 0, dy: 0.05)) },
            action("Move left") { $0.handler?.item($0, nudged: .move(dx: -0.05, dy: 0)) },
            action("Move right") { $0.handler?.item($0, nudged: .move(dx: 0.05, dy: 0)) }
        ]
        accessibilityCustomActions = actions
    }

    private func action(_ name: String, _ perform: @escaping @MainActor (MediaOverlayItemView) -> Void)
        -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let self else { return false }
            perform(self)
            return true
        }
    }

    /// Selects a sticker; opens a text for editing.
    override func accessibilityActivate() -> Bool {
        guard let handler, handler.isEditable else { return false }
        if case .text = overlay.content {
            handler.itemWantsEditing(self)
        } else {
            handler.itemTapped(self)
        }
        return true
    }

    private static func name(of emoji: String) -> String {
        guard let scalar = emoji.unicodeScalars.first, let name = scalar.properties.name else { return emoji }
        return name.lowercased().capitalized
    }

    // MARK: - Tests

    /// Internal for tests: the picture the view shows, if the rasteriser drew one.
    var debugPicture: UIImage? { picture.image }
    /// Internal for tests: the lettering shown while the rasteriser cannot draw.
    var debugLettering: NSAttributedString? { lettering.isHidden ? nil : lettering.attributedText }
    /// Internal for tests: the scale the picture was last drawn at.
    var debugDrawnScale: Double { drawnScale }
    /// Internal for tests: the item's recognisers, to read how they are wired.
    var debugTap: UITapGestureRecognizer { tap }
    var debugTogetherRecognisers: [UIGestureRecognizer] { [pan, pinch, rotation] }
}
