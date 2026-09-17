import DesignSystem
import MediaPlayback
import UIKit

/// What the Effects tools spell and draw.
///
/// ⚠️ **EVERY SYMBOL HERE IS ASKED OF THE RUNTIME BY A TEST**
/// (`everyEffectsGlyphExists`). A name that does not resolve draws an empty
/// card and nothing errors — the category strip shipped one once.
enum MediaEffectsCatalog {
    static let closeGlyph = "xmark"
    static let noneGlyph = "circle.slash"
    static let noneLabel = "None"

    /// How strongly a newly chosen effect is laid on: fully, so its card and
    /// the canvas agree, and the slider takes it down from there.
    static let startingIntensity = 1.0

    static func name(_ key: LookAdjustments.Key) -> String {
        switch key {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .warmth: "Warmth"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .sharpness: "Sharpness"
        case .vignette: "Vignette"
        case .grain: "Grain"
        }
    }

    static func glyph(_ key: LookAdjustments.Key) -> String {
        switch key {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.halffull"
        case .warmth: "thermometer.medium"
        case .highlights: "circle.tophalf.filled"
        case .shadows: "circle.bottomhalf.filled"
        case .sharpness: "triangle.lefthalf.filled"
        case .vignette: "circle.dashed"
        case .grain: "circle.grid.3x3"
        }
    }

    static func name(_ kind: LookEffectKind) -> String {
        switch kind {
        case .blur: "Blur"
        case .pixellate: "Pixels"
        case .rgbSplit: "RGB Split"
        case .vhs: "VHS"
        case .posterize: "Posterize"
        case .comic: "Comic"
        case .bloom: "Bloom"
        case .zoomBlur: "Zoom"
        case .crystallize: "Crystal"
        case .halftone: "Halftone"
        case .thermal: "Thermal"
        case .xray: "X-Ray"
        }
    }

    /// Every symbol the tools draw.
    static var glyphs: [String] {
        [closeGlyph, noneGlyph] + LookAdjustments.Key.allCases.map(glyph)
    }
}

/// The small pictures a row of looks is made of.
///
/// ⚠️ **ONE SOURCE, SHRUNK ONCE, THEN MANY LOOKS.** The canvas-sized picture is
/// ~1.4 MB; running thirteen looks over it for 56pt cards would be thirteen
/// canvas renders. It is shrunk first — whole, so a crop's fractions still
/// mean the same thing — then cut, then dressed.
///
/// `nonisolated`: values and `Sendable` images only, so a row can be dressed
/// off the main actor.
enum MediaLookThumbnails {
    /// `source` shrunk so its short side is `pixels` × 2 (room for a cut), then
    /// cut by `crop`. Upright, at scale 1.
    nonisolated static func base(_ source: UIImage, crop: MediaCrop, pixels: CGFloat) -> UIImage {
        let short = min(source.size.width, source.size.height)
        let factor = short > 0 ? min(1, (pixels * 2) / short) : 1
        let size = CGSize(
            width: max(1, (source.size.width * factor).rounded()),
            height: max(1, (source.size.height * factor).rounded())
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard !crop.isUntouched else { return small }
        return MediaCropRenderer.apply(crop, to: small) ?? small
    }

    /// `base` wearing `look`; `base` itself for a neutral look or a failed
    /// render.
    nonisolated static func dressed(_ base: UIImage, in look: FrameLook) -> UIImage {
        guard !look.isNeutral, let source = CIImage(image: base) else { return base }
        let output = FrameLookRenderer.apply(look, to: source, time: 0)
        guard output !== source,
              let rendered = EditingRenderContext.shared.createCGImage(output, from: source.extent)
        else { return base }
        return UIImage(cgImage: rendered, scale: base.scale, orientation: base.imageOrientation)
    }
}

/// The Effects tools in the editing band: the dials, then the effects — and,
/// while one of them is being turned, its slider.
///
/// ```
///  browsing:
///  ┌──┐┌──┐┌──┐ … ┌──┐ │ ┌──┐┌──┐┌──┐┌──┐
///  │☀•││◐ ││💧│    │▦ │ │ │⊘ ││▣▣││▣▣││▣▣│  →
///  └──┘└──┘└──┘    └──┘ │ └──┘└──┘└──┘└──┘
///  Brig Cont Satu  Grain  None Blur Pixl RGB
///
///  turning one:
///  (✕)  Brightness  ━━━━━━━━━●━━━━━━━━━
///       +23
/// ```
///
/// ⚠️ **A DOT, NOT A NUMBER, ON A TURNED DIAL'S CARD.** Nine numbers in a row
/// read as a spreadsheet; the dot says "this one is not at rest", and the
/// number is one tap away.
///
/// ⚠️ **ONE EFFECT AT A TIME.** Choosing an effect replaces the one before —
/// the compositor's budget on an SE allows one stylised stage per frame
/// (`FrameLookRenderer`) — and "None" is a card of its own, ringed while no
/// effect is on.
///
/// ⚠️ **THE VIEW DECIDES NOTHING ABOUT THE PICTURE.** It says what was turned
/// (`onDial`, `onEffect`) and is told what is true (`show(_:)`); the mode writes
/// the edit and the screen redraws.
@MainActor
final class MediaEffectsToolsView: UIView {
    private enum Metrics {
        static let card: CGFloat = 56
    }

