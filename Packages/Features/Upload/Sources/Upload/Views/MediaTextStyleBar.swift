import DesignSystem
import MediaPlayback
import UIKit

extension OverlayFont {
    /// What the style bar calls the typeface.
    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        case .condensed: "Condensed"
        case .marker: "Marker"
        case .typewriter: "Typewriter"
        case .script: "Script"
        }
    }

    /// The names the four families with no system design are set in.
    ///
    /// ⚠️ **ASKED OF THE RUNTIME BY A TEST, NOT ASSUMED.** `UIFont(name:)`
    /// answers nil for a name that does not resolve and nothing errors — the
    /// text would quietly come out in the system face.
    static let namedFaces: [OverlayFont: String] = [
        .condensed: "AvenirNextCondensed-Bold",
        .marker: "MarkerFelt-Wide",
        .typewriter: "AmericanTypewriter-Bold",
        .script: "SnellRoundhand-Bold"
    ]

    /// The face the editor draws this typeface in — while typing, and on the
    /// canvas until the rasteriser can draw it (`MediaOverlayItemView`).
    func editorFont(ofSize size: CGFloat) -> UIFont {
        let bold = UIFont.systemFont(ofSize: size, weight: .bold)
        switch self {
        case .classic:
            return bold
        case .rounded:
            return bold.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? bold
        case .serif:
            return bold.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? bold
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .bold)
        case .condensed, .marker, .typewriter, .script:
            return Self.namedFaces[self].flatMap { UIFont(name: $0, size: size) } ?? bold
        }
    }
}

extension OverlayColour {
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            r: min(max(red, 0), 1), g: min(max(green, 0), 1),
            b: min(max(blue, 0), 1), a: min(max(alpha, 0), 1)
        )
    }

    /// Whether dark ink reads better on this colour than white does.
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.6 }
}

extension TextOverlay {
    /// A new block of text, before anything is typed.
    static let fresh = TextOverlay(text: "")
}

/// The eight inks the bar offers, and what VoiceOver calls them.
enum MediaTextPalette {
    static let swatches: [(name: String, colour: OverlayColour)] = [
        ("White", .white),
        ("Black", .black),
        ("Red", OverlayColour(r: 1, g: 0.23, b: 0.19)),
        ("Orange", OverlayColour(r: 1, g: 0.58, b: 0)),
        ("Yellow", OverlayColour(r: 1, g: 0.8, b: 0)),
        ("Green", OverlayColour(r: 0.2, g: 0.78, b: 0.35)),
        ("Blue", OverlayColour(r: 0, g: 0.48, b: 1)),
        ("Pink", OverlayColour(r: 1, g: 0.18, b: 0.33))
    ]

    static func name(of colour: OverlayColour) -> String {
        swatches.first { $0.colour == colour }?.name ?? "Custom"
    }
}

