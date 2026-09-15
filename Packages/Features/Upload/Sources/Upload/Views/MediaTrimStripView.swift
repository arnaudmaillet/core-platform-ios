import DesignSystem
import UIKit

/// The clip laid out end to end, with a handle at each end of what will be kept.
///
/// ⚠️ **NO GROUND, NO MATERIAL, NO PLATE** — the band's rule, stated by every
/// tenant it has. The canvas runs full-bleed underneath and a plate here would
/// cut the picture in two. What dims is the part of the CLIP being discarded,
/// which is ink on the strip rather than a surface behind it.
///
/// ⚠️ **IT ANNOUNCES ON RELEASE, NOT DURING THE DRAG** — `MediaCropSurfaceView`
/// does the same and for the same reason: a value sampled mid-gesture is not a
/// decision, and storing one would put an entry in `edits` for every frame of a
/// drag the author has not finished. The view draws its own state while the
/// finger is down.
@MainActor
final class MediaTrimStripView: UIView {
    private enum Metrics {
        /// The frames themselves. Matches the filter row's thumbnail so the two
        /// band tenants are the same height at rest.
        static let strip: CGFloat = 56
        /// The grab bars at each end. Wide enough to see; the REACH is a
        /// finger's 44, which is `MediaTrimming.reach` and much larger.
        static let handle: CGFloat = 12
        static let border: CGFloat = 2
    }

    /// ⚠️ `nonisolated` SO A TENANT'S OWN `Metrics` CAN ADD IT UP — the same
    /// reason `StraightenDialView.height` is, and it cost a build once.
    nonisolated static var height: CGFloat { Metrics.strip }

    /// Fired when the author lets go of a handle.
    var onChange: ((MediaTrim) -> Void)?

    private let frames = UIStackView()
    private let dimBefore = UIView()
    private let dimAfter = UIView()
    private let selection = UIView()
    private let startHandle = UIView()
    private let endHandle = UIView()

    private var duration: Double = 0
    private var trim: MediaTrim = .whole
    /// Which handle the finger has hold of, if any.
    private var grip: MediaTrimming.Handle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        layer.cornerRadius = Spacing.xs
        // ⚠️ THE ORDER OF THESE BLOCKS IS THE Z-ORDER — `pin(to:)` begins with
        // `addSubview`. Frames first, then what dims them, then the selection's
        // outline and its handles on top.
        frames.axis = .horizontal
        frames.distribution = .fillEqually
        frames.isUserInteractionEnabled = false
        frames.pin(to: self)

