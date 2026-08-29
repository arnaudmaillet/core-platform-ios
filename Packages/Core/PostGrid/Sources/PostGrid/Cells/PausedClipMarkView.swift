import UIKit

/// The mark a stopped clip wears: a play triangle in the middle of the picture.
///
/// ⚠️ IT BELONGS TO THE PICTURE, NOT TO THE SCREEN — which is why it is a view
/// of its own rather than an image the host centres on itself. A carousel's
/// pages each carry their own clip and their own playhead, so each carries its
/// own mark: the one the viewer stopped slides away under the finger and the
/// page arriving brings its own answer. Centred on the SCREEN it belonged to
/// nothing, and a swipe left it hanging over a picture that was playing.
///
/// Deliberately inert. The mark says a clip is stopped; starting it again is a
/// tap anywhere on the picture, which is a target the size of the media rather
/// than a 56pt glyph.
public final class PausedClipMarkView: UIImageView {
    /// How long the mark takes to arrive or leave. Short — it is the receipt
    /// for a tap that has already happened.
    public static let fadeDuration: TimeInterval = 0.15

    public init() {
        super.init(frame: .zero)
        image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold))
        tintColor = UIColor.white.withAlphaComponent(0.85)
        contentMode = .center
        isUserInteractionEnabled = false
        isHidden = true
        // Over a photograph a white glyph can land on white; the shadow is what
        // keeps it readable without a plate behind it.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows or hides the mark, crossfading. A no-op when it is already in the
    /// asked-for state, so a reconcile that runs on every page change cannot
    /// restart the fade.
    public func setVisible(_ visible: Bool, animated: Bool = true) {
        guard isHidden == visible else { return }
        guard animated else {
            isHidden = !visible
            return
        }
        UIView.transition(with: self, duration: Self.fadeDuration,
                          options: .transitionCrossDissolve) {
            self.isHidden = !visible
        }
    }

    public var isShowing: Bool { !isHidden }
}