/// The row of text styles over the keyboard: typeface, ink, what is behind the
/// words, and how the lines line up — one glass capsule running the width of
/// the keyboard, with the controls scrolling inside it.
///
/// ```
/// ┌───────────────────────────────────────────┐
/// │ [≡][A̲] | Classic Rounded … | ● ● ● ● ● ◐  │
/// └───────────────────────────────────────────┘
///   q  w  e  r  t  y  u  i  o  p
/// ```
///
/// ⚠️ **AN `inputAccessoryView` IS THE WINDOW'S WIDTH, SO "FULL-WIDTH CAPSULE"
/// IS A CAPSULE INSIDE INSETS.** UIKit sizes and places this view itself, edge
/// to edge, and a capsule drawn edge to edge has its curves cut off by the
/// screen: it reads as a bar with two bites out of it. The view therefore stays
/// the full width and carries nothing of its own — no colour, no material — and
/// the one glass host is inset `Metrics.ends` from each end and
/// `Metrics.clearance` from top and bottom. The bar's height is the capsule
/// plus that clearance twice, which is why `height` is arithmetic and not a
/// number.
///
/// ⚠️ **ONE MATERIAL, AND IT IS THE HOUSE'S.** `GlassCapsule.wrap` is copied,
/// not re-invented: its note records that the corner shape MUST be
/// `cornerConfiguration` and never `clipsToBounds` plus a layer radius, or the
/// shape is not part of what UIKit interpolates and the capsule flashes as a
/// hard square. The 0.35 black plate this bar used to wear is gone with it —
/// a colour under glass reads as two surfaces.
///
/// ⚠️ **IT STORES NOTHING.** It says what was chosen through `onChange` and
/// shows what it is told through `show(_:)`; the composer owns the style, and
/// the overlay mode owns what is stored.
@MainActor
final class MediaTextStyleBar: UIView {
    private enum Metrics {
        /// The tallest control in the row — the two cycle buttons and the font
        /// chips all stand 44pt, a finger's own target.
        static let control: CGFloat = 44
        /// The glass itself: the controls with 4pt of material above and below,
        /// which is the 52pt this bar has always been.
        static let capsule: CGFloat = 52
        /// Between the capsule and the ends of the window.
        static let ends: CGFloat = Spacing.md
        /// Above and below the capsule, so the glass floats clear of the
        /// keyboard's top edge instead of being welded to it.
        static let clearance: CGFloat = Spacing.sm
        /// How far the first and last control stand from the capsule's ends.
        ///
        /// ⚠️ **MEASURED OFF THE CURVE, NOT PICKED.** A capsule 52pt tall has a
        /// 26pt radius; a 44pt control centred in it spans 4pt to 48pt, and at
        /// 4pt from the top the capsule's own edge is already
        /// `26 − √(26² − 22²) = 12.14pt` in from the bounding box. A control
        /// flush against that box would have its corner eaten by the glass.
        /// 14pt clears it with under two points to spare.
        static let inner: CGFloat = 14
    }

    /// The capsule plus its clearance, twice — 68pt at the current metrics.
    static var height: CGFloat { Metrics.capsule + 2 * Metrics.clearance }

    /// Called with the whole style after any control changed it.
    var onChange: ((TextOverlay) -> Void)?

    private(set) var style = TextOverlay.fresh

    private let scroller: ChipScrollView
    private let row = UIStackView()
    private let glass: UIVisualEffectView
    private let backgroundButton = UIButton(type: .system)
    private let alignmentButton = UIButton(type: .system)
    private var fontButtons: [OverlayFont: UIButton] = [:]
    private var swatchButtons: [UIButton] = []
    private let well = UIColorWell()

