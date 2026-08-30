import DesignSystem
import UIKit

/// What a thumb dragging a clip's bar is pointing at: the frame it would land
/// on, and the time it would land at.
///
/// ⚠️ THE TIME IS THE LOAD-BEARING HALF. A frame has to be decoded from
/// wherever the thumb is now, and not every asset will give one up in the time
/// a finger waits — a stream may refuse outright. So the card is built around
/// the readout and the picture is what it gets when it can: no frame yet is a
/// card that still says exactly where you are, which is the answer a viewer is
/// actually reading while they drag.
///
/// It FOLLOWS THE THUMB rather than sitting in the middle. Centred, it would be
/// a caption about the gesture; over the thumb it is a label on the place the
/// gesture is pointing at — and the difference shows the moment the clip is
/// long enough that the two ends mean different things.
final class SnapScrubPreviewView: UIView {
    /// The frame's box. 16:9 because that is what the fixtures and most posts
    /// are; a taller frame letterboxes inside it rather than resizing the card,
    /// which would make the card move while the thumb did not.
    static let frameSize = CGSize(width: 118, height: 66)

    private let picture = UIImageView()
    private let time = UILabel()
    private let plate = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        plate.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        plate.layer.cornerCurve = .continuous
        plate.layer.cornerRadius = 10
        plate.clipsToBounds = true

        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        time.textColor = .white
        time.textAlignment = .center
        // ⚠️ Monospaced digits, and not for tidiness: a proportional face
        // re-measures the label every tenth of a second while the thumb moves,
        // so the card twitches sideways under a finger that is trying to aim.
        time.layer.shadowColor = UIColor.black.cgColor
        time.layer.shadowOpacity = 0.5
        time.layer.shadowRadius = 2
        time.layer.shadowOffset = .zero

        addSubview(plate)
        plate.addSubview(picture)
        addSubview(time)
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's whole size: the frame, and the readout under it.
    static var totalSize: CGSize {
        CGSize(width: frameSize.width, height: frameSize.height + 18)
    }

    override var intrinsicContentSize: CGSize { Self.totalSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = CGRect(origin: .zero, size: Self.frameSize)
        picture.frame = plate.bounds
        time.frame = CGRect(
            x: 0, y: Self.frameSize.height + 2,
            width: bounds.width, height: 16
        )
    }

    /// Shows the card, or moves it: `fraction` of a clip `seconds` long.
    func show(fraction: Double, seconds: Double) {
        time.text = Self.timestamp(fraction * seconds) + " / " + Self.timestamp(seconds)
        guard alpha < 1 else { return }
        UIView.animate(withDuration: 0.15, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
        }
    }

    /// The frame under the thumb, or nil while there is none to show.
    func setPicture(_ image: CGImage?) {
        picture.image = image.map { UIImage(cgImage: $0) }
    }

    func hide() {
        UIView.animate(withDuration: 0.2, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            guard self.alpha == 0 else { return }
            self.picture.image = nil
        }
    }

    /// `m:ss`, and `h:mm:ss` once there is an hour to show — the shortest form
    /// that cannot be misread, which is what a readout under a thumb needs.
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    #if DEBUG
    var debugTimestamp: String? { time.text }
    var debugHasPicture: Bool { picture.image != nil }
    var debugIsShowing: Bool { alpha > 0.5 }
    #endif
}
