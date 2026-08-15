import UIKit

/// A toolbar-family currency badge: the coin glyph and the spendable
/// balance in one capsule. Two hosts wear it — the map's navigation bar
/// (next to the bell, where tapping opens the claim sheet) and the snap
/// feed's trailing run (display-only, left of the author pill) — which is
/// why it lives in DesignSystem: one face for the one number, wherever it
/// shows. A custom-view bar item (an image-only item can't carry the
/// count), so iOS 26 wraps it in its own glass capsule; hosts keep it out
/// of shared platters with `sharesBackground = false` or a fixed-space
/// spacer (`LeadingSelectorItem`'s doctrine).
///
/// # Built from SUBVIEWS, not `UIButton.Configuration` — deliberately
/// A configuration button re-renders its content on a DEFERRED pass, so at
/// the moment a balance changes every width you can ask for is stale:
/// `intrinsicContentSize` still answers the old spelling, a fitting pass
/// resolves the old constraints, and a hand-computed width measured ~4pt
/// narrow and caused the very wrap it meant to prevent (all three measured
/// in-sim as "120" wrapping into "12/0"). A plain image view + label whose
/// text is set synchronously make `intrinsicContentSize` (overridden below)
/// exact at the instant of the change — which the reinstall dance depends
/// on.
///
/// # The coin's ring
/// The next-claim countdown is drawn as a thin gold RING around the coin,
/// closing clockwise as the claim approaches and standing complete while
/// one is ready. Around the COIN, not the capsule: the glass pill is the
/// bar's own drawing, rendered outside this view's bounds, so a border
/// there cannot hug its true edge — the coin is already a circle, and a
/// ring around it reads as "this charges up". The ring is a single linear
/// `strokeEnd` animation to full over the remaining time (no per-second
/// timer); its window is remembered as wall-clock dates so a window
/// re-attach (tab switch, push) resumes at the correct fraction instead of
/// replaying from where it left off.
///
/// # Width growth
/// A bar measures a custom view once, at install, and the wrapper then pins
/// that size — so when the count's width actually changes, the badge asks
/// its host (via `onFittedWidthChange`) to install a FRESH bar item around
/// it. Fired async so the mutation never lands mid-bar-layout.
///
/// When the wallet has a claim waiting, the coin also PULSES — a slow scale
/// breath with a gold glow — and stops the moment the claim is taken or the
/// day's cap is hit. Pulse and ring are both re-armed on window attach
/// because repeating/running `CAAnimation`s die silently every time the
/// view leaves a window, which would strand the badge looking idle while a
/// reward waits.
public final class WalletBadgeButton: UIButton {

    /// The countdown the ring renders: how far along the wait already is,
    /// and how many seconds remain until the claim unlocks.
    public struct ClaimProgress {
        public let fraction: Double
        public let remaining: TimeInterval
        public init(fraction: Double, remaining: TimeInterval) {
            self.fraction = min(max(fraction, 0), 1)
            self.remaining = max(remaining, 0)
        }
    }

    /// Fired (async, next runloop turn) when the count's fitted width
    /// actually changed — the hosts' cue to REINSTALL the bar item with a
    /// fresh `UIBarButtonItem`, the only thing a bar measures anew.
    public var onFittedWidthChange: (() -> Void)?

    private let coinView = UIImageView()
    private let countLabel = UILabel()
    private let ringLayer = CAShapeLayer()

    /// The claim-waiting state as INTENT, separate from the layer's current
    /// animations — the layer forgets on window detach, this doesn't.
    private var wantsPulse = false
    /// The ring's window as wall-clock dates (start = where fraction 0 was,
    /// end = the unlock instant), so any later re-arm derives the CURRENT
    /// fraction from the clock instead of resuming a stale one. Nil = no
    /// countdown (ring hidden or standing full).
    private var ringWindow: (start: Date, end: Date)?
    /// Whether the ring should stand complete (a claim is ready).
    private var ringStandsFull = false

    private enum Metrics {
        static let height: CGFloat = 36
        static let ringDiameter: CGFloat = 26
        static let ringWidth: CGFloat = 2
    }

