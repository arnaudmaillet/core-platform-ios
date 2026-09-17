import DesignSystem
import MediaPlayback
import UIKit

/// What the Effects tools spell and draw.
///
/// ⚠️ **EVERY SYMBOL HERE IS ASKED OF THE RUNTIME BY A TEST**
/// (`everyEffectsGlyphExists`). A name that does not resolve draws an empty
/// pill and nothing errors — the category strip shipped one once.
enum MediaEffectsCatalog {
    static let noneGlyph = "circle.slash"
    static let noneLabel = "None"

    /// How strongly a newly chosen effect is laid on: fully, so its pill and
    /// the canvas agree, and the ruler takes it down from there.
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
        [noneGlyph] + LookAdjustments.Key.allCases.map(glyph)
    }
}

/// The small pictures a row of looks is made of.
///
/// ⚠️ **ONE SOURCE, SHRUNK ONCE, THEN MANY LOOKS.** The canvas-sized picture is
/// ~1.4 MB; running thirteen looks over it for tiny pictures would be thirteen
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

/// The Effects tools in the editing band: a row of pills — the dials, then the
/// effects — and, over it, the ruler of the one being turned.
///
/// ```
///                         +20%
///   · · ┃ · · · · ┃ · · · ▼ · · ┃ · · · ·           ← while a pill is chosen
///  (Brightness +20%)(◐ Contrast)(💧 Saturation) │ (⊘ None)(◉ Blur) →
/// ```
///
/// ⚠️ **THE CROP TOOLS' LAYOUT: A RULER OVER A ROW OF CHIPS, AND THE SAME
/// HEIGHT.** Choosing a pill brings the ruler in above the row; the row never
/// leaves, so the next dial is one tap away rather than a close button and a
/// tap. A tap on the chosen pill puts the ruler away.
///
/// ⚠️ **A NUMBER INSTEAD OF THE SYMBOL ON A TURNED PILL.** "Contrast −30%" says
/// both that the dial is not at rest and where it is, and an untouched pill
/// keeps the symbol that helps find it.
///
/// ⚠️ **ONE EFFECT AT A TIME.** Choosing an effect replaces the one before —
/// the compositor's budget on an SE allows one stylised stage per frame
/// (`FrameLookRenderer`) — and "None" takes it away, so it is dimmed while
/// there is nothing to take.
///
/// ⚠️ **THE VIEW DECIDES NOTHING ABOUT THE PICTURE.** It says what was turned
/// (`onDial`, `onEffect`) and is told what is true (`show(_:)`); the mode writes
/// the edit and the screen redraws.
@MainActor
final class MediaEffectsToolsView: UIView {
    private enum Metrics {
        static let pill: CGFloat = 30
        static let icon: CGFloat = 20
        static var height: CGFloat { MediaValueRulerView.height + Spacing.sm + pill }
    }

    /// The ruler, a gap and a row of pills — `MediaCropToolsView`'s sum.
    static var height: CGFloat { Metrics.height }

    /// The side of an effect pill's picture, in points.
    static var thumbnailSide: CGFloat { Metrics.icon }

    /// What the tools are showing.
    enum Focus: Equatable {
        /// The row alone.
        case browsing
        /// One dial's ruler.
        case dial(LookAdjustments.Key)
        /// The chosen effect's strength.
        case effect(LookEffectKind)
    }

    /// A dial moved; `isTracking` is true while a finger is still on it.
    var onDial: ((LookAdjustments.Key, Double, _ isTracking: Bool) -> Void)?
    /// The effect changed — nil is "None".
    var onEffect: ((LookEffect?, _ isTracking: Bool) -> Void)?
    /// A finger came down on the ruler, or lifted.
    var onTracking: ((Bool) -> Void)?

    private(set) var focus: Focus = .browsing
    private var look = FrameLook.neutral

    private let ruler = MediaValueRulerView()
    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private var dialPills: [LookAdjustments.Key: EffectsPill] = [:]
    private var effectPills: [LookEffectKind: EffectsPill] = [:]
    private let nonePill = EffectsPill(glyph: MediaEffectsCatalog.noneGlyph, caption: MediaEffectsCatalog.noneLabel)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        ruler.alpha = 0
        ruler.isHidden = true
        ruler.isUserInteractionEnabled = false
        ruler.onTracking = { [weak self] tracking in self?.onTracking?(tracking) }
        ruler.onChange = { [weak self] value, tracking in self?.rulerMoved(to: value, tracking: tracking) }

