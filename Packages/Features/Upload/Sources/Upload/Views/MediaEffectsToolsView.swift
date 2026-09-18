import DesignSystem
import MediaPlayback
import UIKit

/// What the Effects tools spell and draw.
///
/// ⚠️ **EVERY SYMBOL HERE IS ASKED OF THE RUNTIME BY A TEST**
/// (`everyEffectsGlyphExists`). A name that does not resolve draws an empty
/// pill and nothing errors — the category strip shipped one once.
enum MediaEffectsCatalog {

    /// ⚠️ **AN EFFECT OPENS AT NOTHING, AND ITS PILL SHOWS IT AT FULL.** Two
    /// numbers, because they answer different questions. Choosing an effect used
    /// to lay it on at full strength and leave the author turning it DOWN from a
    /// picture they had not asked for — *"ne jamais afficher par défaut un filtre
    /// à 100%"*. So a tap applies `startingIntensity`, which is none of it, and
    /// the ruler opens at zero for the author to raise. The PILL still has to
    /// show what the effect does, and an effect at zero looks like every other
    /// effect at zero, so its little picture is dressed at `previewIntensity`.
    static let startingIntensity = 0.0
    /// What an effect's own pill picture is dressed at — see above.
    static let previewIntensity = 1.0

    /// The two fixed icons that stand over the leading end of the row.
    static let clearGlyph = "circle.slash"
    static let clearLabel = "Take every look off"
    static let revertGlyph = "arrow.counterclockwise"
    static let revertLabel = "Back to how it was"

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
        [clearGlyph, revertGlyph] + LookAdjustments.Key.allCases.map(glyph)
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

/// The Effects tools in the editing band: a ruler over a row of pills — the
/// dials, then the effects — with two fixed icons standing over its leading end.
///
/// ```
///                         +20%
///   · · ┃ · · · · ┃ · · · ▼ · · ┃ · · · ·
///  (⊘)(↺)  (Brightness +20%)(◐ Contrast)(💧 Saturation) │ (◉ Blur) →
/// ```
///
/// ⚠️ **THE CROP TOOLS' LAYOUT, DOWN TO THE DISSOLVE.** A ruler over a row of
/// chips at the same height, and — as Crop does behind its rotate and mirror
/// buttons — the pills fade out as they pass behind the two icons rather than
/// sliding under them: the mask is on a host that does NOT scroll, because a
/// scroll view's `bounds.origin` IS its content offset.
///
/// ⚠️ **THERE IS NO EMPTY STATE: SOMETHING IS ALWAYS CHOSEN.** The row opens on
/// the first dial with its ruler up — *"un élément doit toujours être
/// sélectionné donc il faut sélectionner par défaut le premier"* — and a tap on
/// the pill that is already lit leaves it lit. The ruler is never put away, so
/// the band never changes shape under the author's finger.
///
/// ⚠️ **THE TWO ICONS ARE NOT PILLS, AND THAT IS THE POINT.** "None" used to be
/// a card in the row, which put an ACTION among a list of CHOICES and made it
/// scroll away just when it was wanted. Taking every look off, and going back to
/// the look the tab opened on, stand still at the leading end where a thumb
/// rests.
///
/// ⚠️ **A NUMBER INSTEAD OF THE SYMBOL ON A TURNED PILL.** "Contrast −30%" says
/// both that the dial is not at rest and where it is, and an untouched pill
/// keeps the symbol that helps find it.
///
/// ⚠️ **ONE EFFECT AT A TIME** — the compositor's budget on an SE allows one
/// stylised stage per frame (`FrameLookRenderer`).
///
/// ⚠️ **THE VIEW DECIDES NOTHING ABOUT THE PICTURE.** It says what was turned
/// (`onDial`, `onEffect`, `onClear`, `onRevert`) and is told what is true
/// (`show(_:)`); the mode writes the edit and the screen redraws.
@MainActor
final class MediaEffectsToolsView: UIView {
    private enum Metrics {
        static let pill: CGFloat = 30
        static let icon: CGFloat = 20
        static let button: CGFloat = 30
        /// How far a pill travels behind the icons before it is gone — the crop
        /// tools' number, measured there: at 28 the ramp was over before the eye
        /// registered it.
        static let fade: CGFloat = 52
        static var height: CGFloat { MediaValueRulerView.height + Spacing.sm + pill }
    }