    /// As tall as the filter row, so the band does not jump between the two.
    static var height: CGFloat { MediaFilterRowView.height }

    /// The side of an effect card's picture, in points.
    static var thumbnailSide: CGFloat { Metrics.card }

    /// What the tools are showing.
    enum Focus: Equatable {
        /// The row of dials and effects.
        case browsing
        /// One dial's slider.
        case dial(LookAdjustments.Key)
        /// The chosen effect's strength.
        case effect(LookEffectKind)
    }

    /// A dial moved; `isTracking` is true while a finger is still on it.
    var onDial: ((LookAdjustments.Key, Double, _ isTracking: Bool) -> Void)?
    /// The effect changed — nil is "None".
    var onEffect: ((LookEffect?, _ isTracking: Bool) -> Void)?
    /// A finger came down on the slider, or lifted.
    var onTracking: ((Bool) -> Void)?

    private(set) var focus: Focus = .browsing
    private var look = FrameLook.neutral

    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private var dialCards: [LookAdjustments.Key: EffectsCard] = [:]
    private var effectCards: [LookEffectKind: EffectsCard] = [:]
    private let noneCard = EffectsCard(glyph: MediaEffectsCatalog.noneGlyph, caption: MediaEffectsCatalog.noneLabel)
    private let slider = MediaValueSliderRow()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.clipsToBounds = false
        scroller.contentInset = UIEdgeInsets(top: 0, left: Spacing.lg, bottom: 0, right: Spacing.lg)
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Spacing.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.pin(to: self)

        for key in LookAdjustments.Key.allCases {
            let card = EffectsCard(glyph: MediaEffectsCatalog.glyph(key), caption: MediaEffectsCatalog.name(key))
            card.onTap = { [weak self] in self?.focus(on: .dial(key)) }
            dialCards[key] = card
            row.addArrangedSubview(card)
        }
        row.addArrangedSubview(Self.divider())
        noneCard.onTap = { [weak self] in self?.chooseNone() }
        row.addArrangedSubview(noneCard)
        for kind in LookEffectKind.allCases {
            let card = EffectsCard(glyph: nil, caption: MediaEffectsCatalog.name(kind))
            card.onTap = { [weak self] in self?.choose(kind) }
            effectCards[kind] = card
            row.addArrangedSubview(card)
        }