        // ⚠️ THE BAND HAS NO BACKGROUND, SO NEITHER DOES THIS — and no clipping,
        // which would cut a pill at the band's edge instead of the screen's.
        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.clipsToBounds = false
        scroller.contentInset = UIEdgeInsets(top: 0, left: Spacing.lg, bottom: 0, right: Spacing.lg)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)

        for key in LookAdjustments.Key.allCases {
            let pill = EffectsPill(glyph: MediaEffectsCatalog.glyph(key), caption: MediaEffectsCatalog.name(key))
            pill.onTap = { [weak self] in self?.toggle(.dial(key)) }
            dialPills[key] = pill
            row.addArrangedSubview(pill)
        }
        row.addArrangedSubview(Self.divider())
        nonePill.onTap = { [weak self] in self?.chooseNone() }
        row.addArrangedSubview(nonePill)
        for kind in LookEffectKind.allCases {
            let pill = EffectsPill(glyph: nil, caption: MediaEffectsCatalog.name(kind))
            pill.onTap = { [weak self] in self?.choose(kind) }
            effectPills[kind] = pill
            row.addArrangedSubview(pill)
        }

        ruler.constrain(in: self) { view in
            ruler.topAnchor.constraint(equalTo: view.topAnchor)
            ruler.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            ruler.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        }
        scroller.constrain(in: self) { view in
            scroller.topAnchor.constraint(equalTo: ruler.bottomAnchor, constant: Spacing.sm)
            scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            scroller.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            scroller.heightAnchor.constraint(equalToConstant: Metrics.pill)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
        show(.neutral)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// States what the page carries, without announcing it: the numbers on the
    /// pills, the chosen effect, and the ruler's value if one is up.
    func show(_ look: FrameLook) {
        self.look = look
        refreshPills()
        switch focus {
        case .browsing: break
        case .dial(let key): ruler.show(look.adjustments[key])
        case .effect(let kind):
            // ⚠️ **AN EFFECT TAKEN AWAY ELSEWHERE TAKES ITS RULER WITH IT** —
            // the undo arrow, or another page.
            if look.effect?.kind == kind {
                ruler.show(look.effect?.intensity ?? 0)
            } else {
                browse(animated: false)
            }
        }
    }

    /// Hands the effect pills their pictures. "None" keeps its symbol.
    func show(pictures: [LookEffectKind: UIImage]) {
        for (kind, pill) in effectPills { pill.setPicture(pictures[kind]) }
    }

    /// Puts the ruler away; the row stays.
    func browse(animated: Bool) {
        guard focus != .browsing else { return }
        ruler.abandonDrag()
        focus = .browsing
        refreshFocus()
        fadeRuler(in: false, animated: animated)
    }

    private func refreshPills() {
        for (key, pill) in dialPills {
            let value = look.adjustments[key]
            let words = ValueRuler.reading(value, twoSided: key.range.lowerBound < 0)
            pill.setReading(value != 0 ? words.written : nil)
            pill.accessibilityValue = words.spoken
        }
        nonePill.isEnabled = look.effect != nil
        for (kind, pill) in effectPills {
            let chosen = look.effect?.kind == kind
            let words = ValueRuler.reading(look.effect?.intensity ?? 0, twoSided: false)
            pill.setChosen(chosen)
            pill.setReading(chosen ? words.written : nil)
            pill.accessibilityValue = chosen ? words.spoken : nil
        }
    }

    private func refreshFocus() {
        for (key, pill) in dialPills { pill.setLit(focus == .dial(key)) }
        for (kind, pill) in effectPills { pill.setLit(focus == .effect(kind)) }
    }

    /// A tap on the pill that is already up puts its ruler away.
    private func toggle(_ target: Focus) {
        guard target != focus else {
            browse(animated: true)
            return
        }
        focus(on: target)
    }

    private func focus(on target: Focus) {
        let wasBrowsing = focus == .browsing
        focus = target
        switch target {
        case .browsing:
            return
        case .dial(let key):
            ruler.configure(
                name: MediaEffectsCatalog.name(key), range: key.range, rest: 0, value: look.adjustments[key]
            )
        case .effect(let kind):
            ruler.configure(
                name: MediaEffectsCatalog.name(kind), range: 0...1,
                rest: MediaEffectsCatalog.startingIntensity,
                value: look.effect?.intensity ?? MediaEffectsCatalog.startingIntensity
            )
        }
        refreshFocus()
        reveal(target)
        if wasBrowsing { fadeRuler(in: true, animated: window != nil) }
    }

    /// Scrolls the chosen pill fully into the row.
    private func reveal(_ target: Focus) {
        let pill: UIView?
        switch target {
        case .browsing: pill = nil
        case .dial(let key): pill = dialPills[key]
        case .effect(let kind): pill = effectPills[kind]
        }
        guard let pill, scroller.bounds.width > 0 else { return }
        layoutIfNeeded()
        let frame = pill.convert(pill.bounds, to: scroller).insetBy(dx: -Spacing.lg, dy: 0)
        scroller.scrollRectToVisible(frame, animated: window != nil)
    }

    private func chooseNone() {
        guard look.effect != nil else { return }
        look.effect = nil
        if case .effect = focus { browse(animated: true) }
        refreshPills()
        onEffect?(nil, false)
    }

    /// ⚠️ **A TAP ON THE CHOSEN ONE ONLY BRINGS UP ITS RULER** — or puts it
    /// away. Re-choosing it would put its strength back to full under a finger
    /// that only wanted to adjust it.
    private func choose(_ kind: LookEffectKind) {
        guard look.effect?.kind != kind else {
            toggle(.effect(kind))
            return
        }
        look.effect = LookEffect(kind: kind, intensity: MediaEffectsCatalog.startingIntensity)
        refreshPills()
        onEffect?(look.effect, false)
        focus(on: .effect(kind))
    }

    private func rulerMoved(to value: Double, tracking: Bool) {
        switch focus {
        case .browsing:
            return
        case .dial(let key):
            look.adjustments[key] = value
            refreshPills()
            onDial?(key, look.adjustments[key], tracking)
        case .effect(let kind):
            // A strength dragged to zero is no effect (`LookEffect.normalised`),
            // and the ruler stays under the finger that did it.
            look.effect = LookEffect(kind: kind, intensity: value)
            refreshPills()
            onEffect?(look.effect, tracking)
        }
    }

    /// ⚠️ **STATED BEFORE THE ANIMATION, NEVER READ FROM IT** — a
    /// `.beginFromCurrentState` fade staged in the same turn animates end to
    /// end and is invisible (memory `uiview-animate-from-value-trap`); this one
    /// starts from an alpha it has just set.
    private func fadeRuler(in showing: Bool, animated: Bool) {
        ruler.isHidden = false
        ruler.isUserInteractionEnabled = showing
        let change = { [ruler] in ruler.alpha = showing ? 1 : 0 }
        let landed = { [weak self] in
            guard let self else { return }
            ruler.isHidden = focus == .browsing
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            change()
            landed()
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: change) { _ in
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
            host.heightAnchor.constraint(equalToConstant: Metrics.pill),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: Spacing.sm),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Spacing.sm)
        ])
        return host
    }

    // MARK: - Tests

    /// Internal for tests: the ruler.
    var debugRuler: MediaValueRulerView { ruler }
    /// Internal for tests: whether the ruler is what a finger would find above
    /// the row.
    var debugShowsRuler: Bool {
        !ruler.isHidden && ruler.alpha > 0 && ruler.isUserInteractionEnabled && focus != .browsing
    }
    /// Internal for tests: whether the row is on screen and takes touches.
    var debugShowsRow: Bool { !scroller.isHidden && scroller.alpha > 0 && scroller.isUserInteractionEnabled }
    /// Internal for tests: where the ruler and the row sit, in this view.
    var debugRulerFrame: CGRect { ruler.frame }
    var debugRowFrame: CGRect { scroller.frame }
    /// Internal for tests: a tap on a dial's pill.
    func debugTapDial(_ key: LookAdjustments.Key) { dialPills[key]?.onTap?() }
    /// Internal for tests: a tap on an effect's pill.
    func debugTapEffect(_ kind: LookEffectKind) { effectPills[kind]?.onTap?() }
    /// Internal for tests: a tap on "None".
    func debugTapNone() { nonePill.onTap?() }
    /// Internal for tests: whether "None" can be tapped.
    var debugNoneIsEnabled: Bool { nonePill.isEnabled }
    /// Internal for tests: the number a dial's pill shows, nil when it shows
    /// its symbol.
    func debugReading(_ key: LookAdjustments.Key) -> String? { dialPills[key]?.reading }
    func debugReading(_ kind: LookEffectKind) -> String? { effectPills[kind]?.reading }
    /// Internal for tests: which effects are chosen.
    var debugChosenEffects: [LookEffectKind] {
        LookEffectKind.allCases.filter { effectPills[$0]?.isChosen == true }
    }
    /// Internal for tests: the pills drawn filled, by caption.
    var debugFocusedPills: [String] {
        (Array(dialPills.values) + Array(effectPills.values) + [nonePill])
            .filter(\.isLit).map(\.caption)
    }
    /// Internal for tests: an effect pill's picture.
    func debugPicture(for kind: LookEffectKind) -> UIImage? { effectPills[kind]?.picture }
    /// Internal for tests: a dial's pill, to read what VoiceOver reads.
    func debugDialPill(_ key: LookAdjustments.Key) -> UIView? { dialPills[key] }
    /// Internal for tests: where a dial pill's parts sit, in the pill — nil for
    /// a part that is not showing.
    func debugParts(_ key: LookAdjustments.Key) -> (icon: CGRect?, caption: CGRect, reading: CGRect?)? {
        dialPills[key]?.parts
    }
    /// Internal for tests: a pill's height.
    func debugPillSize(_ key: LookAdjustments.Key) -> CGSize? { dialPills[key]?.bounds.size }
}

