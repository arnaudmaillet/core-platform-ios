import DesignSystem
import UIKit

/// What the band holds while "Crop" is the chosen mode: the straightening dial,
/// a row of shapes to hold the box to, and the two buttons that undo.
///
/// ```
///              -5°
///   · · | · · ▼ · · | · · · | · ·        ← StraightenDialView
///  ⟳  ↺   Free  Original  1:1  4:5  →    ← turn, reset, then the shapes
/// ```
///
/// ⚠️ **A HOST FOR THREE CONTROLS, NOT A CONTROL.** It owns placement and
/// forwards; the dial owns degrees. The band it sits in owns neither, which is
/// why all three of them state their own heights.
///
/// ⚠️ **NO BACKGROUND AND NO MATERIAL** — the band's rule, inherited: *"the
/// canvas runs full-bleed underneath and the media is the subject; a plate here
/// would cut the picture in two"*. The lift comes from the editor's dissolve,
/// whose top anchor swaps onto this band the moment it opens.
@MainActor
final class MediaCropToolsView: UIView {
    private enum Metrics {
        static let chip: CGFloat = 30
        static let chipPadding: CGFloat = 12
        static let button: CGFloat = 30
        /// How far a chip has to travel before it is gone.
        ///
        /// ⚠️ **AND THE SCROLLER CARRIES THE SAME NUMBER AS A LEADING INSET.**
        /// Without it the first chip would rest INSIDE the fade and sit
        /// permanently half-dimmed; with it, a chip is solid where it stops and
        /// dissolves only on its way out.
        /// ⚠️ **WIDE ENOUGH TO READ AS A DISSOLVE, MEASURED ON SCREEN.** At 28 the
        /// ramp was over before the eye registered it and a chip still looked cut
        /// off at a letter; at this width a shape visibly loses itself before it
        /// reaches the buttons. It is roughly one chip.
        static let fade: CGFloat = 52
        static var height: CGFloat { StraightenDialView.height + Spacing.sm + chip }
    }

    nonisolated static var height: CGFloat { Metrics.height }

    var onTurn: ((CGFloat) -> Void)?
    var onTurnSettled: ((CGFloat) -> Void)?
    var onRatio: ((CropRatio) -> Void)?
    var onQuarterTurn: (() -> Void)?
    var onFlip: (() -> Void)?
    /// The fill/fit glyph beside them — see `showFit`.
    var onFit: (() -> Void)?

    private let dial = StraightenDialView()
    private let scroller = ChipScrollView()

    /// ⚠️ **THE MASK GOES ON THIS, NOT ON THE SCROLLER — AND THE FIRST CUT PUT IT
    /// ON THE SCROLLER.** A `UIScrollView`'s `bounds.origin` IS its content
    /// offset, so a mask framed in `scroller.bounds` travels with the content:
    /// set once in `layoutSubviews`, it slid off the viewport on the first drag
    /// and what remained was the hard edge of `clipsToBounds`. Seen on screen as a
    /// chip guillotined mid-letter. This host does not scroll, so its bounds mean
    /// what they say.
    private let scrollerHost = UIView()