        slider.alpha = 0
        slider.isHidden = true
        slider.onClose = { [weak self] in self?.browse(animated: true) }
        slider.onTracking = { [weak self] tracking in self?.onTracking?(tracking) }
        slider.onChange = { [weak self] value, tracking in self?.sliderMoved(to: value, tracking: tracking) }
        slider.pin(to: self)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Self.height)
        ])
        show(.neutral)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// States what the page carries, without announcing it: the dots, the
    /// ringed effect, and the slider's value if one is up.
    func show(_ look: FrameLook) {
        self.look = look
        for (key, card) in dialCards {
            let value = look.adjustments[key]
            card.setMarked(value != 0)
            card.accessibilityValue = MediaValueSliderRow.spelled(value, twoSided: key.range.lowerBound < 0).spoken
        }
        noneCard.setChosen(look.effect == nil)
        for (kind, card) in effectCards {
            let chosen = look.effect?.kind == kind
            card.setChosen(chosen)
            card.accessibilityValue = chosen
                ? MediaValueSliderRow.spelled(look.effect?.intensity ?? 0, twoSided: false).spoken
                : nil
        }
        switch focus {
        case .browsing: break
        case .dial(let key): slider.show(look.adjustments[key])
        case .effect(let kind):
            // ⚠️ **AN EFFECT TAKEN AWAY ELSEWHERE TAKES ITS SLIDER WITH IT** —
            // the undo arrow, or another page.
            if look.effect?.kind == kind {
                slider.show(look.effect?.intensity ?? 0)
            } else {
                browse(animated: false)
            }
        }
    }

    /// Hands the effect cards their pictures. "None" keeps its symbol.
    func show(pictures: [LookEffectKind: UIImage]) {
        for (kind, card) in effectCards { card.setPicture(pictures[kind]) }
    }

    /// Back to the row of cards.
    func browse(animated: Bool) {
        guard focus != .browsing else { return }
        focus = .browsing
        crossfade(toSlider: false, animated: animated)
    }

    private func focus(on focus: Focus) {
        self.focus = focus
        switch focus {
        case .browsing:
            return
        case .dial(let key):
            let name = MediaEffectsCatalog.name(key)
            slider.configure(
                title: name, closeLabel: "Close \(name)", range: key.range, value: look.adjustments[key]
            )
        case .effect(let kind):
            let name = MediaEffectsCatalog.name(kind)
            slider.configure(
                title: name, closeLabel: "Close \(name)", range: 0...1,
                value: look.effect?.intensity ?? MediaEffectsCatalog.startingIntensity
            )
        }
        crossfade(toSlider: true, animated: window != nil)
    }

    private func chooseNone() {
        guard look.effect != nil else { return }
        look.effect = nil
        show(look)
        onEffect?(nil, false)
    }

    /// ⚠️ **EXCLUSIVE, AND A TAP ON THE CHOSEN ONE ONLY OPENS ITS SLIDER.**
    /// Re-choosing it would put its strength back to full under a finger that
    /// only wanted to adjust it.
    private func choose(_ kind: LookEffectKind) {
        if look.effect?.kind != kind {
            look.effect = LookEffect(kind: kind, intensity: MediaEffectsCatalog.startingIntensity)
            show(look)
            onEffect?(look.effect, false)
        }
        focus(on: .effect(kind))
    }

    private func sliderMoved(to value: Double, tracking: Bool) {
        switch focus {
        case .browsing:
            return
        case .dial(let key):
            look.adjustments[key] = value
            dialCards[key]?.setMarked(look.adjustments[key] != 0)
            onDial?(key, look.adjustments[key], tracking)
        case .effect(let kind):
            look.effect = LookEffect(kind: kind, intensity: value)
            onEffect?(look.effect, tracking)
        }
    }

    /// ⚠️ **STATED BEFORE THE ANIMATION, NEVER READ FROM IT** — a
    /// `.beginFromCurrentState` fade staged in the same turn animates end to
    /// end and is invisible (memory `uiview-animate-from-value-trap`); this one
    /// starts from alphas it has just set.
    private func crossfade(toSlider: Bool, animated: Bool) {
        slider.isHidden = false
        scroller.isHidden = false
        scroller.isUserInteractionEnabled = !toSlider
        slider.isUserInteractionEnabled = toSlider
        let changes = { [self] in
            slider.alpha = toSlider ? 1 : 0
            scroller.alpha = toSlider ? 0 : 1
        }
        let landed = { [weak self] in
            guard let self else { return }
            let showingSlider = focus != .browsing
            slider.isHidden = !showingSlider
            scroller.isHidden = showingSlider
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            landed()
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: changes) { _ in
            landed()
        }
    }

    private static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView()
        host.addSubview(line)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 1 + Spacing.sm),
            host.heightAnchor.constraint(equalToConstant: Metrics.card),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: Spacing.sm),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Spacing.sm)
        ])
        return host
    }

    // MARK: - Tests

    /// Internal for tests: the slider row.
    var debugSlider: MediaValueSliderRow { slider }
    /// Internal for tests: whether the slider, not the row, is what shows.
    var debugShowsSlider: Bool { !slider.isHidden && slider.alpha > 0 && focus != .browsing }
    /// Internal for tests: a tap on a dial's card.
    func debugTapDial(_ key: LookAdjustments.Key) { dialCards[key]?.onTap?() }
    /// Internal for tests: a tap on an effect's card.
    func debugTapEffect(_ kind: LookEffectKind) { effectCards[kind]?.onTap?() }
    /// Internal for tests: a tap on "None".
    func debugTapNone() { noneCard.onTap?() }
    /// Internal for tests: whether a dial's card wears its dot.
    func debugDialIsMarked(_ key: LookAdjustments.Key) -> Bool { dialCards[key]?.isMarked ?? false }
    /// Internal for tests: which cards are ringed — nil is "None".
    var debugRingedEffects: [LookEffectKind?] {
        (noneCard.isChosen ? [nil] : []) + LookEffectKind.allCases.filter { effectCards[$0]?.isChosen == true }
    }
    /// Internal for tests: an effect card's picture.
    func debugPicture(for kind: LookEffectKind) -> UIImage? { effectCards[kind]?.picture }
    /// Internal for tests: a dial's card, to read what VoiceOver reads.
    func debugDialCard(_ key: LookAdjustments.Key) -> UIView? { dialCards[key] }
}

