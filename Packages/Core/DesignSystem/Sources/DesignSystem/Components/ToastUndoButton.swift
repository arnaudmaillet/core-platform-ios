import UIKit

/// An undoable toast's trailing control (#954): the undo glyph inside a ring
/// that empties as the toast's time runs out, and the word "Undo".
///
/// The ring is the countdown made visible — the viewer sees how long they
/// have. It follows `ToastCountdown`: it runs down while the countdown runs,
/// and stops exactly where it is while the countdown is held (a finger on the
/// toast, VoiceOver's focus on it, the scene inactive). It is information,
/// not decoration, so it keeps running under Reduce Motion: a linear ring
/// emptying is not the kind of motion that setting is about.
@MainActor
final class ToastUndoButton: UIControl {
    static let ringDiameter: CGFloat = 20
    static let ringWidth: CGFloat = 1.5

    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let glyph = UIImageView(image: UIImage(systemName: "arrow.uturn.backward"))
    private let title = UILabel()
    private let ringHost = UIView()

    /// The fraction of the ring still drawn, 1 → 0 (tests read the model
    /// value).
    var ringFraction: CGFloat { ring.strokeEnd }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Undo"
        accessibilityTraits = .button

        ringHost.isUserInteractionEnabled = false
        for layer in [track, ring] {
            layer.fillColor = nil
            layer.lineWidth = Self.ringWidth
            layer.lineCap = .round
            ringHost.layer.addSublayer(layer)
        }
        ring.strokeEnd = 1
        resolveRingColors()
        // The ring's size is fixed, so its path is drawn once, in the host's
        // coordinates — never from a bounds the stack has not laid out yet
        // (from `layoutSubviews` it came out empty). From twelve o'clock,
        // clockwise: the ring empties the way a clock hand runs.
        let radius = (Self.ringDiameter - Self.ringWidth) / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: Self.ringDiameter / 2, y: Self.ringDiameter / 2), radius: radius,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        track.path = path
        ring.path = path

        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false

        title.text = "Undo"
        title.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.isUserInteractionEnabled = false

        let row = UIStackView(arrangedSubviews: [ringHost, title])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isUserInteractionEnabled = false
        glyph.constrain(in: ringHost) { parent in
            glyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            glyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        row.constrain(in: self) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor, constant: 6)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -6)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 4)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8)
        }
        NSLayoutConstraint.activate([
            ringHost.widthAnchor.constraint(equalToConstant: Self.ringDiameter),
            ringHost.heightAnchor.constraint(equalToConstant: Self.ringDiameter),
            // The touch target's floor (#1034): a 20 pt ring, a 44 pt control.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: ToastUndoButton, _) in
            button.resolveRingColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// CGColors do not follow the appearance on their own.
    private func resolveRingColors() {
        track.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        ring.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }

    /// Follows the countdown: running from `remaining` of `total` down to
    /// empty, or held where it is.
    func follow(isRunning: Bool, remaining: TimeInterval, total: TimeInterval) {
        let fraction = total > 0 ? CGFloat(remaining / total) : 0
        ring.removeAnimation(forKey: "countdown")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = isRunning ? 0 : fraction
        CATransaction.commit()
        guard isRunning, remaining > 0 else { return }
        let run = CABasicAnimation(keyPath: "strokeEnd")
        run.fromValue = fraction
        run.toValue = 0
        run.duration = remaining
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(run, forKey: "countdown")
    }
}
