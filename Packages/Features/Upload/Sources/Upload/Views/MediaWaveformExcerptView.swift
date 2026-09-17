import DesignSystem
import UIKit

/// The part of a song that plays under the film: the song's waveform scrolls
/// under a fixed window as long as the film.
///
/// ```
///  ▁▃▅▇▅▃▁▃ ┃▅▇█▇▅▃▁▃▅▇█▇▅▃┃ ▁▃▅▇▅▃▁
///           ┗━━ the film ━━━┛
/// ```
///
/// ⚠️ **THE WINDOW STAYS, THE SONG MOVES.** The film is what the author is
/// fitting a song to, so its length is the one fixed thing on screen; dragging
/// the song under it is choosing which part plays. The song's start sits at the
/// window's left edge at the far left, and its end at the window's right edge
/// at the far right — the scroll insets say so, so no excerpt can run past the
/// song's end while the song is longer than the film.
///
/// ⚠️ **STORED WHEN THE FINGER LIFTS, NEVER DURING THE DRAG.** A new start is a
/// new audio track and so a new player item; built on every scroll step it
/// would restart the film under the finger sixty times a second. `onChange`
/// only moves the readout; `onSettle` is the one that is stored.
///
/// ⚠️ **NO BACKGROUND** — the band's rule: the picture runs underneath.
@MainActor
final class MediaWaveformExcerptView: UIView, UIScrollViewDelegate {
    nonisolated static let height: CGFloat = 44

    private enum Metrics {
        /// The share of the width the window takes when the film allows it.
        static let windowShare: CGFloat = 0.6
        /// One bar per this many points.
        static let barPitch: CGFloat = 3
        static let barWidth: CGFloat = 2
        static let windowCorner: CGFloat = 8
        static let windowBorder: CGFloat = 2
        /// The shallowest and steepest the song may be drawn, in points per
        /// second: a five-minute film still fits its window, and a two-second
        /// film does not stretch a song across a mile.
        static let pointsPerSecond: ClosedRange<CGFloat> = 0.1...60
    }

    /// The start moved under the finger — for a readout, not for storing.
    var onChange: ((Double) -> Void)?
    /// The finger lifted, or VoiceOver stepped: store this start.
    var onSettle: ((Double) -> Void)?

    private let scroller = UIScrollView()
    private let bars = CAShapeLayer()
    private let excerptFrame = UIView()
    private let leftShade = UIView()
    private let rightShade = UIView()

    private var songSeconds: Double = 0
    private var filmSeconds: Double = 0
    private var peaks: [Float] = []
    private var bucketSeconds: Double = 0.01
    /// The start the view was last told, re-applied whenever the geometry
    /// changes — a layout pass must not move the song.
    private var start: Double = 0
    private var laidWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.decelerationRate = .fast
        scroller.delegate = self
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.pin(to: self)
        scroller.layer.addSublayer(bars)

