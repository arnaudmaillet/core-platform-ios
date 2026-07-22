import DesignSystem
import UIKit

/// One Liquid Glass filter pill, shared by the main filter bar and the
/// sub-filter bar. Sized by its content — text pills are dynamic-width
/// capsules; icon-only pills (no title) pin width to height and render as
/// perfect circles (capsule corners on a square).
///
/// Configured PLAIN at init; the glass configuration materializes on first
/// window attach — the house doctrine (`SnapRailComposeButton`, #46):
/// creating a system material contacts the render server, a multi-second
/// main-thread stall on headless CI simulators, where unit-tested views never
/// join a window and must never pay it.
final class MapPillButton: UIButton {
    /// Pure presentation — the owning bar maps pills back to selections.
    struct Content: Equatable {
        let title: String?
        let symbolName: String
        let selectedSymbolName: String
        let accessibilityLabel: String
    }

    let content: Content
    private var hasGlass = false
    private var isSelectedAppearance = false
    /// Circular avatar thumbnail replacing the symbol (people pills). Set
    /// async once the pipeline resolves; nil keeps the symbol placeholder.
    private var avatarImage: UIImage?

    /// Icon-only pills are perfect circles, not narrow capsules.
    private var isCircular: Bool { content.title == nil }

    init(content: Content, height: CGFloat) {
        self.content = content
        super.init(frame: .zero)
        configuration = makeConfiguration(glass: false, selected: false)
        accessibilityLabel = content.accessibilityLabel
        // Fixed height (the bar-bubble family). Width: circles pin to the
        // height (capsule corners → a circle); text pills stay intrinsic —
        // strictly content-determined, never constrained.
        heightAnchor.constraint(equalToConstant: height).isActive = true
        if isCircular {
            widthAnchor.constraint(equalTo: heightAnchor).isActive = true
        }
        // Width is sacred: hug the content and refuse compression, so no
        // stack/scroll ambiguity can ever stretch or squeeze a pill away
        // from its intrinsic avatar + title + insets width.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hasGlass {
            hasGlass = true
            configuration = makeConfiguration(glass: true, selected: isSelectedAppearance)
        }
    }

    func setSelectedAppearance(_ selected: Bool) {
        guard selected != isSelectedAppearance else { return }
        isSelectedAppearance = selected
        configuration = makeConfiguration(glass: hasGlass, selected: selected)
    }

    /// Swaps the symbol for a real avatar, pre-cropped to a circle sized for
    /// the pill. The raw image is rendered once here, not per configuration.
    func setAvatar(_ image: UIImage?) {
        avatarImage = image.map { Self.circularThumbnail(from: $0, diameter: avatarDiameter) }
        configuration = makeConfiguration(glass: hasGlass, selected: isSelectedAppearance)
    }

    private var avatarDiameter: CGFloat { 20 }

    private static func circularThumbnail(from image: UIImage, diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            // Aspect-fill the circle from the (possibly non-square) source.
            let scale = max(diameter / image.size.width, diameter / image.size.height)
            let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (diameter - scaled.width) / 2, y: (diameter - scaled.height) / 2,
                width: scaled.width, height: scaled.height
            ))
        }
        // Original rendering mode so the tinted foreground color never
        // flattens the photo.
        return rendered.withRenderingMode(.alwaysOriginal)
    }

    private func makeConfiguration(glass: Bool, selected: Bool) -> UIButton.Configuration {
        // Selected = prominent (tinted) glass, unselected = clear glass; the
        // same on/off language as the system's own glass controls. Foregrounds
        // use dynamic colors so pills stay legible over light and dark tiles.
        var config: UIButton.Configuration
        if glass {
            config = selected ? .prominentGlass() : .glass()
        } else {
            config = .plain()
        }
        if let title = content.title {
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([
                    .font: UIFont.preferredFont(forTextStyle: .footnote)
                        .withWeight(selected ? .semibold : .medium)
                ])
            )
            // Avatar pills sit the name snugly against the photo; symbol
            // pills keep a hairline gap (glyphs carry whitespace of their
            // own).
            config.imagePadding = avatarImage == nil ? 4 : 6
        }
        // A real avatar (people pills) beats the symbol; otherwise a lone
        // glyph carries the whole circle — give it more presence than the
        // inline icon that sits beside a label.
        config.image = avatarImage ?? UIImage(
            systemName: selected ? content.selectedSymbolName : content.symbolName
        )?.withConfiguration(UIImage.SymbolConfiguration(pointSize: isCircular ? 13 : 11, weight: .semibold))
        config.baseForegroundColor = selected ? .systemBackground : .label
        if selected { config.baseBackgroundColor = .label }
        // Circles get no insets — the constrained square frame centers the
        // glyph; capsules pad their content. An avatar pill tucks the photo
        // near the capsule's leading curve (the circle itself reads as
        // padding) and keeps standard breathing room after the title.
        config.contentInsets = if isCircular {
            .zero
        } else if avatarImage != nil {
            NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10)
        } else {
            NSDirectionalEdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md)
        }
        // Capsule corners = bounds.height / 2 everywhere: a circle on the
        // square pills, the oval on the dynamic-width ones.
        config.cornerStyle = .capsule
        return config
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
