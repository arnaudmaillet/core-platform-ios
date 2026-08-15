import DesignSystem
import UIKit

/// One Liquid Glass filter pill, shared by the main filter bar and the
/// sub-filter bar. Sized by its content — text pills are dynamic-width
/// capsules; icon-only pills (no title) pin width to height and render as
/// perfect circles (capsule corners on a square).
///
/// Configured PLAIN at init; the glass configuration materializes on first
/// window attach — the house doctrine (`SnapRailBoostButton`, #46):
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
        /// Morphing pills (the icon primaries): compact icon-only circle at
        /// rest, expanding into an icon + title capsule while selected. The
        /// owning bar animates the layout pass so neighbors shift smoothly.
        let expandsWhenSelected: Bool

        init(
            title: String?,
            symbolName: String,
            selectedSymbolName: String,
            accessibilityLabel: String,
            expandsWhenSelected: Bool = false
        ) {
            self.title = title
            self.symbolName = symbolName
            self.selectedSymbolName = selectedSymbolName
            self.accessibilityLabel = accessibilityLabel
            self.expandsWhenSelected = expandsWhenSelected
        }
    }

    /// The pill's hard width ceiling, and the share of the screen it may
    /// never exceed. Titles are user content — a display name like
    /// "Maximilian Schwarzenberger-Ulrichsdottir" would otherwise mint a
    /// capsule wider than the bar, pushing every sibling primary past the
    /// fold and leaving nothing to scroll back to. Half the screen keeps at
    /// least one neighbour (and the sub bar's fixed button) in view on small
    /// devices; the 200pt ceiling stops an iPad from minting a banner.
    static let widthCeiling: CGFloat = 200
    static let widthScreenShare: CGFloat = 0.5

    /// The resolved cap for a given screen width — pure, so the sizing rule
    /// is testable without a window.
    static func maxWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        min(widthCeiling, screenWidth * widthScreenShare)
    }

    private(set) var content: Content
    /// The pill's fixed height — and, for a circular pill, its diameter. Held
    /// because the avatar is cropped to fit it: a thumbnail sized by a
    /// constant cannot follow a bar that changes size.
    private let height: CGFloat
    private var hasGlass = false
    private var isSelectedAppearance = false
    /// Circular avatar thumbnail replacing the symbol (people pills). Set
    /// async once the pipeline resolves; nil keeps the symbol placeholder.
    private var avatarImage: UIImage?

    /// The pill currently renders as a perfect circle: permanently for
    /// title-less pills, at rest for morphing (`expandsWhenSelected`) ones.
    private var isCircular: Bool {
        content.title == nil || (content.expandsWhenSelected && !isSelectedAppearance)
    }

    /// Pins width to height while circular; deactivated when a morphing pill
    /// expands, handing width back to the intrinsic icon + title + insets.
    private lazy var circleConstraint = widthAnchor.constraint(equalTo: heightAnchor)

    /// The cap. Always active — a circle's `width == height` sits far below
    /// it, so only overlong capsules ever feel it. Its constant is retuned to
    /// the real screen on window attach.
    private lazy var maxWidthConstraint = widthAnchor.constraint(
        lessThanOrEqualToConstant: Self.widthCeiling
    )

    init(content: Content, height: CGFloat) {
        self.content = content
        self.height = height
        super.init(frame: .zero)
        configuration = makeConfiguration(glass: false, selected: false)
        accessibilityLabel = content.accessibilityLabel
        // The pill activates its own height / circle / cap constraints, so it
        // is an Auto Layout view by construction — leaving the autoresizing
        // translation on would let a frame-sized parent fight them (and makes
        // `systemLayoutSizeFitting` measure the bare content instead).
        translatesAutoresizingMaskIntoConstraints = false
        // Fixed height (the bar-bubble family). Width: circles pin to the
        // height (capsule corners → a circle); text pills stay intrinsic —
        // strictly content-determined, never constrained.
        heightAnchor.constraint(equalToConstant: height).isActive = true
        circleConstraint.isActive = isCircular
        maxWidthConstraint.isActive = true
        // Width is sacred: hug the content and resist compression, so no
        // stack/scroll ambiguity can ever stretch or squeeze a pill away
        // from its intrinsic avatar + title + insets width. Compression
        // resistance stops ONE point short of required — the cap is the only
        // force allowed to win against the intrinsic width, and a required
        // resistance would make an overlong title an unsatisfiable conflict
        // (UIKit would break one of them, arbitrarily, and log).
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required - 1, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hasGlass {
            hasGlass = true
            configuration = makeConfiguration(glass: true, selected: isSelectedAppearance)
        }
        updateMaxWidth()
    }

    override func layoutSubviews() {
        // Rotation / iPad split-view resizes change the share; the guard
        // inside makes this a no-op in every ordinary pass (a constant that
        // never changes can't retrigger layout).
        updateMaxWidth()
        super.layoutSubviews()
    }

    /// Retunes the cap to the CONTAINING WINDOW rather than the physical
    /// screen — under iPad multitasking the window is the real estate the bar
    /// actually has, and "half the screen" would let a pill fill a slim
    /// column edge to edge.
    private func updateMaxWidth() {
        guard let containerWidth = window?.bounds.width, containerWidth > 0 else { return }
        let cap = Self.maxWidth(forScreenWidth: containerWidth)
        guard abs(maxWidthConstraint.constant - cap) > 0.5 else { return }
        maxWidthConstraint.constant = cap
    }

    /// The tactile press: a quick dip to 95% on touch-down, a springy bounce
    /// back on release. Lives HERE so the sub bar's fixed leading button gets
    /// it natively from its own tracking, and collection cells get the
    /// identical feel by forwarding their highlight state — one code path,
    /// uniform response. (The glass material's own pressed look rides the
    /// same `isHighlighted` change via the configuration system.)
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                UIView.animate(
                    withDuration: 0.12, delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
                ) {
                    self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
                }
            } else {
                UIView.animate(
                    springDuration: 0.3, bounce: 0.3,
                    delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.transform = .identity
                }
            }
        }
    }

    /// Selection swap. Content and shape land atomically (no implicit width
    /// animation — the accordion doctrine); when the swap changes the pill's
    /// footprint (a morphing primary, a weight shift), the OWNING BAR runs
    /// the animated layout pass so frames glide while content is already
    /// final.
    func setSelectedAppearance(_ selected: Bool) {
        guard selected != isSelectedAppearance else { return }
        isSelectedAppearance = selected
        circleConstraint.isActive = isCircular
        UIView.performWithoutAnimation {
            configuration = makeConfiguration(glass: hasGlass, selected: selected)
        }
    }

    /// Swaps what the pill represents (collection cells reconfigure across
    /// reuse). Atomic like every structural change; clears any stale avatar —
    /// the owner re-resolves it for the new identity.
    func setContent(_ newContent: Content) {
        guard newContent != content else { return }
        content = newContent
        avatarImage = nil
        accessibilityLabel = newContent.accessibilityLabel
        circleConstraint.isActive = isCircular
        UIView.performWithoutAnimation {
            configuration = makeConfiguration(glass: hasGlass, selected: isSelectedAppearance)
        }
    }

    /// Swaps the symbol for a real avatar, pre-cropped to a circle sized for
    /// the pill. The raw image is rendered once here, not per configuration.
    func setAvatar(_ image: UIImage?) {
        avatarImage = image.map { Self.circularThumbnail(from: $0, diameter: avatarDiameter) }
        applyConfiguration()
    }

    /// Configuration swaps can change intrinsic width (weight shift on
    /// selection, avatar insets on arrival). Landing them inside an implicit
    /// animation makes the stack interpolate widths — the accordion. Apply
    /// structure atomically instead: new width takes effect in one frame.
    private func applyConfiguration() {
        UIView.performWithoutAnimation {
            configuration = makeConfiguration(glass: hasGlass, selected: isSelectedAppearance)
            superview?.layoutIfNeeded()
        }
    }

    /// How much glass is left showing around a circular pill's avatar.
    ///
    /// A hairline, not a margin: the photo IS the pill, and the ring exists
    /// only so the glass edge still reads as an edge against a busy map. In a
    /// capsule (a titled pill) the avatar is a leading thumbnail instead, and
    /// keeps its old proportions.
    static let avatarInset: CGFloat = 2

    /// The avatar's rendered diameter for a pill of this size — pure, so the
    /// rule is testable without a window (the same shape `maxWidth` takes).
    ///
    /// Derived from the pill, never a constant: it was pinned at 20pt, so a
    /// 40pt circle showed a photo half its own width floating in glass. A
    /// CAPSULE keeps the small thumbnail — there the avatar sits beside a
    /// title and must not crowd it.
    static func avatarDiameter(forPillHeight height: CGFloat, isCircular: Bool) -> CGFloat {
        isCircular ? height - avatarInset * 2 : capsuleAvatarDiameter
    }

    /// The leading thumbnail's diameter inside a titled capsule.
    static let capsuleAvatarDiameter: CGFloat = 20

    private var avatarDiameter: CGFloat {
        Self.avatarDiameter(forPillHeight: height, isCircular: isCircular)
    }

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

    /// What the pill actually renders. Identity to the caller's title in a
    /// shipping build; under the DEBUG `-maps-long-titles` stress arg every
    /// title grows past the cap, which is the only way to exercise truncation
    /// in-sim (no seeded profile or place category has a name long enough).
    private static func displayTitle(_ title: String) -> String {
        #if DEBUG
        if stressesLongTitles { return "\(title) Maximilian Schwarzenberger-Ulrichsdottir" }
        #endif
        return title
    }

    #if DEBUG
    private static let stressesLongTitles =
        ProcessInfo.processInfo.arguments.contains("-maps-long-titles")
    #endif

    /// The accent, resolved per trait collection: `systemBlue` is already the
    /// selected content colour here, and it brightens in dark mode, which is
    /// what keeps the rim legible when the map goes dark.
    private static let selectionRingColor = UIColor.systemBlue

    private func makeConfiguration(glass: Bool, selected: Bool) -> UIButton.Configuration {
        // Selection is carried by the CONTENT, not the material: a selected
        // pill keeps a neutral frosted lift (soft white fill + subtle
        // hairline, blur live underneath) while its glyph and title turn
        // accent blue — the glass family stays monochrome and the color
        // means exactly one thing. Unselected = resting clear glass with
        // secondary-level content.
        var config: UIButton.Configuration = glass ? .glass() : .plain()
        if selected {
            config.background.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            config.background.strokeColor = UIColor.white.withAlphaComponent(0.25)
            config.background.strokeWidth = 1
        }
        // ...and where the content cannot carry it, the rim does. See
        // `MapPillSelectionRing`: a title-less pill wearing a photograph has
        // no glyph to tint and no label to embolden, so selected and
        // unselected looked identical.
        let ring = MapPillSelectionRing.resolve(selected: selected, isCircular: isCircular)
        if ring.isVisible {
            config.background.strokeColor = Self.selectionRingColor
            config.background.strokeWidth = ring.strokeWidth
            config.background.strokeOutset = ring.outset
        }
        // The halo is set on BOTH branches, never only when lit: these
        // properties hang off a reference type, so a configuration built for
        // a selected pill would otherwise leave its glow on the next pill
        // that reuses the object.
        config.background.shadowProperties.color = Self.selectionRingColor
        config.background.shadowProperties.offset = .zero
        config.background.shadowProperties.radius = ring.glowRadius
        config.background.shadowProperties.opacity = ring.glowOpacity
        // A morphing pill hides its title while resting as a circle; the
        // label only exists in the expanded capsule.
        if let title = content.title, !isCircular {
            config.attributedTitle = AttributedString(
                Self.displayTitle(title),
                attributes: AttributeContainer([
                    .font: UIFont.preferredFont(forTextStyle: .footnote)
                        .withWeight(selected ? .semibold : .medium)
                ])
            )
            // Avatar pills sit the name snugly against the photo; symbol
            // pills keep a hairline gap (glyphs carry whitespace of their
            // own).
            config.imagePadding = avatarImage == nil ? 4 : 6
            // Titles are single-line by contract: at the cap the label is
            // narrower than the text it holds, so it must truncate with an
            // ellipsis — never wrap into a two-line pill inside a
            // fixed-height capsule.
            config.titleLineBreakMode = .byTruncatingTail
        }
        // A real avatar (people pills) beats the symbol; otherwise a lone
        // glyph carries the whole circle — give it more presence than the
        // inline icon that sits beside a label. The tint is BAKED into the
        // symbol image (`.alwaysOriginal`): the glass style applies its own
        // vibrancy to template images and neither `baseForegroundColor` nor
        // an `imageColorTransformer` reliably lands on the glyph.
        let contentColor: UIColor = selected ? .systemBlue : .secondaryLabel
        config.image = avatarImage ?? UIImage(
            systemName: selected ? content.selectedSymbolName : content.symbolName
        )?.withConfiguration(UIImage.SymbolConfiguration(
            // Roughly a third of the circle — the proportion the 13pt glyph
            // struck in the original 40pt pill, kept as the pill grows.
            pointSize: isCircular ? round(height / 3) : 11,
            weight: .semibold
        ))
            .withTintColor(contentColor, renderingMode: .alwaysOriginal)
        config.baseForegroundColor = contentColor
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

extension UIView {
    /// The perceptual length of `mapBarFade`. Public because callers that
    /// SEQUENCE fades need to phrase their timing as a fraction of it rather
    /// than duplicating the number (see `MapSubFilterBarView.transition`).
    static let mapBarFadeDuration: TimeInterval = 0.25

    /// The bars' fade primitive: a critically-damped spring (zero bounce).
    /// Opacity must NEVER overshoot — an alpha bounce reads as flicker, which
    /// is exactly what made the naive all-spring pass feel wrong. The spring
    /// solver still gives the natural ease-out settle of system fades.
    static func mapBarFade(
        _ animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        UIView.animate(
            springDuration: mapBarFadeDuration, bounce: 0,
            delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
            animations: animations, completion: completion
        )
    }

    /// The bars' geometry primitive: a gently underdamped spring for layout
    /// morphs and glides (pill expansion, neighbors shifting) — the subtle
    /// physical settle system components have, without wobble. Interrupted
    /// springs retarget from current position via `.beginFromCurrentState`.
    static func mapBarMorph(
        _ animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        UIView.animate(
            springDuration: 0.32, bounce: 0.18,
            delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
            animations: animations, completion: completion
        )
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
