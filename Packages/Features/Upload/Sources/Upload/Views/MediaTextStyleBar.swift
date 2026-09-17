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
/// words, and how the lines line up.
///
/// ```
/// [≡][A̲] | Classic Rounded Serif … | ● ● ● ● ● ● ● ● ◐
/// ```
///
/// ⚠️ **IT STORES NOTHING.** It says what was chosen through `onChange` and
/// shows what it is told through `show(_:)`; the composer owns the style, and
/// the overlay mode owns what is stored.
@MainActor
final class MediaTextStyleBar: UIView {
    static let height: CGFloat = 52

    /// Called with the whole style after any control changed it.
    var onChange: ((TextOverlay) -> Void)?

    private(set) var style = TextOverlay.fresh

    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private let backgroundButton = UIButton(type: .system)
    private let alignmentButton = UIButton(type: .system)
    private var fontButtons: [OverlayFont: UIButton] = [:]
    private var swatchButtons: [UIButton] = []
    private let well = UIColorWell()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: frame.width, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = UIColor.black.withAlphaComponent(0.35)

        scroller.showsHorizontalScrollIndicator = false
        scroller.backgroundColor = .clear
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.pin(to: self)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: Spacing.md),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -Spacing.md),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        ])

        for button in [backgroundButton, alignmentButton] {
            button.tintColor = .white
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
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
            button.layer.cornerRadius = 15
            button.layer.cornerCurve = .continuous
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.choose(font) }, for: .touchUpInside)
            fontButtons[font] = button
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(Self.divider())

        for (index, swatch) in MediaTextPalette.swatches.enumerated() {
            let button = UIButton(type: .custom)
            button.backgroundColor = swatch.colour.uiColor
            button.layer.cornerRadius = 13
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
}