/// One pill: a symbol or a small picture and a word side by side — or, once
/// the dial it stands for is turned, the word and its number.
///
/// ```
/// ( ☀ Brightness )      ( Brightness +20% )
/// ```
private final class EffectsPill: UIControl {
    private enum Metrics {
        static let height: CGFloat = 30
        static let padding: CGFloat = 12
        static let gap: CGFloat = 6
        static let icon: CGFloat = 20
        static let glyph: CGFloat = 13
    }

    var onTap: (() -> Void)?
    let caption: String
    private let hasPicture: Bool
    private let iconView = UIImageView()
    private let captionLabel = UILabel()
    private let readingLabel = UILabel()
    private let stack = UIStackView()
    private(set) var isLit = false
    private(set) var isChosen = false
    private(set) var reading: String?
    var picture: UIImage? { hasPicture ? iconView.image : nil }

    init(glyph: String?, caption: String) {
        self.caption = caption
        hasPicture = glyph == nil
        super.init(frame: .zero)
        layer.cornerCurve = .continuous

        if let glyph {
            iconView.image = UIImage(
                systemName: glyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.glyph, weight: .semibold)
            )
            iconView.contentMode = .center
        } else {
            // A picture waits for its render on a plain disc, so the pill does
            // not change width when it lands.
            iconView.backgroundColor = .tertiarySystemFill
            iconView.contentMode = .scaleAspectFill
            iconView.layer.cornerRadius = Metrics.icon / 2
            iconView.clipsToBounds = true
        }
        captionLabel.text = caption
        captionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        readingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        readingLabel.isHidden = true

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Metrics.gap
        stack.isUserInteractionEnabled = false
        for part in [iconView, captionLabel, readingLabel] { stack.addArrangedSubview(part) }
        stack.constrain(in: self) { view in
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.padding)
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.padding)
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Metrics.icon),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.icon),
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = caption
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Shaped before anything reads it — `IconSelectorBar`'s rule.
        layer.cornerRadius = bounds.height / 2
    }

    override var isHighlighted: Bool {
        didSet { paint() }
    }

    override var isEnabled: Bool {
        didSet { paint() }
    }

    /// Nil shows the symbol; a number replaces it.
    func setReading(_ text: String?) {
        guard text != reading else { return }
        reading = text
        readingLabel.text = text
        readingLabel.isHidden = text == nil
        iconView.isHidden = text != nil
    }

    /// Filled while its ruler is up.
    func setLit(_ lit: Bool) {
        guard lit != isLit else { return }
        isLit = lit
        paint()
    }

    /// The effect that is on.
    func setChosen(_ chosen: Bool) {
        guard chosen != isChosen else { return }
        isChosen = chosen
        paint()
    }

    func setPicture(_ image: UIImage?) {
        guard hasPicture else { return }
        iconView.image = image
    }

    /// ⚠️ **ONE MATERIAL, NEVER TWO — AND HERE, NONE AT ALL**, the crop chip's
    /// rule: the band carries no plate, so a focused pill is a fill in the
    /// label's colour and the rest are a faint wash of it.
    private func paint() {
        backgroundColor = isLit ? .label : UIColor.label.withAlphaComponent(0.12)
        let ink: UIColor = isLit ? .systemBackground : .label
        iconView.tintColor = ink
        captionLabel.textColor = ink
        readingLabel.textColor = ink
        alpha = !isEnabled ? 0.4 : (isHighlighted ? 0.55 : 1)
        var traits: UIAccessibilityTraits = .button
        if isLit || isChosen { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    /// Internal for tests: where the parts sit, in the pill.
    var parts: (icon: CGRect?, caption: CGRect, reading: CGRect?) {
        layoutIfNeeded()
        return (
            iconView.isHidden ? nil : iconView.convert(iconView.bounds, to: self),
            captionLabel.convert(captionLabel.bounds, to: self),
            readingLabel.isHidden ? nil : readingLabel.convert(readingLabel.bounds, to: self)
        )
    }
}
