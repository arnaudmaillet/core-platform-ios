import UIKit

/// A toast's trailing action — "Retry", "View", Undo — as a FILLED capsule
/// (the owner, 2026-11-06, after the system's own pills): a grey ground and
/// its word, semibold, in the app's primary ink — no glyph, no ring. As tall
/// as the leading disc (`ToastBadge.side`).
///
/// The capsule sits inside the toast's own, concentric: as far from the
/// toast's trailing edge as from its top and foot. It is shorter than a
/// touch target, so it takes touches up to 44 pt around it (#1034).
///
/// Until 2026-11-06 Undo drew its countdown as a ring around an arrow
/// (#954); both went with the filled look. The countdown still runs, and
/// still holds for a finger, VoiceOver's focus or an inactive scene
/// (`ToastCountdown`) — it is just not drawn.
@MainActor
class ToastActionButton: UIButton {
    /// The touch target's floor, whatever the capsule's size.
    static let touchTarget: CGFloat = 44
    /// The grey ground, light and dark, and pressed; the word's ink.
    static let ground = UIColor.tertiarySystemFill
    static let pressedGround = UIColor.secondarySystemFill
    static let ink = Palette.brandText

    init(title: String) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
            return attributes
        }
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Self.ground
        configuration.baseForegroundColor = Self.ink
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        self.configuration = configuration
        // As tall as the leading disc: concentric with the toast.
        let height = heightAnchor.constraint(greaterThanOrEqualToConstant: ToastBadge.side)
        height.priority = .required - 1
        height.isActive = true
        // Pressed: a step darker grey.
        configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            configuration.baseBackgroundColor = button.isHighlighted ? ToastActionButton.pressedGround : ToastActionButton.ground
            button.configuration = configuration
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Up to `touchTarget` around the capsule: the toast's height gives it
    /// the room.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.touchTarget - bounds.width) / 2)
        let dy = max(0, (Self.touchTarget - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// An undoable toast's trailing action (#954): "Undo".
@MainActor
final class ToastUndoButton: ToastActionButton {
    init() {
        super.init(title: "Undo")
        accessibilityLabel = "Undo"
    }
}

/// A toast's leading mark (the owner, 2026-11-06, after the system's own
/// pills): its glyph, in white, on a full disc of the toast's colour — the
/// app's primary for what went well, red for a failure, yellow (and a dark
/// glyph) for a warning, a glyph's own colour where it has one (the Points
/// heart, the saved star). Concentric with the toast, as its action is.
///
/// A content change never repaints it (#2285): the old disc blurs away and
/// the new one comes out of a blur at the same place — a change of colour
/// happens inside the blur. (Its glyph swapped by the symbol transition left
/// the disc empty for a third of a second, filmed, #2166.)
@MainActor
final class ToastBadge: UIView {
    /// The disc's side, and the action capsule's height: the toast's height
    /// less the same inset all round.
    nonisolated static let side: CGFloat = 36

    let glyph: UIImageView

    init(image: UIImage, fill: UIColor, ink: UIColor) {
        glyph = UIImageView(image: image.withRenderingMode(.alwaysTemplate))
        super.init(frame: .zero)
        backgroundColor = fill
        layer.cornerRadius = Self.side / 2
        layer.cornerCurve = .circular
        glyph.tintColor = ink
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        glyph.contentMode = .center
        glyph.constrain(in: self) { parent in
            glyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            glyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A toast's close control, when it has one (a toast that does not leave on
/// its own and has no action): an ✕ in the primary ink on a grey disc, the
/// action capsule's shape squared to a circle.
@MainActor
final class ToastCloseButton: UIButton {
    init() {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "xmark")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = ToastActionButton.ground
        configuration.baseForegroundColor = ToastActionButton.ink
        configuration.contentInsets = .zero
        self.configuration = configuration
        accessibilityLabel = "Dismiss"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ToastBadge.side),
            heightAnchor.constraint(equalToConstant: ToastBadge.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Up to the touch target around the disc, as the action's capsule.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (ToastActionButton.touchTarget - bounds.width) / 2)
        let dy = max(0, (ToastActionButton.touchTarget - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// A toast's words: the message centred in its slot, held whole during a
/// change and blurred across it (`blur(appearing:…)`) — the content change of
/// the system's glass bubbles (the owner, 2026-11-06). Inside the toast's
/// glass a layer's mask is not drawn, and a render of the label comes out in
/// the glass's vibrant ink (white): the words are drawn for the change.
@MainActor
final class ToastWords: UIView {
    let label: UILabel
    private let clip = UIView()
    /// At rest the clip is the words' width.
    private let matches: NSLayoutConstraint
    /// The words' picture while they blur (`blur(appearing:…)`).
    private weak var stand: UIImageView?
    /// During a change: the words at their whole width, and the clip's own.
    private var held: NSLayoutConstraint?
    private var opening: NSLayoutConstraint?

    init(label: UILabel) {
        self.label = label
        matches = clip.widthAnchor.constraint(equalTo: label.widthAnchor)
        super.init(frame: .zero)
        clip.clipsToBounds = true
        // Just under required: at rest these win over the words' compression
        // resistance, and the words truncate at the slot's ends; during a
        // change the words hold their whole width and the capsule clips them.
        let fitsLeading = clip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        let fitsTrailing = clip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        fitsLeading.priority = .required - 1
        fitsTrailing.priority = .required - 1
        clip.constrain(in: self) { slot in
            clip.centerXAnchor.constraint(equalTo: slot.centerXAnchor)
            clip.topAnchor.constraint(equalTo: slot.topAnchor)
            clip.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
            fitsLeading
            fitsTrailing
        }
        label.constrain(in: clip) { clip in
            label.centerXAnchor.constraint(equalTo: clip.centerXAnchor)
            label.topAnchor.constraint(equalTo: clip.topAnchor)
            label.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        }
        matches.isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Holds the words at their whole width — laid out now — and the clip
    /// at `width`: shut (0) to open, or as it is to close.
    private func hold(clipAt width: CGFloat) {
        settle()
        let held = label.widthAnchor.constraint(equalToConstant: label.bounds.width)
        let opening = clip.widthAnchor.constraint(equalToConstant: width)
        matches.isActive = false
        NSLayoutConstraint.activate([held, opening])
        self.held = held
        self.opening = opening
    }

    /// Held whole for a change: the words at their laid-out width, never
    /// truncated by the capsule's narrower start.
    func holdWhole() { hold(clipAt: label.bounds.width) }

    /// The words drawn as a picture in their own ink, resolved here — a
    /// render of the label would take the glass's vibrant ink for white
    /// (filmed) — on `pad` around, at `scale`.
    private func picture(scale: CGFloat, pad: CGFloat) -> CGImage? {
        guard let text = label.text, let font = label.font, label.bounds.width > 0 else { return nil }
        let size = CGSize(width: label.bounds.width + pad * 2, height: label.bounds.height + pad * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = label.textAlignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (label.textColor ?? .label).resolvedColor(with: traitCollection),
            .paragraphStyle: paragraph,
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let line = ceil(font.lineHeight)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(x: pad, y: pad + (label.bounds.height - line) / 2, width: label.bounds.width, height: line)
            (text as NSString).draw(
                with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil
            )
        }.cgImage
    }

    /// Blurs the words in (`appearing`: from `peak`, in pixels, to sharp) or
    /// away (sharp to `peak`, from `opacity` — what still showed of them),
    /// fading as they go, over `duration` after `delay`: a picture stands
    /// exactly where the words are, the words hidden under it; arriving,
    /// they take its place as it clears (`ToastBlur`). `completion` runs
    /// once it has finished. False, and nothing done, when there is nothing
    /// to draw (words not laid out).
    @discardableResult
    func blur(
        appearing: Bool, peak: CGFloat, delay: TimeInterval, duration: TimeInterval,
        from opacity: Float = 1, completion: (@MainActor () -> Void)? = nil
    ) -> Bool {
        // One picture at a time: a change mid-change starts over from here.
        stand?.removeFromSuperview()
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        let pad = peak / scale * 3
        guard let image = picture(scale: scale, pad: pad) else { return false }
        let standFrame = label.convert(label.bounds, to: self).insetBy(dx: -pad, dy: -pad)
        let standIn = ToastBlur.stand(
            image, scale: scale, frame: standFrame, in: self, appearing: appearing,
            peak: peak, delay: delay, duration: duration, opacity: opacity
        ) { [weak self] finished in
            // A newer blur took over: it owns the words now.
            guard let self, finished === self.stand else {
                finished.removeFromSuperview()
                return
            }
            if appearing {
                ToastBlur.handOver(from: finished, to: label)
            } else {
                finished.removeFromSuperview()
            }
            completion?()
        }
        standIn.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        self.stand = standIn
        label.alpha = 0
        return true
    }

    /// Whether a change holds the words now (opening or closing).
    var isOpening: Bool { opening != nil }

    /// Back at rest: the clip the words' width again.
    func settle() {
        held?.isActive = false
        opening?.isActive = false
        held = nil
        opening = nil
        matches.isActive = true
    }
}