    public init() {
        super.init(frame: .zero)

        // The points token: a gold STAR, deliberately not a currency glyph —
        // the balance is app points, and a dollar sign promises money the
        // product doesn't hold. `.alwaysOriginal` because glass vibrancy
        // ignores tint for palette symbols (the bell badge's rule); the
        // explicit tint below is the belt for renderers that drop the
        // palette. Static — only the count ever changes.
        let palette = UIImage.SymbolConfiguration(paletteColors: [.white, .systemYellow])
            .applying(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        coinView.image = UIImage(systemName: "star.circle.fill", withConfiguration: palette)?
            .withRenderingMode(.alwaysOriginal)
        coinView.tintColor = .systemYellow
        coinView.isUserInteractionEnabled = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        countLabel.textColor = .label
        countLabel.isUserInteractionEnabled = false

        for subview in [coinView, countLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            coinView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            coinView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // sm, not xs: the star glyph fills its bounds edge-to-edge
            // (unlike the old currency glyph), so 4pt read as glued.
            countLabel.leadingAnchor.constraint(equalTo: coinView.trailingAnchor, constant: Spacing.sm),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.sm),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // 999, never required: the bar's first pass pins its item wrapper
        // with autoresizing constraints, and anything required loses to
        // that with a console break (the circular bar-button doctrine).
        let height = heightAnchor.constraint(equalToConstant: Metrics.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        ringLayer.fillColor = nil
        ringLayer.lineWidth = Metrics.ringWidth
        ringLayer.lineCap = .round
        ringLayer.strokeColor = UIColor.systemYellow.cgColor
        ringLayer.strokeEnd = 0
        ringLayer.isHidden = true
        layer.addSublayer(ringLayer)

        update(balance: 0, claimAvailable: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The count as currently rendered — a test seam (the label itself is
    /// an implementation detail).
    public var renderedCount: String? { countLabel.text }

    /// Exact and SYNCHRONOUS — the whole reason this view is subview-built.
    override public var intrinsicContentSize: CGSize {
        let icon = coinView.image?.size.width ?? 0
        let text = countLabel.intrinsicContentSize.width
        return CGSize(
            width: ceil(Spacing.sm + icon + Spacing.sm + text + Spacing.sm),
            height: Metrics.height
        )
    }

    /// One setter for every fact the badge renders — count, claim state and
    /// countdown always move together (they come from the same snapshot),
    /// so there is no half-updated frame.
    public func update(balance: Int, claimAvailable: Bool, claimProgress: ClaimProgress? = nil) {
        // The count, in the app's one compact spelling; monospaced digits
        // so a spend doesn't make the capsule tremble.
        let before = intrinsicContentSize.width
        countLabel.text = balance.formattedCompact()
        invalidateIntrinsicContentSize()
        // Only once INSTALLED (in a window): pre-install the item has never
        // been measured, so the first install simply takes the right size —
        // and a reinstall fired during a push would rebuild the trailing
        // run mid-transition, which is its own flash.
        if abs(intrinsicContentSize.width - before) > 0.5, window != nil {
            // Async: the reinstall replaces bar items, and this update may
            // already be running inside a bar layout pass.
            DispatchQueue.main.async { [weak self] in self?.onFittedWidthChange?() }
        }

        accessibilityLabel = claimAvailable
            ? "Wallet, \(balance) points, reward available"
            : "Wallet, \(balance) points"
        setPulsing(claimAvailable)

        // The ring: full and still when a claim waits; charging toward the
        // unlock instant while one doesn't; absent without a countdown.
        ringStandsFull = claimAvailable
        if claimAvailable {
            ringWindow = nil
        } else if let progress = claimProgress, progress.remaining > 0, progress.fraction < 1 {
            // Reconstruct the whole window from (fraction, remaining) so a
            // re-arm can place "now" on it: start is where fraction 0 was.
            let total = progress.remaining / (1 - progress.fraction)
            let now = Date()
            ringWindow = (start: now.addingTimeInterval(-(total - progress.remaining)),
                          end: now.addingTimeInterval(progress.remaining))
        } else {
            ringWindow = nil
        }
        applyRing()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Re-arm: neither the repeating pulse nor the running ring fill
        // survived the detach.
        if wantsPulse { addPulseIfMissing() }
        applyRing()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard coinView.bounds.width > 0 else { return }
        let center = coinView.center
        let radius = Metrics.ringDiameter / 2
        ringLayer.frame = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: Metrics.ringDiameter, height: Metrics.ringDiameter
        )
        // From 12 o'clock, clockwise — the reading a countdown dial trained.
        ringLayer.path = UIBezierPath(
            arcCenter: CGPoint(x: radius, y: radius), radius: radius - Metrics.ringWidth / 2,
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
    }

    // MARK: - Ring

    private static let ringFillKey = "wallet.ring"

    private func applyRing() {
        ringLayer.removeAnimation(forKey: Self.ringFillKey)
        if ringStandsFull {
            ringLayer.isHidden = false
            ringLayer.strokeEnd = 1
            return
        }
        guard let ringWindow, window != nil else {
            // Off-window the model state is enough — didMoveToWindow
            // replays this with a window to animate in. No countdown at
            // all hides the ring outright.
            ringLayer.isHidden = ringWindow == nil
            return
        }
        let now = Date()
        let total = ringWindow.end.timeIntervalSince(ringWindow.start)
        let elapsed = now.timeIntervalSince(ringWindow.start)
        let fraction = total > 0 ? min(max(elapsed / total, 0), 1) : 1
        ringLayer.isHidden = false
        ringLayer.strokeEnd = 1
        guard fraction < 1 else { return }
        // One linear fill to the unlock instant — no per-second timer; the
        // model value above is already 1 so the finished state needs no
        // completion handling.
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = fraction
        fill.toValue = 1
        fill.duration = ringWindow.end.timeIntervalSince(now)
        ringLayer.add(fill, forKey: Self.ringFillKey)
    }

    // MARK: - Pulse

    private func setPulsing(_ on: Bool) {
        wantsPulse = on
        if on {
            addPulseIfMissing()
        } else {
            coinView.layer.removeAnimation(forKey: Self.pulseKey)
            coinView.layer.shadowOpacity = 0
        }
    }

    private static let pulseKey = "wallet.pulse"

    private func addPulseIfMissing() {
        guard window != nil,
              coinView.layer.animation(forKey: Self.pulseKey) == nil else { return }
        // A breath, not a bounce: subtle enough to live in a toolbar, alive
        // enough to say "something is waiting".
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.18
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coinView.layer.add(pulse, forKey: Self.pulseKey)
        // The glow rides the same state, static while the scale breathes.
        coinView.layer.shadowColor = UIColor.systemYellow.cgColor
        coinView.layer.shadowOpacity = 0.8
        coinView.layer.shadowRadius = 6
        coinView.layer.shadowOffset = .zero
    }
}