        for dim in [dimBefore, dimAfter] {
            dim.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.65)
            dim.isUserInteractionEnabled = false
            addSubview(dim)
        }

        selection.layer.borderWidth = Metrics.border
        selection.layer.borderColor = UIColor.label.cgColor
        selection.layer.cornerRadius = Spacing.xs
        selection.isUserInteractionEnabled = false
        addSubview(selection)

        for handle in [startHandle, endHandle] {
            handle.backgroundColor = .label
            handle.layer.cornerRadius = Metrics.handle / 2
            handle.isUserInteractionEnabled = false
            addSubview(handle)
        }

        // ⚠️ **A `CGColor` DOES NOT FOLLOW AN APPEARANCE CHANGE.** The dims and
        // the handles are `UIColor` on a view and re-resolve themselves; the
        // selection's outline is a `layer.borderColor`, resolved once at the
        // moment it was read. Without this, an editor opened in light and
        // switched to dark would keep a dark outline on a dark ground. The page
        // dots and the filter row's chip ring carry the same note.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (strip: MediaTrimStripView, _) in
            strip.selection.layer.borderColor = UIColor.label.cgColor
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        addGestureRecognizer(pan)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        // ⚠️ **`.adjustable` IS A PROMISE, AND IT WAS AN EMPTY ONE.** The trait
        // tells VoiceOver this control can be changed with a swipe up or down,
        // and the swipe calls `accessibilityIncrement`/`Decrement`. Declaring it
        // without implementing them gives a viewer a control they can hear the
        // value of and cannot move — worse than a plain label, because the
        // affordance is announced.
        //
        // The end is what the pair adjusts: "how much of this clip do I keep" is
        // the question, and the start is reachable by trimming the end and
        // dragging. The label says so rather than leaving it to be guessed.
        accessibilityLabel = "Trim, adjusts the end"

        heightAnchor.constraint(equalToConstant: Metrics.strip).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - What it is showing

    /// ⚠️ **THE DURATION IS THE CLIP'S, AND EVERYTHING IS LAID OUT AGAINST IT.**
    /// A strip told one length while the file runs another places its handles
    /// over moments that do not exist — which is why `DebugMediaLibrary` had to
    /// stop declaring invented durations before this could be trusted.
    /// ⚠️ **REFUSED WHILE A FINGER IS DOWN, AND NOT REFUSING IT WAS A DEFECT.**
    /// The frames arrive asynchronously — a file read, then a dozen exact-time
    /// decodes — and the author can start dragging before they land. This used
    /// to take a `trim` alongside the pictures and assign it, so the landing
    /// silently reset the handle mid-drag, back to whatever was stored. The
    /// pictures are decoration; the value being edited is not theirs to set.
    func configure(duration: Double, trim: MediaTrim) {
        guard grip == nil else { return }
        self.duration = duration
        self.trim = trim
        setNeedsLayout()
    }

    /// The pictures only — safe at any moment, including mid-drag.
    func showFrames(_ pictures: [UIImage]) {
        if frames.arrangedSubviews.count != pictures.count {
            for view in frames.arrangedSubviews { view.removeFromSuperview() }
            for picture in pictures { frames.addArrangedSubview(Self.cell(picture)) }
        } else {
            for (view, picture) in zip(frames.arrangedSubviews, pictures) {
                (view as? UIImageView)?.image = picture
            }
        }
        setNeedsLayout()
    }

    private static func cell(_ picture: UIImage) -> UIImageView {
        let view = UIImageView(image: picture)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let range = MediaTrimming.resolved(trim, within: duration)
        let startX = MediaTrimming.x(forSeconds: range.lowerBound, width: bounds.width, duration: duration)
        let endX = MediaTrimming.x(forSeconds: range.upperBound, width: bounds.width, duration: duration)

        dimBefore.frame = CGRect(x: 0, y: 0, width: startX, height: bounds.height)
        dimAfter.frame = CGRect(
            x: endX, y: 0, width: max(bounds.width - endX, 0), height: bounds.height
        )
        selection.frame = CGRect(
            x: startX, y: 0, width: max(endX - startX, 0), height: bounds.height
        )
        startHandle.frame = CGRect(
            x: startX, y: 0, width: Metrics.handle, height: bounds.height
        )
        endHandle.frame = CGRect(
            x: endX - Metrics.handle, y: 0, width: Metrics.handle, height: bounds.height
        )
        accessibilityValue = Self.spoken(range)
    }

    private static func spoken(_ range: ClosedRange<Double>) -> String {
        let seconds = Int((range.upperBound - range.lowerBound).rounded())
        return seconds == 1 ? "1 second kept" : "\(seconds) seconds kept"
    }

    // MARK: - Spoken adjustment

    /// One second per swipe: the floor `MediaTrimming` enforces, so a viewer
    /// cannot step into a state the handles refuse.
    private static let spokenStep: Double = 1

    override func accessibilityIncrement() {
        adjustEnd(bySeconds: Self.spokenStep)
    }

    override func accessibilityDecrement() {
        adjustEnd(bySeconds: -Self.spokenStep)
    }

    /// ⚠️ **THROUGH `MediaTrimming.moved`, LIKE EVERY OTHER ROUTE.** A second
    /// implementation of the clamping would be a second set of edge cases, and
    /// the arithmetic is pure precisely so every caller can share it.
    private func adjustEnd(bySeconds delta: Double) {
        let next = MediaTrimming.moved(trim, handle: .end, bySeconds: delta, within: duration)
        guard next != trim else { return }
        trim = next
        setNeedsLayout()
        // Announced immediately: unlike a finger, a VoiceOver swipe IS the whole
        // gesture, so there is no release to wait for.
        onChange?(trim)
    }

    // MARK: - Dragging

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            takeHold(at: pan.location(in: self).x)
        case .changed:
            // ⚠️ **ZEROED EVERY SAMPLE, SO THE ARITHMETIC IS INCREMENTAL.** It is
            // what lets a handle dragged past the end of the clip come straight
            // back rather than first undoing its overshoot — the crop surface
            // and the straighten dial both do this, and `MediaTrimming` is
            // written to be fed deltas.
            let moved = pan.translation(in: self).x
            pan.setTranslation(.zero, in: self)
            track(byPoints: moved)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    // ⚠️ **THE THREE ROUTINES A FINGER USES, NAMED — SO THE DEBUG HOOKS CAN GO
    // THROUGH THEM RATHER THAN ALONGSIDE.** The crop surface states the rule:
    // a test re-entering by a copy of the logic is a test of the copy. This was
    // written inline in `dragged(_:)` first, and the "nothing is stored until
    // the finger lifts" test was consequently asking the hook, not the view.
    private func takeHold(at x: CGFloat) {
        let range = MediaTrimming.resolved(trim, within: duration)
        grip = MediaTrimming.handle(
            at: x,
            startX: MediaTrimming.x(
                forSeconds: range.lowerBound, width: bounds.width, duration: duration
            ),
            endX: MediaTrimming.x(
                forSeconds: range.upperBound, width: bounds.width, duration: duration
            )
        )
    }

    private func track(byPoints points: CGFloat) {
        guard let grip else { return }
        trim = MediaTrimming.moved(
            trim,
            handle: grip,
            bySeconds: MediaTrimming.seconds(
                forWidth: points, width: bounds.width, duration: duration
            ),
            within: duration
        )
        setNeedsLayout()
    }

    private func finishDrag() {
        let hadGrip = grip != nil
        grip = nil
        guard hadGrip else { return }
        onChange?(trim)
    }

    #if DEBUG
    /// Internal for tests: the strip's own state, and re-entry through the very
    /// routines a finger uses rather than around them.
    var debugTrim: MediaTrim { trim }
    var debugFrameCount: Int { frames.arrangedSubviews.count }
    var debugSelectionFrame: CGRect { selection.frame }
    var debugIsDimmedBefore: Bool { dimBefore.frame.width > 0.5 }
    var debugIsDimmedAfter: Bool { dimAfter.frame.width > 0.5 }

    func debugTakeHold(at x: CGFloat) { takeHold(at: x) }

    var debugHasGrip: Bool { grip != nil }

    func debugDrag(byPoints points: CGFloat) {
        track(byPoints: points)
        layoutIfNeeded()
    }

    func debugRelease() { finishDrag() }
    #endif
}