    override init(frame: CGRect) {
        // ⚠️ **BUILT FROM LOCALS, BECAUSE `wrap` TAKES THE SCROLLER.** A
        // designated initialiser may not touch `self` until every stored
        // property is set and `super.init` has run, so the scroller is made
        // here, handed to `wrap`, and both are stored in the same breath.
        let scroller = ChipScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.backgroundColor = .clear
        self.scroller = scroller
        // ⚠️ **THE SCROLLER IS CLIPPED AND THE CAPSULE IS WHAT CLIPS IT.**
        // `cornerConfiguration` gives the host its shape, so clipping there
        // follows the curve rather than squaring it off — which is what a
        // layer-masked radius would have done. Without it a chip scrolled to
        // the end would slide out past the glass and hang in mid-air.
        let glass = GlassCapsule.wrap(scroller)
        glass.clipsToBounds = true
        self.glass = glass
        super.init(frame: CGRect(x: 0, y: 0, width: frame.width, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear

        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        addSubview(glass)
        NSLayoutConstraint.activate([
            // ⚠️ **PINNED TO THE SAFE AREA, NOT THE EDGES.** In landscape on a
            // notched phone the accessory view still spans the window, and a
            // capsule inset from the raw edge would sit under the sensor
            // housing on one side and float on the other.
            glass.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Metrics.ends
            ),
            glass.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Metrics.ends
            ),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.clearance),
            glass.heightAnchor.constraint(equalToConstant: Metrics.capsule),
            // ⚠️ `wrap` PINS leading, trailing AND centerY — NEVER A HEIGHT,
            // which `MediaAccessNoticeView` also has to make up. A scroll view
            // with no height is a scroll view that shows nothing.
            scroller.heightAnchor.constraint(equalTo: glass.contentView.heightAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: Metrics.inner
            ),
            row.trailingAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -Metrics.inner
            ),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        ])

        for button in [backgroundButton, alignmentButton] {
            button.tintColor = .white
            button.widthAnchor.constraint(equalToConstant: Metrics.control).isActive = true
            button.heightAnchor.constraint(equalToConstant: Metrics.control).isActive = true
            row.addArrangedSubview(button)
        }
        backgroundButton.addAction(UIAction { [weak self] _ in self?.cycleBackground() }, for: .touchUpInside)
        alignmentButton.addAction(UIAction { [weak self] _ in self?.cycleAlignment() }, for: .touchUpInside)
        row.addArrangedSubview(Self.divider())

        for font in OverlayFont.allCases {
            var configuration = UIButton.Configuration.plain()
            configuration.attributedTitle = AttributedString(
                font.displayName, attributes: AttributeContainer([.font: font.editorFont(ofSize: 15)])
            )
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            let button = UIButton(configuration: configuration)
            button.tintColor = .white
            // ⚠️ **A PILL INSIDE A PILL, AND `cornerConfiguration` IS HOW.** A
            // 15pt radius on a 44pt-tall chip is a rounded rectangle sitting
            // inside a capsule — two different corner languages a few points
            // apart, which is what the author saw. `.capsule()` asks UIKit for
            // the shape rather than stating a number, so a chip that grows with
            // Dynamic Type stays a pill instead of turning back into a
            // rectangle; `InlineFilterTrayView` records the rest of the reason.
            button.cornerConfiguration = .capsule()
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.control).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.choose(font) }, for: .touchUpInside)
            fontButtons[font] = button
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(Self.divider())

        for (index, swatch) in MediaTextPalette.swatches.enumerated() {
            let button = UIButton(type: .custom)
            button.backgroundColor = swatch.colour.uiColor
            // The same language as the chips beside them: a 26pt square asked
            // for a capsule is the circle these have always drawn, and it stays
            // one if the size ever moves.
            button.cornerConfiguration = .capsule()
            button.layer.borderColor = UIColor.white.cgColor
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            button.accessibilityLabel = "Colour, \(swatch.name)"
            button.addAction(UIAction { [weak self] _ in self?.choose(MediaTextPalette.swatches[index].colour) },
                             for: .touchUpInside)
            swatchButtons.append(button)
            row.addArrangedSubview(button)
        }
        well.supportsAlpha = false
        well.accessibilityLabel = "Other colour"
        well.addAction(UIAction { [weak self] _ in
            guard let self, let colour = well.selectedColor else { return }
            choose(OverlayColour(colour))
        }, for: .valueChanged)
        row.addArrangedSubview(well)

        show(style)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return line
    }

    /// Shows `style` as chosen, without announcing it.
    func show(_ style: TextOverlay) {
        self.style = style
        for (font, button) in fontButtons {
            let isChosen = font == style.font
            button.backgroundColor = isChosen ? UIColor.white.withAlphaComponent(0.25) : .clear
            button.accessibilityLabel = "Font, \(font.displayName)"
            button.accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
        for (index, button) in swatchButtons.enumerated() {
            let isChosen = MediaTextPalette.swatches[index].colour == style.colour
            button.layer.borderWidth = isChosen ? 3 : 1
            button.accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
        backgroundButton.setImage(UIImage(systemName: Self.symbol(for: style.background)), for: .normal)
        backgroundButton.accessibilityLabel = "Background, \(Self.name(for: style.background))"
        alignmentButton.setImage(UIImage(systemName: Self.symbol(for: style.alignment)), for: .normal)
        alignmentButton.accessibilityLabel = "Alignment, \(Self.name(for: style.alignment))"
    }

    static func symbol(for background: TextBackground) -> String {
        switch background {
        case .none: "character"
        case .highlight: "character.textbox"
        case .box: "square.fill"
        }
    }

    static func name(for background: TextBackground) -> String {
        switch background {
        case .none: "None"
        case .highlight: "Highlight"
        case .box: "Box"
        }
    }

    static func symbol(for alignment: OverlayTextAlignment) -> String {
        switch alignment {
        case .leading: "text.alignleft"
        case .centre: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    static func name(for alignment: OverlayTextAlignment) -> String {
        switch alignment {
        case .leading: "Left"
        case .centre: "Centre"
        case .trailing: "Right"
        }
    }

    private func announce(_ mutate: (inout TextOverlay) -> Void) {
        var next = style
        mutate(&next)
        show(next)
        onChange?(next)
    }

    func choose(_ font: OverlayFont) { announce { $0.font = font } }

    func choose(_ colour: OverlayColour) { announce { $0.colour = colour } }

    /// none → highlight → box → none.
    func cycleBackground() {
        announce { style in
            let all = TextBackground.allCases
            style.background = all[(all.firstIndex(of: style.background)! + 1) % all.count]
        }
    }

    /// centre → trailing → leading → centre, as the order of `allCases` says.
    func cycleAlignment() {
        announce { style in
            let all = OverlayTextAlignment.allCases
            style.alignment = all[(all.firstIndex(of: style.alignment)! + 1) % all.count]
        }
    }

    /// Internal for tests: the controls, to read what they say.
    var debugBackgroundButton: UIButton { backgroundButton }
    var debugAlignmentButton: UIButton { alignmentButton }
    func debugFontButton(_ font: OverlayFont) -> UIButton? { fontButtons[font] }
    /// Internal for tests: every material in the bar's subtree. There must be
    /// exactly one.
    var debugMaterials: [UIVisualEffectView] { Self.materials(in: self) }
    /// Internal for tests: where the capsule is DRAWN, in the bar's points.
    var debugCapsuleFrame: CGRect { glass.convert(glass.bounds, to: self) }
    /// Internal for tests: the radius the capsule's corners actually RESOLVE
    /// to, asked of UIKit through the `cornerConfiguration` it was given —
    /// which is the shape as drawn, not a number somebody stored.
    func debugCapsuleRadius(_ corner: UIRectCorner) -> CGFloat {
        glass.effectiveRadius(corner: corner)
    }
    /// Internal for tests: the layer radius the capsule is NOT cut with. See
    /// `GlassCapsule` — a layer-masked radius is not part of what UIKit
    /// interpolates, and the capsule flashes square.
    var debugCapsuleLayerRadius: CGFloat { glass.layer.cornerRadius }
    /// Internal for tests: every control that carries a shape of its own, and
    /// the radius each one RESOLVES to — the chips and the swatches, asked of
    /// UIKit rather than read back off a number somebody stored.
    var debugShapedControls: [(view: UIView, radius: CGFloat, asksForAShape: Bool)] {
        (Array(fontButtons.values) + swatchButtons).map {
            ($0, $0.effectiveRadius(corner: .topLeft), $0.cornerConfiguration != nil)
        }
    }
    /// Internal for tests: the scroller, and where its first control sits
    /// inside the capsule.
    var debugScroller: UIScrollView { scroller }
    var debugFirstControlFrame: CGRect? {
        row.arrangedSubviews.first.map { $0.convert($0.bounds, to: glass) }
    }

    private static func materials(in view: UIView) -> [UIVisualEffectView] {
        view.subviews.flatMap { subview -> [UIVisualEffectView] in
            (subview as? UIVisualEffectView).map { [$0] } ?? materials(in: subview)
        }
    }
}
