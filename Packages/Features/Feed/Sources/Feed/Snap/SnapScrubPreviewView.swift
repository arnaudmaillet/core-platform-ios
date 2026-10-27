import DesignSystem
import PostGrid
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
    /// The frame's box budget (#1724, the owner): the card takes the clip's
    /// own shape — 118 pt wide for a landscape clip, at most 150 pt tall for a
    /// portrait one — instead of a fixed 16:9 box a vertical clip letterboxed
    /// in. The shape is the page's declared aspect, known before the first
    /// frame, so the card does not resize under a still thumb.
    static let maxFrameWidth: CGFloat = 118
    static let maxFrameHeight: CGFloat = 150

    /// The frame's box for a clip `aspect` (width / height) wide.
    static func frameSize(aspect: CGFloat) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        if ratio >= maxFrameWidth / maxFrameHeight {
            return CGSize(width: maxFrameWidth, height: (maxFrameWidth / ratio).rounded())
        }
        return CGSize(width: (maxFrameHeight * ratio).rounded(), height: maxFrameHeight)
    }

    /// The clip's shape, width / height. Set by the host before it places
    /// the card; a frame of another shape resets it (`setPicture`).
    var aspect: CGFloat = 16.0 / 9.0 {
        didSet {
            guard aspect != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The frame came in another shape than declared: the host re-places
    /// the card at its new size.
    var onShapeChange: (() -> Void)?

    var frameSize: CGSize { Self.frameSize(aspect: aspect) }

    private let picture = UIImageView()
    private let time = UILabel()
    private let plate = UIView()

    /// Shown while a frame is being decoded and there is nothing yet to show.
    ///
    /// The branded loader (#1329), in its own tones over the post's photograph
    /// or black.
    private let spinner: AppLoaderView = {
        let view = AppLoaderView(size: .medium)
        view.hidesWhenStopped = true
        return view
    }()

    /// Whether a frame is on its way, and the delay before saying so.
    private var isLoading = false
    /// The spinner's timing — the kit's (`LoaderGate`, #1768) at this card's
    /// grace, no minimum: a frame that lands replaces the spinner at once.
    private lazy var spinnerGate = LoaderGate(grace: Self.loaderGrace, minimum: 0) { [weak self] showing in
        guard let self else { return }
        guard showing else { return spinner.stopAnimating() }
        // ⚠️ Above the picture, and re-stated on every show for the reason
        // the media card's is: this is the only thing here that has to be
        // seen through whatever else the plate is holding.
        plate.bringSubviewToFront(spinner)
        spinner.startAnimating()
    }

    /// ⚠️ A FIFTH OF A SECOND OF SILENCE FIRST. Most frames arrive faster than
    /// that, and a spinner shown for every one of them would strobe under the
    /// thumb — the same trap the media loader documents one file over, where an
    /// indicator armed without a grace flashed on nearly every page change.
    static let loaderGrace: TimeInterval = 0.2

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        plate.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        plate.layer.cornerCurve = .continuous
        plate.layer.cornerRadius = 10
        plate.clipsToBounds = true

        // Fill until a frame says otherwise — see `setPicture`.
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        // Fixed size (#482): a stamp on the preview frame, sized with it.
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
        plate.addSubview(spinner)
        addSubview(time)
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's whole size: the frame, and the readout under it.
    var totalSize: CGSize {
        CGSize(width: max(frameSize.width, 84), height: frameSize.height + 18)
    }

    override var intrinsicContentSize: CGSize { totalSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Centred over the readout, which keeps room for "0:00 / 0:00".
        plate.frame = CGRect(
            x: ((bounds.width - frameSize.width) / 2).rounded(), y: 0,
            width: frameSize.width, height: frameSize.height
        )
        picture.frame = plate.bounds
        spinner.center = CGPoint(x: plate.bounds.midX, y: plate.bounds.midY)
        time.frame = CGRect(
            x: 0, y: frameSize.height + 2,
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

    /// A frame the thumb is pointing at.
    ///
    /// ⚠️ THERE IS NO WAY TO SAY "NOTHING NEW" HERE, deliberately: a decode
    /// that fails or arrives late must leave the last frame standing. A card
    /// that blanked between frames would flicker its way along a drag, and the
    /// picture it blanked to is less true than the one it already had — the
    /// thumb has moved a little, not somewhere else. Clearing belongs to the
    /// end of the gesture, and `hide` owns it.
    func setPicture(_ image: CGImage) {
        // The preview frames the clip by the page's own rule
        // (`SnapMediaAspect`): a clip the page shows whole is shown whole here,
        // on the plate's dark ground; a clip the page fills is cropped to fill.
        // The card has the clip's shape: the frame fills it. A frame of
        // another shape than declared reshapes the card (#1724).
        picture.contentMode = .scaleAspectFill
        if image.width > 0, image.height > 0 {
            let actual = CGFloat(image.width) / CGFloat(image.height)
            if abs(actual - aspect) > 0.02 {
                aspect = actual
                onShapeChange?()
            }
        }
        picture.image = UIImage(cgImage: image)
        setLoading(false)
    }

    /// Whether a frame is being decoded. The spinner only stands in for a
    /// picture that is not there — once one is, a newer one arrives over it and
    /// the card never goes blank.
    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        guard loading else { return spinnerGate.cancel() }
        guard picture.image == nil else { return }
        spinnerGate.begin { [weak self] in
            guard let self else { return false }
            return isLoading && picture.image == nil
        }
    }

    func hide() {
        setLoading(false)
        UIView.animate(withDuration: 0.2, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            guard self.alpha == 0 else { return }
            // ⚠️ Cleared only here. The next gesture may be on a different clip
            // — or a different post — and a card that opened on the last one's
            // frame would be claiming something untrue for as long as the first
            // decode takes.
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
    var debugIsLoading: Bool { spinner.isAnimating }

    /// Runs the loader's grace out now, so a spec need not wait a fifth of a
    /// second for a delay whose duration is not the claim under test.
    func debugElapseLoaderGrace() {
        spinnerGate.debugElapseGrace()
    }
    #endif
}