    /// The ruler, a gap and a row of pills — `MediaCropToolsView`'s sum.
    static var height: CGFloat { Metrics.height }

    /// The side of an effect pill's picture, in points.
    static var thumbnailSide: CGFloat { Metrics.icon }

    /// Which pill the ruler belongs to. There is no third case: the row is
    /// never in an empty state.
    enum Focus: Equatable {
        /// One dial's ruler.
        case dial(LookAdjustments.Key)
        /// An effect's strength.
        case effect(LookEffectKind)
    }

    /// The dial the row opens on, and the one it settles back to when a new
    /// page arrives.
    static let firstDial = LookAdjustments.Key.allCases[0]

    /// A dial moved; `isTracking` is true while a finger is still on it.
    var onDial: ((LookAdjustments.Key, Double, _ isTracking: Bool) -> Void)?
    /// The effect changed — nil is "None".
    var onEffect: ((LookEffect?, _ isTracking: Bool) -> Void)?
    /// A finger came down on the ruler, or lifted.
    var onTracking: ((Bool) -> Void)?
    /// The ⊘ icon: take every look off this page.
    var onClear: (() -> Void)?
    /// The ↺ icon: back to the look the tab was opened on.
    var onRevert: (() -> Void)?

    private(set) var focus: Focus = .dial(MediaEffectsToolsView.firstDial)
    private var look = FrameLook.neutral