    /// The quarter turn and the mirror, standing over the strip.
    private lazy var turns: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [quarterTurn, flip, fitGlyph])
        stack.axis = .horizontal
        stack.spacing = Spacing.xs
        return stack
    }()

    /// Clear where the buttons stand, solid a chip's-width past them: what a shape
    /// passes through on its way behind them.
    private let fadeOut: CAGradientLayer = {
        let gradient = CAGradientLayer()
        // Two clear stops then two solid ones: everything up to the buttons is
        // gone, and the ramp happens in the gap just past them.
        gradient.colors = [
            UIColor.clear.cgColor, UIColor.clear.cgColor,
            UIColor.black.cgColor, UIColor.black.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }()
    private let row = UIStackView()
    private var chips: [CropRatio: RatioChip] = [:]
    private var chosen: CropRatio = .free

    /// ⚠️ **THE ONLY BUTTON LEFT BESIDE THE SHAPES.** Undo used to stand here too;
    /// it is now a bar item at the top of the screen, in the place the fill/fit
    /// glyph occupies outside this mode. A control that undoes the whole screen's
    /// work belongs with "Next" and the chevron, not in a row of shapes.
    private lazy var quarterTurn = makeButton(
        symbol: "rotate.left", label: "Rotate a quarter turn"
    ) { [weak self] in self?.onQuarterTurn?() }

    /// ⚠️ THE `trianglehead` VARIANT, to sit with the undo arrow in the bar rather
    /// than beside it in an older weight. Both spellings exist in this SDK; the
    /// plain one is the SF Symbols 1 drawing.
    private lazy var flip = makeButton(
        symbol: "arrow.trianglehead.left.and.right.righttriangle.left.righttriangle.right",
        label: "Flip the picture left to right"
    ) { [weak self] in self?.onFlip?() }

    /// ⚠️ **THE FILL/FIT GLYPH LIVES HERE NOW, NOT IN THE HEADER.** Asked for
    /// in those words: *"on va supprimer l'option de fill/fit en haut dans le
    /// header et on va plutôt le mettre dans les options de recadrage à côté
    /// des icônes de rotation et de miroir"*. It belongs with them: all three
    /// say how the picture sits in the frame, and it has nothing to act on
    /// while the author is somewhere else. The row's dissolve follows it for
    /// free — `layoutSubviews` measures the buttons' stack, whatever it holds.
    private lazy var fitGlyph = makeButton(
        symbol: "arrow.down.right.and.arrow.up.left", label: "Fit the picture"
    ) { [weak self] in self?.onFit?() }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        dial.onTurn = { [weak self] angle in self?.onTurn?(angle) }
        dial.onSettle = { [weak self] angle in self?.onTurnSettled?(angle) }

        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        // ⚠️ THE BAND HAS NO BACKGROUND, SO NEITHER DOES THIS — the filter row
        // states the same line for the same scroller.
        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        // ⚠️ **NO CLIPPING AT ALL — THE MASK IS THE ONLY THING THAT TAKES A CHIP
        // AWAY.** A hard clip and a gradient fight for the same pixels, and the
        // clip wins: that is precisely the sharp edge this replaced.
        scroller.clipsToBounds = false
        scroller.addSubview(row)

        scrollerHost.clipsToBounds = false
        scrollerHost.layer.mask = fadeOut
        scroller.pin(to: scrollerHost)

        for ratio in CropRatio.allCases {
            let chip = RatioChip(ratio: ratio, height: Metrics.chip, padding: Metrics.chipPadding)
            chip.onTap = { [weak self] in self?.pick(ratio) }
            chips[ratio] = chip
            row.addArrangedSubview(chip)
        }
        chips[.free]?.setChosen(true)

        dial.constrain(in: self) { view in
            dial.topAnchor.constraint(equalTo: view.topAnchor)
            dial.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            dial.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        }
        // ⚠️ **THE STRIP RUNS THE WHOLE WIDTH AND PASSES BEHIND THE BUTTONS —
        // AND IT IS ADDED FIRST, WHICH IS WHAT PUTS THEM ON TOP.** `constrain(in:)`
        // begins with `addSubview`, so the order of these two blocks IS the z
        // order. The strip used to begin where the buttons end, which is why a
        // chip could only ever stop at a hard edge: there was nothing for it to
        // travel through. What keeps a chip from being SEEN under a button is the
        // gradient, not this ordering — the ordering is what makes the buttons
        // legible while it happens.
        scrollerHost.constrain(in: self) { view in
            scrollerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            scrollerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            scrollerHost.topAnchor.constraint(equalTo: dial.bottomAnchor, constant: Spacing.sm)
            scrollerHost.heightAnchor.constraint(equalToConstant: Metrics.chip)
        }
        turns.constrain(in: self) { view in
            turns.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg)
            turns.topAnchor.constraint(equalTo: scrollerHost.topAnchor)
            turns.heightAnchor.constraint(equalToConstant: Metrics.chip)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **A MASK, NOT A GRADIENT VIEW LAID ON TOP.** The band has no background
    /// of its own — the picture runs underneath it — so a strip painted in the
    /// band's colour would have no colour to paint. Dissolving the shapes
    /// themselves is the only way to make them disappear into whatever happens to
    /// be behind them.
    ///
    /// ⚠️ AND THE FRAME IS SET WITH ACTIONS OFF. A layer that is not a view's
    /// backing layer animates its own `frame` implicitly over a quarter second, so
    /// the mask would lag a rotation of the device behind the strip it masks.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = scrollerHost.bounds.width
        guard width > 0 else { return }

        // ⚠️ **THE RESTING PLACE IS PAST THE RAMP.** Without this inset the first
        // shape would come to rest inside the fade and sit permanently half
        // dissolved; with it, a shape is solid where it stops and dissolves only
        // on its way out.
        let behind = turns.frame.maxX
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

    /// States the tools' position without announcing it — for adopting what a
    /// picture already carries when the viewer swipes to it.
    func adopt(angle: CGFloat, ratio: CropRatio) {
        dial.setAngle(angle)
        setChosen(ratio)
    }

    /// States which way the picture is laid, so the glyph offers the OTHER
    /// state — the rule the header's item used to carry.
    func showFit(symbol: String, label: String) {
        fitGlyph.configuration?.image = UIImage(systemName: symbol)
        fitGlyph.accessibilityLabel = label
    }

    private func pick(_ ratio: CropRatio) {
        setChosen(ratio)
        onRatio?(ratio)
    }

    private func setChosen(_ ratio: CropRatio) {
        guard ratio != chosen else { return }
        chips[chosen]?.setChosen(false)
        chosen = ratio
        chips[ratio]?.setChosen(true)
    }

    private func makeButton(
        symbol: String, label: String, action: @escaping () -> Void
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

    /// One shape the box can be held to.
    private final class RatioChip: UIControl {
        var onTap: (() -> Void)?
        private let caption = UILabel()

        init(ratio: CropRatio, height: CGFloat, padding: CGFloat) {
            super.init(frame: .zero)
            caption.text = ratio.name
            caption.font = .systemFont(ofSize: 13, weight: .semibold)
            caption.textAlignment = .center
            caption.isUserInteractionEnabled = false
            caption.constrain(in: self) { view in
                caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding)
                caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding)
                caption.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            }
            heightAnchor.constraint(equalToConstant: height).isActive = true
            layer.cornerCurve = .continuous
            addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityLabel = ratio.name
            setChosen(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Shape before anything reads it, the rule `IconSelectorBar` states:
            // a radius set after a fill has already drawn shows one frame of
            // square corners.
            layer.cornerRadius = bounds.height / 2
        }

        func setChosen(_ isChosen: Bool) {
            // ⚠️ ONE MATERIAL, NEVER TWO — and here, none at all. The band carries
            // no plate, so a chosen chip is a tint and an unchosen one is a
            // hairline, exactly as `IconSelectorBar`'s lens is a tinted view
            // rather than a second glass.
            chosen = isChosen
            backgroundColor = isChosen ? .label : UIColor.label.withAlphaComponent(0.12)
            caption.textColor = isChosen ? .systemBackground : .label
            accessibilityTraits = isChosen ? [.button, .selected] : .button
        }

        /// ⚠️ **A FLAG, NOT THE INK.** This read `caption.textColor == .black`,
        /// which was true only while the chosen colour happened to be literal
        /// black; the moment the ink became semantic it answered false for every
        /// chip and the suite would have gone quiet rather than red.
        private var chosen = false
        var debugIsChosen: Bool { chosen }
        var debugInk: UIColor { caption.textColor }
        var debugGround: UIColor { backgroundColor ?? .systemBackground }
    }
}