        for shade in [leftShade, rightShade] {
            // ⚠️ THE GROUND'S OWN COLOUR, HALF-STRENGTH: what dims the song
            // outside the window is the screen, not a plate of its own.
            shade.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
            shade.isUserInteractionEnabled = false
            addSubview(shade)
        }
        excerptFrame.isUserInteractionEnabled = false
        excerptFrame.layer.borderWidth = Metrics.windowBorder
        excerptFrame.layer.cornerRadius = Metrics.windowCorner
        excerptFrame.layer.cornerCurve = .continuous
        addSubview(excerptFrame)

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        resolveInks()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.resolveInks()
        }
        isAccessibilityElement = true
        accessibilityLabel = "Song start"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The song, the film it goes under, and where the excerpt starts.
    func configure(songSeconds: Double, filmSeconds: Double, start: Double) {
        self.songSeconds = max(songSeconds.isFinite ? songSeconds : 0, 0)
        self.filmSeconds = max(filmSeconds.isFinite ? filmSeconds : 0, 0)
        self.start = clamped(start)
        laidWidth = -1
        setNeedsLayout()
        updateReadout()
    }

    /// The song's loudness, one peak per `bucketSeconds`.
    func setPeaks(_ peaks: [Float], bucketSeconds: Double) {
        self.peaks = peaks
        self.bucketSeconds = bucketSeconds > 0 ? bucketSeconds : 0.01
        drawBars()
    }

    /// Where the excerpt starts, in seconds of the song.
    var startSeconds: Double { start }

    // MARK: - Geometry

    /// How far the song is drawn per second.
    private var pointsPerSecond: CGFloat {
        guard filmSeconds > 0, bounds.width > 0 else { return Metrics.pointsPerSecond.lowerBound }
        let fitted = bounds.width * Metrics.windowShare / CGFloat(filmSeconds)
        return min(max(fitted, Metrics.pointsPerSecond.lowerBound), Metrics.pointsPerSecond.upperBound)
    }

    private var windowRect: CGRect {
        let width = min(CGFloat(filmSeconds) * pointsPerSecond, bounds.width - 2 * Spacing.lg)
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: max(width, 0), height: bounds.height)
    }

    /// The latest start that still fills the window with song.
    private var latestStart: Double { max(songSeconds - filmSeconds, 0) }

    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), latestStart)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != laidWidth else { return }
        laidWidth = bounds.width
        let frame = windowRect
        excerptFrame.frame = frame
        leftShade.frame = CGRect(x: 0, y: 0, width: frame.minX, height: bounds.height)
        rightShade.frame = CGRect(x: frame.maxX, y: 0, width: bounds.width - frame.maxX, height: bounds.height)
        let songWidth = CGFloat(songSeconds) * pointsPerSecond
        scroller.contentSize = CGSize(width: songWidth, height: bounds.height)
        // ⚠️ THE INSETS ARE THE CLAMP: at the far left the song's start meets
        // the window's left edge, at the far right its end meets the right edge
        // — or, for a song shorter than the film, it cannot move at all.
        let right = max(bounds.width - frame.minX - songWidth, bounds.width - frame.maxX)
        scroller.contentInset = UIEdgeInsets(top: 0, left: frame.minX, bottom: 0, right: right)
        drawBars()
        place(at: start)
    }

    private func place(at seconds: Double) {
        let x = CGFloat(seconds) * pointsPerSecond - windowRect.minX
        scroller.setContentOffset(CGPoint(x: x, y: 0), animated: false)
    }

    private func seconds(atOffset x: CGFloat) -> Double {
        clamped(Double((x + windowRect.minX) / pointsPerSecond))
    }

    /// ⚠️ **A SHAPE LAYER, NOT A DRAWN BITMAP.** A four-minute song under a
    /// short film is thousands of points wide; a bitmap that long at screen
    /// scale is tens of megabytes, a path of bars is a few kilobytes.
    private func drawBars() {
        let pitch = Metrics.barPitch
        let perPoint = 1 / (Double(pointsPerSecond) * bucketSeconds)
        let songWidth = CGFloat(songSeconds) * pointsPerSecond
        let path = CGMutablePath()
        let middle = bounds.height / 2
        let tallest = bounds.height / 2 - 4
        var x: CGFloat = 0
        while x < songWidth, !peaks.isEmpty {
            let from = Int(Double(x) * perPoint)
            let to = min(Int(Double(x + pitch) * perPoint), peaks.count)
            guard from < peaks.count else { break }
            let peak = CGFloat(peaks[from..<max(to, from + 1)].max() ?? 0)
            let half = max(1, peak * tallest)
            path.addRoundedRect(
                in: CGRect(x: x, y: middle - half, width: Metrics.barWidth, height: half * 2),
                cornerWidth: Metrics.barWidth / 2, cornerHeight: Metrics.barWidth / 2
            )
            x += pitch
        }
        if peaks.isEmpty, songWidth > 0 {
            // Still reading: a flat line where the song will be drawn.
            path.addRect(CGRect(x: 0, y: middle - 0.5, width: songWidth, height: 1))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.frame = CGRect(x: 0, y: 0, width: songWidth, height: bounds.height)
        bars.path = path
        CATransaction.commit()
    }

    /// Layer colours do not follow the appearance on their own.
    private func resolveInks() {
        bars.fillColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        excerptFrame.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }

    // MARK: - The finger

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ ONLY WHILE A FINGER OR ITS FLING MOVES IT: `place` scrolls too.
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        start = seconds(atOffset: scrollView.contentOffset.x)
        updateReadout()
        onChange?(start)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        settle()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    /// ⚠️ **ROUNDED TO A HUNDREDTH, THEN CLAMPED**, so a start the eye cannot
    /// tell apart from the stored one is not a new item — and the offset's
    /// floating-point round trip never turns 11 into 10.99.
    private func settle() {
        start = clamped((seconds(atOffset: scroller.contentOffset.x) * 100).rounded() / 100)
        updateReadout()
        onSettle?(start)
    }

    // MARK: - VoiceOver

    private func updateReadout() {
        accessibilityValue = Self.clock(start)
    }

    override func accessibilityIncrement() { step(by: 1) }

    override func accessibilityDecrement() { step(by: -1) }

    private func step(by seconds: Double) {
        let next = clamped((start + seconds).rounded())
        guard next != start else { return }
        start = next
        place(at: start)
        updateReadout()
        onSettle?(start)
    }

    /// "0:12".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

extension MediaWaveformExcerptView {
    /// Internal for tests: the path a finger takes — dragged to `seconds`, not
    /// yet let go.
    func debugDrag(toSeconds seconds: Double) {
        layoutIfNeeded()
        start = clamped(seconds)
        place(at: start)
        updateReadout()
        onChange?(start)
    }

    /// Internal for tests: the finger lifts where it is.
    func debugRelease() { settle() }

    /// Internal for tests: where the window is, in the view.
    var debugWindowFrame: CGRect { excerptFrame.frame }

    /// Internal for tests: how many bars are drawn.
    var debugHasBars: Bool { !(bars.path?.isEmpty ?? true) }
}