    private let ruler = MediaValueRulerView()
    private let scroller = ChipScrollView()
    private let row = UIStackView()
    /// ⚠️ **THE MASK GOES ON THIS, NOT ON THE SCROLLER** — `MediaCropToolsView`
    /// records why: a scroll view's `bounds.origin` is its content offset, so a
    /// mask framed in its bounds travels with the content and slides off the
    /// viewport on the first drag.
    private let scrollerHost = UIView()
    private let fadeOut = CAGradientLayer()
    private var dialPills: [LookAdjustments.Key: EffectsPill] = [:]
    private var effectPills: [LookEffectKind: EffectsPill] = [:]
    private lazy var clearButton = Self.button(
        symbol: MediaEffectsCatalog.clearGlyph, label: MediaEffectsCatalog.clearLabel
    ) { [weak self] in self?.onClear?() }
    private lazy var revertButton = Self.button(
        symbol: MediaEffectsCatalog.revertGlyph, label: MediaEffectsCatalog.revertLabel
    ) { [weak self] in self?.onRevert?() }
    private lazy var icons: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [clearButton, revertButton])
        stack.axis = .horizontal
        stack.spacing = Spacing.xs
        return stack
    }()
    /// What the last reveal decided to scroll to, nil when it left the row
    /// alone — the decision, which an animated scroll hides from a test.
    private var revealed: CGRect?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        ruler.onTracking = { [weak self] tracking in self?.onTracking?(tracking) }
        ruler.onChange = { [weak self] value, tracking in self?.rulerMoved(to: value, tracking: tracking) }

        // ⚠️ THE BAND HAS NO BACKGROUND, SO NEITHER DOES THIS — and no clipping,
        // which would cut a pill at the band's edge instead of the screen's.
        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.clipsToBounds = false
        // The leading inset is not a constant: `layoutSubviews` sets it past
        // the icons and their ramp, so the first pill rests where it is whole.
        scroller.contentInset = UIEdgeInsets(top: 0, left: Spacing.lg, bottom: 0, right: Spacing.lg)
        // ⚠️ **NO CLIPPING AT ALL — THE MASK IS THE ONLY THING THAT TAKES A PILL
        // AWAY.** A hard clip and a gradient fight for the same pixels and the
        // clip wins, which is the sharp edge this replaced in the crop tools.
        scrollerHost.clipsToBounds = false
        fadeOut.colors = [
            UIColor.clear.cgColor, UIColor.clear.cgColor,
            UIColor.black.cgColor, UIColor.black.cgColor
        ]
        fadeOut.startPoint = CGPoint(x: 0, y: 0.5)
        fadeOut.endPoint = CGPoint(x: 1, y: 0.5)
        scrollerHost.layer.mask = fadeOut
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)

        for key in LookAdjustments.Key.allCases {
            let pill = EffectsPill(glyph: MediaEffectsCatalog.glyph(key), caption: MediaEffectsCatalog.name(key))
            pill.onTap = { [weak self] in self?.focus(on: .dial(key)) }
            dialPills[key] = pill
            row.addArrangedSubview(pill)
        }
        row.addArrangedSubview(Self.divider())
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
        // ⚠️ **THE HOST IS ADDED FIRST, AND THAT IS WHAT PUTS THE ICONS ON TOP.**
        // `constrain(in:)` begins with `addSubview`, so the order of these two
        // blocks IS the z order — the crop tools' note, and the same reason: the
        // row has to run UNDER the icons for there to be anything to dissolve.
        scroller.pin(to: scrollerHost)
        scrollerHost.constrain(in: self) { view in
            scrollerHost.topAnchor.constraint(equalTo: ruler.bottomAnchor, constant: Spacing.sm)
            scrollerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            scrollerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            scrollerHost.heightAnchor.constraint(equalToConstant: Metrics.pill)
        }
        icons.constrain(in: self) { view in
            icons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg)
            icons.topAnchor.constraint(equalTo: scrollerHost.topAnchor)
            icons.heightAnchor.constraint(equalToConstant: Metrics.pill)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
        openOnTheFirstDial()
        show(.neutral)
    }

    /// ⚠️ **THE INSET AND THE RAMP ARE ONE STATEMENT.** Without the inset the
    /// first pill would come to rest inside the fade and sit permanently half
    /// dissolved; with it, a pill is solid where it stops and dissolves only on
    /// its way out. The frame is set with actions off because a layer that is
    /// not a view's backing layer animates its own `frame` over a quarter
    /// second, which would drag the ramp behind a rotation.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = scrollerHost.bounds.width
        guard width > 0 else { return }
        let behind = icons.frame.maxX
        let solid = behind + Metrics.fade
        if abs(scroller.contentInset.left - (solid + Spacing.sm)) > 0.5 {
            scroller.contentInset.left = solid + Spacing.sm
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeOut.frame = scrollerHost.bounds
        fadeOut.locations = [
            0,
            NSNumber(value: Double(behind / width)),
            NSNumber(value: Double(solid / width)),
            1
        ]
        CATransaction.commit()
    }

    /// One of the two icons: the crop tools' button, to the point.
    private static func button(
        symbol: String, label: String, action: @escaping @MainActor () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: Metrics.button).isActive = true
        return button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// States what the page carries, without announcing it: the numbers on the
    /// pills, the chosen effect, and where the ruler stands.
    func show(_ look: FrameLook) {
        self.look = look
        refreshPills()
        switch focus {
        case .dial(let key):
            ruler.show(look.adjustments[key])
        case .effect(let kind):
            // ⚠️ **AN EFFECT TAKEN OFF ELSEWHERE LEAVES ITS RULER AT NOTHING,
            // NOT SOMEWHERE ELSE.** The undo arrow, the ⊘ icon or another page
            // can empty it while its pill is the one lit; zero is where it sits
            // then, which is also where a fresh choice starts.
            ruler.show(look.effect?.kind == kind ? (look.effect?.intensity ?? 0) : 0)
        }
    }

    /// Hands the effect pills their pictures.
    func show(pictures: [LookEffectKind: UIImage]) {
        for (kind, pill) in effectPills { pill.setPicture(pictures[kind]) }
    }

    /// Whether the ↺ icon has anything to go back to.
    func setCanRevert(_ can: Bool) {
        revertButton.isEnabled = can
    }

    /// Back to the dial the row opens on — what a new page, or the band being
    /// handed to someone else, settles the row to.
    ///
    /// ⚠️ **NOT "NOTHING CHOSEN".** There is no such state: the ruler belongs to
    /// a pill at all times, so arriving at another picture puts it back on the
    /// first dial rather than leaving the band half empty.
    func openOnTheFirstDial() {
        ruler.abandonDrag()
        focus(on: .dial(Self.firstDial))
    }

    private func refreshPills() {
        for (key, pill) in dialPills {
            let value = look.adjustments[key]
            let words = ValueRuler.reading(value, twoSided: key.range.lowerBound < 0)
            pill.setReading(value != 0 ? words.written : nil)
            pill.accessibilityValue = words.spoken
        }
        clearButton.isEnabled = !look.adjustments.isNeutral || look.effect != nil
        for (kind, pill) in effectPills {
            let chosen = look.effect?.kind == kind
            let words = ValueRuler.reading(look.effect?.intensity ?? 0, twoSided: false)
            pill.setChosen(chosen)
            // ⚠️ **THE LIT PILL SHOWS ITS NUMBER EVEN AT NOTHING.** An effect
            // opens at 0%, so it carries no effect at all yet; without this the
            // pill the ruler belongs to would be the one pill not saying where
            // it stands.
            let lit = focus == .effect(kind)
            pill.setReading(chosen || lit ? words.written : nil)
            pill.accessibilityValue = chosen || lit ? words.spoken : nil
        }
    }

    private func refreshFocus() {
        for (key, pill) in dialPills { pill.setLit(focus == .dial(key)) }
        for (kind, pill) in effectPills { pill.setLit(focus == .effect(kind)) }
    }

    /// ⚠️ **A TAP ON THE PILL THAT IS ALREADY LIT CHANGES NOTHING**, because
    /// there is nowhere to go: the row has no empty state, and putting the ruler
    /// away would be one.
    private func focus(on target: Focus) {
        focus = target
        switch target {
        case .dial(let key):
            ruler.configure(
                name: MediaEffectsCatalog.name(key), range: key.range, rest: 0, value: look.adjustments[key]
            )
        case .effect(let kind):
            ruler.configure(
                name: MediaEffectsCatalog.name(kind), range: 0...1,
                rest: MediaEffectsCatalog.startingIntensity,
                value: look.effect?.kind == kind
                    ? (look.effect?.intensity ?? 0)
                    : MediaEffectsCatalog.startingIntensity
            )
        }
        refreshFocus()
        refreshPills()
        reveal(target)
    }

    /// Scrolls the chosen pill fully into the row.
    ///
    /// ⚠️ **AND LEAVES THE ROW ALONE WHEN IT IS ALREADY THERE.**
    /// `scrollRectToVisible` on a rect that is already visible still moves the
    /// row, because the rect is inset by a margin the row does not owe it:
    /// measured, a tap on the first pill slid everything 16pt sideways under
    /// the finger that had just aimed at it.
    private func reveal(_ target: Focus) {
        let pill: UIView?
        switch target {
        case .dial(let key): pill = dialPills[key]
        case .effect(let kind): pill = effectPills[kind]
        }
        guard let pill, scroller.bounds.width > 0 else { return }
        layoutIfNeeded()
        let frame = pill.convert(pill.bounds, to: scroller)
        let showing = CGRect(
            x: scroller.contentOffset.x + scroller.contentInset.left, y: 0,
            width: scroller.bounds.width - scroller.contentInset.left - scroller.contentInset.right,
            height: scroller.bounds.height
        )
        guard frame.minX < showing.minX || frame.maxX > showing.maxX else {
            revealed = nil
            return
        }
        revealed = frame
        scroller.scrollRectToVisible(frame.insetBy(dx: -Spacing.lg, dy: 0), animated: window != nil)
    }

    /// ⚠️ **CHOOSING AN EFFECT LAYS NOTHING ON — IT HANDS OVER THE RULER.** The
    /// strength starts at nothing (`startingIntensity`) and the author raises
    /// it; an effect that arrived at full left them turning DOWN a picture they
    /// had not asked for. Announced all the same, because zero IS the new value
    /// when another effect was on.
    private func choose(_ kind: LookEffectKind) {
        guard look.effect?.kind != kind else {
            focus(on: .effect(kind))
            return
        }
        let had = look.effect
        look.effect = LookEffect(kind: kind, intensity: MediaEffectsCatalog.startingIntensity)
        focus(on: .effect(kind))
        if had != look.effect { onEffect?(look.effect, false) }
    }

    private func rulerMoved(to value: Double, tracking: Bool) {
        switch focus {
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
    /// the row. It is always up — the row has no empty state — so a false here
    /// is a defect, not a mode.
    var debugShowsRuler: Bool {
        !ruler.isHidden && ruler.alpha > 0 && ruler.isUserInteractionEnabled
    }
    /// Internal for tests: whether the row is on screen and takes touches.
    var debugShowsRow: Bool { !scroller.isHidden && scroller.alpha > 0 && scroller.isUserInteractionEnabled }
    /// Internal for tests: where the ruler and the row sit, in this view.
    var debugRulerFrame: CGRect { ruler.frame }
    var debugRowFrame: CGRect { scrollerHost.frame }
    /// Internal for tests: a tap on a dial's pill.
    func debugTapDial(_ key: LookAdjustments.Key) { dialPills[key]?.onTap?() }
    /// Internal for tests: a tap on an effect's pill.
    func debugTapEffect(_ kind: LookEffectKind) { effectPills[kind]?.onTap?() }
    /// Internal for tests: a tap on the ⊘ icon, and on the ↺ one.
    func debugTapClear() { clearButton.sendActions(for: .primaryActionTriggered) }
    func debugTapRevert() { revertButton.sendActions(for: .primaryActionTriggered) }
    /// Internal for tests: whether each icon has anything to do.
    var debugCanClear: Bool { clearButton.isEnabled }
    var debugCanRevert: Bool { revertButton.isEnabled }
    /// Internal for tests: the two icons, to read where they stand over the row.
    var debugIconsFrame: CGRect { icons.frame }
    /// Internal for tests: the mask that dissolves a pill passing behind them —
    /// on the HOST, and framed in the host's own bounds.
    var debugMaskIsOnTheHost: Bool { scrollerHost.layer.mask === fadeOut }
    var debugFadeFrame: CGRect { fadeOut.frame }
    var debugFadeStops: [Double] { (fadeOut.locations ?? []).map(\.doubleValue) }
    /// Internal for tests: where the row comes to rest — past the ramp — and
    /// what it keeps at the other end.
    var debugRowInset: CGFloat { scroller.contentInset.left }
    var debugRowTrailingInset: CGFloat { scroller.contentInset.right }
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
        (Array(dialPills.values) + Array(effectPills.values))
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
    /// Internal for tests: what the last reveal scrolled to, nil when it left
    /// the row where it was.
    var debugRevealed: CGRect? { revealed }
    /// Internal for tests: how far the row is scrolled, and where a pill sits
    /// in it.
    var debugRowOffset: CGFloat {
        get { scroller.contentOffset.x }
        set { scroller.contentOffset.x = newValue }
    }
    func debugPillFrame(_ key: LookAdjustments.Key) -> CGRect? {
        dialPills[key].map { $0.convert($0.bounds, to: scroller) }
    }
    /// Internal for tests: the width the row shows, inside its insets.
    var debugRowWindow: CGFloat {
        scroller.bounds.width - scroller.contentInset.left - scroller.contentInset.right
    }
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

// MARK: - Arriving

extension MediaEffectsToolsView: PoppingTenant {
    /// ⚠️ **THE TWO FIXED ICONS FIRST, THEN THE PILLS.** They stand over the
    /// leading end of the row and the pills pass behind them; arriving after
    /// the pills they would appear on top of a row that had already settled,
    /// which reads as a second thing happening rather than as one row landing.
    /// The ruler is not among them — it is the readout of whatever is chosen,
    /// and it is drawn by `MediaValueRulerView`'s own reveal.
    var poppableElements: [UIView] { icons.arrangedSubviews + row.arrangedSubviews }
    var revealingSurfaces: [RevealingSurface] { [ruler] }
}
