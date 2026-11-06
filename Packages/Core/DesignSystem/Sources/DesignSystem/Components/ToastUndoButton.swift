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

    /// Another glyph and colour on the same disc — animated: the glyphs
    /// cross-fade in place and the colour eases. (The symbol transition
    /// `.replace` left the disc empty for a third of a second between two
    /// unrelated glyphs — filmed.)
    func update(image: UIImage, fill: UIColor, ink: UIColor, animated: Bool) {
        let template = image.withRenderingMode(.alwaysTemplate)
        if animated {
            UIView.transition(with: glyph, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.glyph.image = template
            }
        } else {
            glyph.image = template
        }
        let paint = {
            self.backgroundColor = fill
            self.glyph.tintColor = ink
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: paint)
        } else {
            paint()
        }
    }
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
    /// away (sharp to `peak`), fading as they go, over `duration` after
    /// `delay`: a picture stands exactly where the words are, the words
    /// hidden under it; arriving, they take its place as it clears.
    func blur(appearing: Bool, peak: CGFloat, delay: TimeInterval, duration: TimeInterval) {
        // One picture at a time: a change mid-change starts over from here.
        stand?.removeFromSuperview()
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        let pad = peak / scale * 3
        guard let image = picture(scale: scale, pad: pad) else { return }
        let levels = 4
        var images = (0...levels).map { AppButtonBlur.blurred(image, radius: peak * CGFloat($0) / CGFloat(levels)) }
        if appearing { images.reverse() }
        let stand = UIImageView(image: UIImage(cgImage: images[0], scale: scale, orientation: .up))
        stand.frame = label.convert(label.bounds, to: self).insetBy(dx: -pad, dy: -pad)
        stand.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        stand.isUserInteractionEnabled = false
        addSubview(stand)
        self.stand = stand
        label.alpha = 0
        let begin = stand.layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let contents = CAKeyframeAnimation(keyPath: "contents")
        contents.values = images.map(\.self)
        contents.beginTime = begin
        contents.duration = duration
        contents.fillMode = .both
        contents.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        fade.beginTime = begin
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak stand] in
            guard let self, let stand else { return }
            guard appearing else {
                stand.removeFromSuperview()
                return
            }
            // The words take over from their picture in a breath: the
            // glass's vibrant ink and the picture's are not quite one.
            UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) {
                self.label.alpha = 1
                stand.alpha = 0
            } completion: { _ in
                stand.removeFromSuperview()
            }
        }
        stand.layer.add(contents, forKey: "blur.contents")
        stand.layer.add(fade, forKey: "blur.opacity")
        CATransaction.commit()
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
