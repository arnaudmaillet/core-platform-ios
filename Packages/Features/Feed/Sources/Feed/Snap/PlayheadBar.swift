import DesignSystem
import UIKit

/// THE PLAYHEAD'S DRAWING, ONCE (#1964): the played part of a track, the
/// cursor at its end and the loading pulse — what the Shots page strip draws
/// on a clip's bar (#1305, #1537, #1544), and what the sound sheet draws for
/// its own track. The host owns the TRACK (its geometry, its resting ink)
/// and hands it in; this draws on it.
///
/// - The Shots strip: the track is the watched clip's segment, which grows
///   into the bar as the carousel moves (`SnapMediaPageBarView.clipness`);
///   the cursor lives in the strip, above the segments.
/// - The sound sheet: `PlayheadBarView`, a plain track of its own.
@MainActor
final class PlayheadBarRenderer {
    /// The cursor's disc after a release, and its pill while handled (#1544).
    static let cursorDiameter: CGFloat = 8
    static let handledCursorSize = CGSize(width: cursorDiameter, height: 14)
    /// The cross-fade between the pulse and the indicator (#1537).
    static let loadingFadeDuration: TimeInterval = 0.2
    /// One stretch of the pulse.
    static let pulseDuration: CFTimeInterval = 0.9
    static let pulseKey = "bar.pulse"

    /// The played part, re-parented into whichever track it is drawn on.
    let fill: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()
    /// The cursor at the played part's end, in the host's space.
    let cursor: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()
    /// A light stroke that stretches from the track's centre to its ends
    /// while fading, looping — TikTok's loading line (the owner's choice).
    let pulseView = UIView()
    let pulseStroke = CALayer()

    /// Whether the track's media is loading: its length unknown, or stalled.
    private(set) var isLoading = false
    /// The indicator's presence against the pulse's (1 / 0 at rest).
    private(set) var indicatorPresence: CGFloat = 1

    /// Draws the played part inside `track`, `fraction` of `width` long, at
    /// `alpha` (before the loading cross-fade), in `ink`. Returns its length.
    @discardableResult
    func drawPlayed(in track: UIView, fraction: Double, width: CGFloat, alpha: CGFloat, ink: UIColor) -> CGFloat {
        if fill.superview !== track {
            fill.removeFromSuperview()
            track.addSubview(fill)
        }
        fill.isHidden = false
        fill.backgroundColor = ink
        // ⚠️ AT ONCE, AT ITS POSITION (#1537, the owner 2026-10-21): the
        // indicator no longer grows in from the track's start (#1305). Its
        // only motion is the cross-fade with the loading pulse.
        fill.alpha = alpha * indicatorPresence
        let height = track.bounds.height
        let played = max(min(CGFloat(fraction), 1), 0) * width
        fill.frame = CGRect(x: 0, y: 0, width: played, height: height)
        fill.layer.cornerRadius = min(height, played) / 2
        return played
    }

    /// Nothing played to draw (no position, or not the bar): the fill and the
    /// cursor go.
    func hidePlayed() {
        fill.isHidden = true
        cursor.isHidden = true
    }

    /// The fill as it is drawn on `track`, or nil when it is drawn elsewhere.
    func fill(on track: UIView) -> UIView? {
        fill.superview === track ? fill : nil
    }

    /// The cursor at the end of the played part (#1544): as tall as the track
    /// at rest — it melts into the indicator's end — a disc once `awakeness`
    /// is 1, and a small vertical pill while `handling` is 1. It never
    /// shrinks below the track's height, and never hangs past its ends.
    func drawCursor(
        in host: UIView, trackMinX minX: CGFloat, trackWidth: CGFloat, centerY: CGFloat,
        played: CGFloat, trackHeight track: CGFloat, handling: CGFloat, awakeness: CGFloat,
        ink: UIColor, alpha: CGFloat
    ) {
        if cursor.superview !== host {
            cursor.removeFromSuperview()
            host.addSubview(cursor)
        }
        let disc = track + (Self.cursorDiameter - track) * awakeness
        let size = CGSize(
            width: disc + (Self.handledCursorSize.width - disc) * handling,
            height: disc + (Self.handledCursorSize.height - disc) * handling
        )
        let end = minX + played
        let x = min(max(end, minX + size.width / 2), minX + max(trackWidth, size.width) - size.width / 2)
        cursor.isHidden = false
        cursor.bounds = CGRect(origin: .zero, size: size)
        cursor.center = CGPoint(x: x, y: centerY)
        cursor.layer.cornerRadius = min(size.width, size.height) / 2
        cursor.backgroundColor = ink
        cursor.alpha = alpha
    }