extension MediaCropToolsView {
    /// Internal for tests: the dial itself, to drive a turn without a finger.
    var debugDial: StraightenDialView { dial }
    /// Internal for tests: which shape is showing as chosen.
    var debugChosenRatio: CropRatio? {
        chips.first { $0.value.debugIsChosen }?.key
    }
    /// Internal for tests: the path a tap on a shape takes.
    func debugPick(_ ratio: CropRatio) { pick(ratio) }
    /// Internal for tests: every ink in the band with the ground it actually sits
    /// on, so a test can ask whether each pair is legible in both appearances.
    ///
    /// ⚠️ **THE PAIR, NOT THE INK ALONE.** A chosen shape's caption IS the
    /// screen's background colour — it is legible because it sits on a pill of the
    /// opposite one. A test that held every ink against the SCREEN's ground called
    /// that illegible, which is how this shape came to be.
    var debugInks: [(name: String, ink: UIColor, ground: UIColor)] {
        var inks: [(String, UIColor, UIColor)] = []
        if let readout = dial.debugInk {
            inks.append(("the dial's readout", readout, .systemBackground))
        }
        if let button = quarterTurn.configuration?.baseForegroundColor {
            inks.append(("the quarter turn", button, .systemBackground))
        }
        if let chip = chips[.free] {
            inks.append(("a chosen shape", chip.debugInk, chip.debugGround))
        }
        if let chip = chips[.square] {
            inks.append(("an unchosen shape", chip.debugInk, .systemBackground))
        }
        return inks
    }

    /// Internal for tests: the paths the two buttons take.
    func debugTapQuarterTurn() { onQuarterTurn?() }
    func debugTapFlip() { onFlip?() }
    /// Internal for tests: the fill/fit glyph — the path a tap takes, and what
    /// it is offering.
    func debugTapFit() { onFit?() }
    var debugFitLabel: String? { fitGlyph.accessibilityLabel }
    /// Internal for tests: the glyphs these buttons actually resolved to. A name
    /// that does not exist in the running SDK gives nil and draws nothing.
    /// ⚠️ **WHAT STANDS IN THE ROW, NOT WHAT WAS BUILT.** This used to list the
    /// buttons by name, so a button left out of the stack — present, configured
    /// and invisible — read as present.
    var debugGlyphs: [UIImage?] {
        turns.arrangedSubviews.map { ($0 as? UIButton)?.configuration?.image }
    }
}

// MARK: - Arriving

extension MediaCropToolsView: PoppingTenant {
    /// The turn, the mirror and the fill/fit glyph, then the shapes. The dial
    /// is not among them: it is a continuous ruler, and it has a reveal of its
    /// own.
    var poppableElements: [UIView] { turns.arrangedSubviews + row.arrangedSubviews }
    var revealingSurfaces: [RevealingSurface] { [dial] }
}
