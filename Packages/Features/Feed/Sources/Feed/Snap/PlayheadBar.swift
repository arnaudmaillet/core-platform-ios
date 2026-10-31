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

/// A playhead bar on its own (#1964): a thin track with the shared drawing
/// on it (`PlayheadBarRenderer`) — the sound sheet's track, read-only.
@MainActor
final class PlayheadBarView: UIView {
    /// What it draws in: white over a picture, as the Shots strip does, or
    /// the ink of the surface it stands on (a sheet's vibrancy).
    enum Ink {
        case onMedia
        case surface(UIColor)
    }

    /// The track's thickness: the Shots clip bar's at rest.
    static let trackHeight: CGFloat = SnapMediaPageBarView.clipTrackHeight

    var ink: Ink = .onMedia {
        didSet { setNeedsLayout() }
    }

    private let track = UIView()
    private let renderer = PlayheadBarRenderer()
    private var fraction: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        track.isUserInteractionEnabled = false
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.cursorRoom)
    }

    /// Room for the cursor's disc above and below the track.
    static let cursorRoom: CGFloat = PlayheadBarRenderer.cursorDiameter

    /// Where the playhead is, 0…1; nil for no known position.
    func setProgress(_ fraction: Double?) {
        self.fraction = fraction
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The media is loading: the pulse in place of the played part.
    func setLoading(_ loading: Bool) {
        renderer.setLoading(loading, animated: window != nil && UIView.areAnimationsEnabled) { 1 }
        setNeedsLayout()
    }

    private var playedInk: UIColor {
        switch ink {
        case .onMedia: .white
        case .surface(let color): color
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Self.trackHeight
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        track.layer.cornerRadius = height / 2
        track.backgroundColor = playedInk.withAlphaComponent(SnapMediaPageBarView.restingAlpha)
        renderer.layoutPulse(on: track, inWindow: window != nil, ink: playedInk)
        guard let fraction, bounds.width > 0 else { return renderer.hidePlayed() }
        let played = renderer.drawPlayed(in: track, fraction: fraction, width: bounds.width, alpha: 1, ink: playedInk)
        renderer.drawCursor(
            in: self, trackMinX: 0, trackWidth: bounds.width, centerY: bounds.height / 2,
            played: played, trackHeight: height, handling: 0, awakeness: 0,
            ink: playedInk, alpha: renderer.fill.alpha
        )
    }

    #if DEBUG
    /// The played part's width, or nil when none is drawn. Tests.
    var debugPlayedWidth: CGFloat? { renderer.fill.isHidden ? nil : renderer.fill.bounds.width }
    var debugIsLoading: Bool { renderer.isLoading }
    #endif
}