    /// The media started or stopped loading: the pulse and the indicator
    /// cross-fade. `fillAlpha` is what the fill wears before the fade.
    func setLoading(_ loading: Bool, animated: Bool, fillAlpha: @escaping () -> CGFloat) {
        guard loading != isLoading else { return }
        isLoading = loading
        let presence: CGFloat = loading ? 0 : 1
        indicatorPresence = presence
        let fade = { [self] in
            pulseView.alpha = 1 - presence
            if !fill.isHidden { fill.alpha = fillAlpha() * presence }
        }
        if animated {
            UIView.animate(
                withDuration: Self.loadingFadeDuration, delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: fade
            ) { [weak self] _ in
                guard let self, !isLoading else { return }
                pulseStroke.removeAnimation(forKey: Self.pulseKey)
            }
        } else {
            fade()
            if !loading { pulseStroke.removeAnimation(forKey: Self.pulseKey) }
        }
    }

    /// Places the pulse on `track` while loading and runs its loop — or a
    /// still, dim track under Reduce Motion or Low Power Mode (no endless
    /// animation, #580). `track` nil, or no longer loading and faded: hidden.
    func layoutPulse(on track: UIView?, inWindow: Bool, ink: UIColor) {
        guard let track, isLoading || pulseView.alpha > 0.001 else {
            pulseView.isHidden = true
            return
        }
        if pulseView.superview !== track {
            pulseView.removeFromSuperview()
            pulseView.isUserInteractionEnabled = false
            pulseView.clipsToBounds = true
            if pulseStroke.superlayer == nil { pulseView.layer.addSublayer(pulseStroke) }
            track.addSubview(pulseView)
            if !isLoading { pulseView.alpha = 0 }
        }
        pulseStroke.backgroundColor = ink.cgColor
        pulseView.isHidden = false
        pulseView.frame = track.bounds
        pulseView.layer.cornerRadius = track.bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseStroke.frame = pulseView.bounds
        pulseStroke.cornerRadius = pulseView.bounds.height / 2
        CATransaction.commit()
        let moves = isLoading && inWindow && !MotionPreference.stillsDecoration
        if moves, pulseStroke.animation(forKey: Self.pulseKey) == nil {
            let stretch = CABasicAnimation(keyPath: "transform.scale.x")
            stretch.fromValue = 0.02
            stretch.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let loop = CAAnimationGroup()
            loop.animations = [stretch, fade]
            loop.duration = Self.pulseDuration
            loop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            loop.repeatCount = .infinity
            loop.isRemovedOnCompletion = false
            pulseStroke.add(loop, forKey: Self.pulseKey)
        } else if !moves {
            pulseStroke.removeAnimation(forKey: Self.pulseKey)
            // Still: a dim track — the bar says "not yet" without moving.
            pulseStroke.opacity = isLoading ? 0.35 : 0
        }
        if moves { pulseStroke.opacity = 1 }
    }

    /// The pulse, if it stands on `track`.
    func pulse(on track: UIView) -> UIView? {
        pulseView.superview === track ? pulseView : nil
    }
}

/// A playhead bar on its own (#1964): a track with the shared drawing on it
/// (`PlayheadBarRenderer`) and, when `isScrubbable`, the Shots clip bar's
/// handling — exactly the video's (the owner, 2026-10-31): it grows from
/// 3 to 8 pt under the finger, its cursor turns from a disc into a pill,
/// a drag seeks from where the playhead was, a tap seeks where it lands, and
/// the released position is held until the player catches up. The sound
/// sheet's track.
@MainActor
final class PlayheadBarView: UIView {
    /// What it draws in: white over a picture, as the Shots strip does, or
    /// the ink of the surface it stands on (a sheet's vibrancy).
    enum Ink {
        case onMedia
        case surface(UIColor)
    }

    typealias Strip = SnapMediaPageBarView

    var ink: Ink = .onMedia {
        didSet { setNeedsLayout() }
    }

    /// Whether a finger may move the playhead.
    var isScrubbable = false {
        didSet {
            scrubGesture.isEnabled = isScrubbable
            if isScrubbable { claimAncestorPans() }
        }
    }