/// One card: a symbol or a picture, its word underneath, a dot when the dial
/// it stands for is turned, a ring when it is chosen.
private final class EffectsCard: UIControl {
    private enum Metrics {
        static let side: CGFloat = 56
        static let corner: CGFloat = 10
        static let ring: CGFloat = 2
        static let caption: CGFloat = 16
        static let dot: CGFloat = 6
        static let glyph: CGFloat = 20
    }

    var onTap: (() -> Void)?
    private let tile = UIView()
    private let glyphView = UIImageView()
    private let pictureView = UIImageView()
    private let captionLabel = UILabel()
    private let dot = UIView()
    private(set) var isMarked = false
    private(set) var isChosen = false
    var picture: UIImage? { pictureView.image }

    init(glyph: String?, caption: String) {
        super.init(frame: .zero)
        tile.backgroundColor = .tertiarySystemFill
        tile.layer.cornerRadius = Metrics.corner
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.isUserInteractionEnabled = false
        tile.layer.borderColor = UIColor.tintColor.cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false

        pictureView.contentMode = .scaleAspectFill
        pictureView.clipsToBounds = true
        pictureView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pictureView)
        if let glyph {
            glyphView.image = UIImage(
                systemName: glyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.glyph, weight: .regular)
            )
            glyphView.tintColor = .label
            glyphView.contentMode = .center
            glyphView.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(glyphView)
            NSLayoutConstraint.activate([
                glyphView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                glyphView.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
            ])
        }

        dot.backgroundColor = .tintColor
        dot.layer.cornerRadius = Metrics.dot / 2
        dot.isHidden = true
        dot.isUserInteractionEnabled = false
        dot.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = caption
        captionLabel.font = .preferredFont(forTextStyle: .caption2)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.7
        captionLabel.textAlignment = .center
        captionLabel.textColor = .secondaryLabel
        captionLabel.isUserInteractionEnabled = false
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(dot)
        addSubview(captionLabel)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.widthAnchor.constraint(equalToConstant: Metrics.side),
            tile.heightAnchor.constraint(equalToConstant: Metrics.side),
            pictureView.topAnchor.constraint(equalTo: tile.topAnchor),
            pictureView.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            pictureView.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            pictureView.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            dot.widthAnchor.constraint(equalToConstant: Metrics.dot),
            dot.heightAnchor.constraint(equalToConstant: Metrics.dot),
            dot.topAnchor.constraint(equalTo: tile.topAnchor, constant: Spacing.xs),
            dot.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -Spacing.xs),
            captionLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: Spacing.xs),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.heightAnchor.constraint(equalToConstant: Metrics.caption),
            // ⚠️ **THE CARD'S HEIGHT COMES FROM BELOW** — the filter chip's
            // lesson: without it the control is shorter than its picture and a
            // finger on the tile's lower half lands on nothing.
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Metrics.side)
        ])

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = caption
        accessibilityTraits = .button
        // ⚠️ A `CGColor`, SO IT IS RE-STATED ON EVERY APPEARANCE CHANGE.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: EffectsCard, _) in
            card.tile.layer.borderColor = UIColor.tintColor.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    func setMarked(_ marked: Bool) {
        isMarked = marked
        dot.isHidden = !marked
    }

    func setChosen(_ chosen: Bool) {
        isChosen = chosen
        tile.layer.borderWidth = chosen ? Metrics.ring : 0
        captionLabel.textColor = chosen ? .label : .secondaryLabel
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    func setPicture(_ image: UIImage?) {
        pictureView.image = image
    }
}