    /// ⚠️ THE PANS ABOVE THE BAR STAND DOWN FOR ITS SCRUB (the owner,
    /// 2026-10-31: "as the video's does"). Shots tells every pan on its
    /// screen to wait for the clip bar's scrub to fail
    /// (`SnapFeedViewController`, "THE DISMISSAL STANDS DOWN FOR A SCRUB"):
    /// a drag along the bar must not also drag the sheet, scroll its posts
    /// or pop its stack. This bar does it itself, for every pan among its
    /// ancestors — `require(toFail:)`, not a delegate, which would let both
    /// run. A touch elsewhere never reaches the scrub and holds nobody up.
    private func claimAncestorPans() {
        guard isScrubbable, window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            for pan in view.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer && !claimedPans.contains(pan) {
                pan.require(toFail: scrubGesture)
                claimedPans.add(pan)
            }
            ancestor = view.superview
        }
    }

    private let claimedPans = NSHashTable<UIGestureRecognizer>.weakObjects()

    /// A drag along the bar began (the host pauses), moved the playhead
    /// (`onSeekRequested`, also a tap's), and let go (`onScrubEnded`, with the
    /// released position, nil when cancelled).
    var onScrubBegan: (() -> Void)?
    var onSeekRequested: ((Double) -> Void)?
    var onScrubEnded: ((Double?) -> Void)?

    private let track = UIView()
    private let renderer = PlayheadBarRenderer()
    private var playhead: Double?
    private var heldPlayhead: Double?
    private var heldReleasedAt: CFTimeInterval?
    private var drawnPlayhead: Double? { heldPlayhead ?? playhead }

    private let scrubGesture: UILongPressGestureRecognizer = {
        let scrub = UILongPressGestureRecognizer()
        scrub.minimumPressDuration = 0
        scrub.allowableMovement = .greatestFiniteMagnitude
        scrub.cancelsTouchesInView = true
        return scrub
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.isUserInteractionEnabled = false
        addSubview(track)
        alpha = Strip.restingOpacity
        scrubGesture.addTarget(self, action: #selector(handleScrubGesture(_:)))
        scrubGesture.isEnabled = false
        addGestureRecognizer(scrubGesture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.cursorRoom)
    }

    /// The bar's footprint: the cursor's disc. The handled track and pill
    /// grow outside it, which costs the layout nothing.
    static let cursorRoom: CGFloat = PlayheadBarRenderer.cursorDiameter

    /// Where the playhead is, 0…1; nil for no known position.
    func setProgress(_ fraction: Double?) {
        let moved = playhead != fraction
        let wasHeld = heldPlayhead != nil
        playhead = fraction
        releaseHeldPlayheadIfCaughtUp()
        guard moved || (wasHeld && heldPlayhead == nil) else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The media is loading: the pulse in place of the played part.
    func setLoading(_ loading: Bool) {
        renderer.setLoading(loading, animated: window != nil && UIView.areAnimationsEnabled) { 1 }
        setNeedsLayout()
    }

    private func releaseHeldPlayheadIfCaughtUp(now: CFTimeInterval = CACurrentMediaTime()) {
        guard heldPlayhead != nil, let releasedAt = heldReleasedAt else { return }
        let caughtUp = playhead.map { abs($0 - (heldPlayhead ?? $0)) <= Strip.handoverTolerance } ?? true
        guard caughtUp || now - releasedAt >= Strip.handoverTimeout else { return }
        heldPlayhead = nil
        heldReleasedAt = nil
    }

    // MARK: - Ink, awake and at rest (the strip's, #1544)

    private var isAwake = false
    private var baseInk: UIColor {
        switch ink {
        case .onMedia: .white
        case .surface(let color): color
        }
    }
    private var fillInk: UIColor { baseInk.withAlphaComponent(isAwake ? 1 : Strip.restingFillInk) }
    private var wakeTimer: Timer?

    private func wake() {
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: Strip.wakeDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rest() }
        }
        guard alpha < 1 || !isAwake else { return }
        isAwake = true
        animate(\.awakeness, to: 1, duration: 0.18)
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.renderer.fill.backgroundColor = self.fillInk
        }
    }

    private func rest() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        isAwake = false
        animate(\.awakeness, to: 0, duration: 0.45)
        UIView.animate(withDuration: 0.45, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = Strip.restingOpacity
            self.renderer.fill.backgroundColor = self.fillInk
        }
    }

    // MARK: - The tweens (the strip's)

    private var handling = Strip.Tween()
    private var awakeness = Strip.Tween()
    private var tweenLink: CADisplayLink?

    private func animate(_ tween: ReferenceWritableKeyPath<PlayheadBarView, Strip.Tween>, to target: CGFloat, duration: TimeInterval) {
        let moves = window != nil && !UIAccessibility.isReduceMotionEnabled
        self[keyPath: tween].move(to: target, duration: moves ? duration : 0, now: CACurrentMediaTime())
        guard handling.isMoving || awakeness.isMoving else { return setNeedsLayout() }
        guard tweenLink == nil else { return }
        let link = CADisplayLink(target: TweenTarget(self), selector: #selector(TweenTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        tweenLink = link
    }

    fileprivate func stepTweens() {
        let now = CACurrentMediaTime()
        handling.step(now: now)
        awakeness.step(now: now)
        setNeedsLayout()
        layoutIfNeeded()
        guard !handling.isMoving, !awakeness.isMoving else { return }
        tweenLink?.invalidate()
        tweenLink = nil
    }

    @MainActor
    private final class TweenTarget: NSObject {
        weak var bar: PlayheadBarView?
        init(_ bar: PlayheadBarView) { self.bar = bar }
        @objc func tick(_ link: CADisplayLink) {
            guard let bar else { return link.invalidate() }
            bar.stepTweens()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claimAncestorPans()
        guard window == nil else { return }
        tweenLink?.invalidate()
        tweenLink = nil
        handling.settle(at: 0)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Strip.clipTrackHeight + (Strip.handledTrackHeight - Strip.clipTrackHeight) * handling.value
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        track.layer.cornerRadius = height / 2
        track.backgroundColor = baseInk.withAlphaComponent(Strip.restingAlpha)
        renderer.layoutPulse(on: track, inWindow: window != nil, ink: baseInk)
        guard let fraction = drawnPlayhead, bounds.width > 0 else { return renderer.hidePlayed() }
        let played = renderer.drawPlayed(in: track, fraction: fraction, width: bounds.width, alpha: 1, ink: fillInk)
        renderer.drawCursor(
            in: self, trackMinX: 0, trackWidth: bounds.width, centerY: bounds.height / 2,
            played: played, trackHeight: height, handling: handling.value, awakeness: awakeness.value,
            ink: fillInk, alpha: renderer.fill.alpha
        )
    }

    // MARK: - The scrub (the strip's, without pages)

    private var seekAnchor: Double?
    private var touchDownX: CGFloat = 0
    private var travelled = false
    private var isDraggingPlayhead = false

    @objc private func handleScrubGesture(_ recognizer: UIGestureRecognizer) {
        handleScrub(recognizer.state, atX: recognizer.location(in: self).x)
    }

    private func handleScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        guard isScrubbable else { return }
        switch state {
        case .began:
            wake()
            touchDownX = x
            travelled = false
            isDraggingPlayhead = false
            animate(\.handling, to: 1, duration: Strip.handleDuration)
            seekAnchor = drawnPlayhead ?? 0
        case .changed:
            wake()
            if abs(x - touchDownX) > Strip.travelThreshold { travelled = true }
            guard travelled else { return }
            if !isDraggingPlayhead {
                isDraggingPlayhead = true
                heldReleasedAt = nil
                onScrubBegan?()
            }
            seek(draggedTo: x)
        case .ended, .cancelled, .failed:
            wake()
            animate(\.handling, to: 0, duration: Strip.handleDuration)
            if isDraggingPlayhead {
                isDraggingPlayhead = false
                heldReleasedAt = CACurrentMediaTime()
                onScrubEnded?(state == .ended ? heldPlayhead : nil)
                if state != .ended {
                    heldPlayhead = nil
                    heldReleasedAt = nil
                    setNeedsLayout()
                }
                return
            }
            guard state == .ended, !travelled, bounds.width > 1 else { return }
            let fraction = Double(min(max(x / bounds.width, 0), 1))
            heldPlayhead = fraction
            heldReleasedAt = CACurrentMediaTime()
            setNeedsLayout()
            onSeekRequested?(fraction)
        default:
            break
        }
    }

    private func seek(draggedTo x: CGFloat) {
        guard let seekAnchor, bounds.width > 0 else { return }
        let fraction = min(max(seekAnchor + Double((x - touchDownX) / bounds.width), 0), 1)
        heldPlayhead = fraction
        setNeedsLayout()
        layoutIfNeeded()
        onSeekRequested?(fraction)
    }

    /// The touch reaches past the thin bar, as the strip's does.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let grown = bounds.insetBy(dx: 0, dy: -(44 - bounds.height) / 2)
        return grown.contains(point)
    }

    #if DEBUG
    /// The played part's width, or nil when none is drawn. Tests.
    var debugPlayedWidth: CGFloat? { renderer.fill.isHidden ? nil : renderer.fill.bounds.width }
    var debugIsLoading: Bool { renderer.isLoading }
    var debugTrackHeight: CGFloat { track.bounds.height }
    var debugCursorSize: CGSize? { renderer.cursor.isHidden ? nil : renderer.cursor.bounds.size }
    var debugHeldPlayhead: Double? { heldPlayhead }
    var debugScrubGesture: UIGestureRecognizer { scrubGesture }
    /// Whether `pan` was told to wait for this bar's scrub to fail. Tests.
    func debugHolds(_ pan: UIGestureRecognizer) -> Bool { claimedPans.contains(pan) }
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) { handleScrub(state, atX: x) }
    func debugFinishTweens() {
        let later = CACurrentMediaTime() + 10
        handling.step(now: later)
        awakeness.step(now: later)
        tweenLink?.invalidate()
        tweenLink = nil
        setNeedsLayout()
        layoutIfNeeded()
    }
    #endif
}
