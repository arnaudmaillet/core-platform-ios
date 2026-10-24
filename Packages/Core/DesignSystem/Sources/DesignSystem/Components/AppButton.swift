import ObjectiveC
import UIKit

/// The app's button with WORDS (#931, #1666): Follow, Message, Edit Profile,
/// a price — a `UIButton` driven by its configuration, on `AppControl`'s
/// shared behaviour (the press, haptics, hit region, gating, appear / go,
/// menu), with what words need on top: the content change a system Liquid
/// Glass button makes, a reserved slot and its anchor, a placeholder while
/// the answer is unknown, a held load. A button that is ONE SYMBOL — a 44pt
/// bubble, a card's glyph and its count — is `AppIconButton`.
///
/// ```
///   ╭──────────────╮  prominent · quiet · tinted · material
///   │  ✓ Following │  capsule or card
///   ╰──────────────╯
/// ```
@MainActor
open class AppButton: AppControl {
    // MARK: - Look

    public enum Aspect: Equatable, Sendable {
        /// Words on a visible ground. (Content alone — a bare glyph — is
        /// `AppIconButton`'s.)
        case pill(Ground)
    }

    public enum Shape: Equatable, Sendable {
        case capsule
        /// A rounded rectangle.
        case card
    }

    public enum Size: CaseIterable, Sendable {
        /// A person row's Follow / Accept.
        case row
        /// The profile header's capsules.
        case header
    }

    /// What the button says: a title, a symbol, a count, or a mix.
    public struct Content: Equatable, Sendable {
        public var title: String?
        public var symbol: String?
        /// Drawn compact (1.2K) in monospaced digits; it is also the
        /// accessibility value.
        public var count: Int?
        /// Where the symbol stands against the words.
        public var imagePlacement: NSDirectionalRectEdge

        public init(
            title: String? = nil, symbol: String? = nil, count: Int? = nil,
            imagePlacement: NSDirectionalRectEdge = .leading
        ) {
            self.title = title
            self.symbol = symbol
            self.count = count
            self.imagePlacement = imagePlacement
        }

        public static func title(_ title: String) -> Content { Content(title: title) }
        public static func symbol(_ symbol: String) -> Content { Content(symbol: symbol) }

        /// The words drawn: the title, then the count.
        var text: String? {
            let parts = [title, count.map(CountFormatter.compactString(for:))].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Whether the content is known, and whether an action is pending.
    public enum Phase: Equatable, Sendable {
        case content
        /// The backend has not answered yet: a bone at the reserved width,
        /// inert, claiming no answer.
        case placeholder
        /// An action is in flight: the content held blurred under a sheen, the
        /// width held, re-taps ignored, still focusable for VoiceOver with a
        /// busy label.
        case loading
    }

    /// The content change and the load (`AppButtonBlur`), as measured on a
    /// system Liquid Glass bar item (2026-10-23). The shared ones are
    /// `AppControl.Metrics`.
    public enum MorphMetrics {
        /// The size's spring — its overshoot is the bounce.
        public static let morphDuration: TimeInterval = 0.33
        public static let morphBounce: CGFloat = 0.3
        /// How long the stand-in plays, the spring settled.
        public static let morphSettle: TimeInterval = 0.55
        /// How far the capsule swells as it changes size fastest: the most,
        /// for a change of `morphSwellReach` points or more; the least, for
        /// a change in place.
        public static let morphSwell: CGFloat = 0.16
        public static let morphSwellBase: CGFloat = 0.06
        public static let morphSwellReach: CGFloat = 100
        /// The swell's course, measured on the system's bar item: (seconds,
        /// share of the depth).
        public static let morphSwellCurve: [(time: TimeInterval, share: CGFloat)] = [
            (0, 0), (0.125, 1), (0.27, 0), (0.37, -0.14), (0.5, 0),
        ]
        /// How far the content blurs, in points.
        public static let morphBlurRadius: CGFloat = 5
        /// The content's blur levels, cross-fading into each other.
        public static let morphBlurLevels = 3
        /// The samples the frame, the grounds and the swell follow.
        public static let morphSamples = 33
        /// When the old content fades out (blurring from the start), the new
        /// one fades in, and the new one sharpens, in seconds.
        public static let morphContentOut: ClosedRange<TimeInterval> = 0.03...0.11
        public static let morphContentIn: ClosedRange<TimeInterval> = 0.04...0.12
        public static let morphContentSharpens: ClosedRange<TimeInterval> = 0.06...0.22
        /// When the old ground's look cross-fades into the new one's.
        public static let morphGroundMix: ClosedRange<TimeInterval> = 0.03...0.2
        /// The hand-off from the stand-in to the button itself, at the end.
        public static let morphHandoff: TimeInterval = 0.08
        /// A load: the sheen's sweep across the blurred content, and the
        /// content's ink when the load is not drawn.
        public static let loadingSheen: TimeInterval = 1.1
        public static let loadingInkAlpha: CGFloat = 0.4
    }

    // MARK: - State

    public let aspect: Aspect
    public let size: Size
    public let shape: Shape
    public private(set) var content: Content
    public private(set) var phase: Phase = .content

    /// The ground while selected. Nil swaps prominent and quiet (Follow →
    /// Following) and keeps the others.
    public var selectedGround: Ground? { didSet { refresh() } }
    /// The placeholder's width, when the caller knows it.
    public var reservedWidth: CGFloat? { didSet { invalidateIntrinsicContentSize() } }
    /// Or the contents the answer may bring: the placeholder holds the
    /// widest, so the answer never moves its neighbours.
    public var reservedContents: [Content] = [] {
        didSet {
            reservedSizeCache = nil
            invalidateIntrinsicContentSize()
            if holdsReservedSize { refresh() }
        }
    }
    /// Holds a slot the size of the largest of `reservedContents` — the
    /// widest, the tallest — in EVERY phase, not only the placeholder's: a
    /// toggle (Follow ⇄ Following ⇄ Requested) never moves its neighbours.
    /// The ground hugs the content shown, set in the slot by `morphAnchor`
    /// — centred, or against the edge it keeps (the owner, 2026-10-23).
    public var holdsReservedSize = false {
        didSet {
            refresh()
            invalidateIntrinsicContentSize()
        }
    }

    /// The side a content change grows and shrinks from (the owner,
    /// 2026-10-23): that edge stays put through the whole morph, the spring,
    /// and its overshoot all on the other side. A row's trailing
    /// button (Follow beside a ✕) is `.trailing`; a leading one `.leading`.
    /// `.top` and `.bottom` keep that edge for a change of height; `.center`
    /// keeps the middle. With `holdsReservedSize` it is also where the
    /// ground sits in the slot.
    public enum MorphAnchor: Sendable, CaseIterable {
        case leading
        case center
        case trailing
        case top
        case bottom
    }
    public var morphAnchor: MorphAnchor = .center {
        didSet { if holdsReservedSize { refresh() } }
    }
    /// `reservedSize`, measured once per text size.
    private var reservedSizeCache: (category: UIContentSizeCategory, size: CGSize)?
    /// The content's own size, measured once per content and text size.
    private var naturalSizeCache: (content: Content, category: UIContentSizeCategory, size: CGSize)?
    /// The slot's margins the configuration draws now. ⚠️ Not `slotMargins`:
    /// an animated `setContent` sets the new content before the morph
    /// draws the old state, which still stands at the old margins.
    private var drawnSlotMargins: NSDirectionalEdgeInsets = .zero
    /// What VoiceOver hears while an action is in flight ("Following…").
    /// Nil: "In progress".
    public var busyLabel: String? { didSet { refreshAccessibility() } }

    /// The veil a content change falls back to when the button cannot be
    /// drawn (a material over a photograph).
    private let veil = UIVisualEffectView(effect: nil)
    private var bone: SkeletonBoneView?
    /// The size an in-flight action holds: the spinner is taller than a
    /// line of words, and narrower than most.
    private var heldSize: CGSize?
    private var morphGeneration = 0
    /// The blurred stand-in drawn over the button while its content changes
    /// (`blurMorph`); the button itself is transparent under it.
    private var blurOverlays: [UIView] = []
    /// The morph those stand-ins play.
    private var flight: MorphFlight?
    /// A load drawn as held (`holdLoad`): the content as it stood, at its
    /// most blurred — where the morph that ends the load starts from.
    private var heldLoad: MorphSide?

    // MARK: - Init

    /// - Parameters:
    ///   - sound: the tick a tap plays (`UISound.tap`, gated by Interface
    ///     Sounds). Nil by default. Decided here, once (`AppControl`).
    ///   - dims: the press also fades the button a little. Off by default:
    ///     a pill has its ground to highlight.
    public init(
        aspect: Aspect, size: Size, shape: Shape = .capsule, content: Content,
        sound: UISound? = nil, dims: Bool? = nil
    ) {
        self.aspect = aspect
        self.size = size
        self.shape = shape
        self.content = content
        // A pill presses as a system glass button does: it swells.
        super.init(pressStyle: .swell, sound: sound, dims: dims ?? false)
        veil.isUserInteractionEnabled = false
        veil.clipsToBounds = true
        veil.isHidden = true
        addSubview(veil)
        refresh()
    }

    // MARK: - Layout

    override open func layoutSubviews() {
        super.layoutSubviews()
        let ground = groundRect
        veil.frame = ground
        veil.layer.cornerRadius = groundCornerRadius
        bone?.frame = ground
        bringSubviewToFront(veil)
        if let bone { bringSubviewToFront(bone) }
    }

    /// A capsule's ends are its shorter side's (a symbol over its words
    /// stands taller than wide); a card's corners are fixed.
    override open func groundCornerRadius(for size: CGSize) -> CGFloat {
        switch shape {
        case .capsule: super.groundCornerRadius(for: size)
        case .card: Metrics.cardRadius
        }
    }

    private func cornerRadius(for size: CGSize) -> CGFloat { groundCornerRadius(for: size) }

    override open var intrinsicContentSize: CGSize {
        if let heldSize { return heldSize }
        var measured = super.intrinsicContentSize
        if phase == .placeholder, let reserved = placeholderWidth {
            measured.width = reserved
        } else if holdsReservedSize, let reserved = reservedSize {
            measured.width = max(measured.width, reserved.width)
            measured.height = max(measured.height, reserved.height)
        }
        return measured
    }

    /// The width a placeholder holds: the one given, else the widest of the
    /// contents the answer may bring.
    public var placeholderWidth: CGFloat? {
        reservedWidth ?? reservedSize?.width
    }

    /// The largest of `reservedContents`: the widest, the tallest.
    private var reservedSize: CGSize? {
        guard !reservedContents.isEmpty else { return nil }
        let category = traitCollection.preferredContentSizeCategory
        if let cached = reservedSizeCache, cached.category == category { return cached.size }
        let sizes = reservedContents.map { fittingSize(for: $0) }
        let size = CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        reservedSizeCache = (category, size)
        return size
    }

    /// The slot's margins around the ground, by `morphAnchor`: zero unless
    /// `holdsReservedSize`.
    private var slotMargins: NSDirectionalEdgeInsets {
        guard holdsReservedSize, phase != .placeholder, let reserved = reservedSize else { return .zero }
        let category = traitCollection.preferredContentSizeCategory
        let natural: CGSize
        if let cached = naturalSizeCache, cached.content == content, cached.category == category {
            natural = cached.size
        } else {
            natural = fittingSize(for: content)
            naturalSizeCache = (content, category, natural)
        }
        let spareWidth = max(0, reserved.width - natural.width)
        let spareHeight = max(0, reserved.height - natural.height)
        var margins = NSDirectionalEdgeInsets(
            top: spareHeight / 2, leading: spareWidth / 2, bottom: spareHeight / 2, trailing: spareWidth / 2
        )
        switch morphAnchor {
        case .leading: margins.leading = 0; margins.trailing = spareWidth
        case .trailing: margins.leading = spareWidth; margins.trailing = 0
        case .top: margins.top = 0; margins.bottom = spareHeight
        case .bottom: margins.top = spareHeight; margins.bottom = 0
        case .center: break
        }
        return margins
    }

    /// Where the ground is drawn: the bounds, less the slot's margins.
    override open var groundRect: CGRect {
        let margins = drawnSlotMargins
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return bounds.inset(by: UIEdgeInsets(
            top: margins.top,
            left: rightToLeft ? margins.trailing : margins.leading,
            bottom: margins.bottom,
            right: rightToLeft ? margins.leading : margins.trailing
        ))
    }

    /// The size the button takes for `content`, resolved now — not at the
    /// next update pass (a configuration resolves late: the cell-accessory
    /// trap, see `cellAccessory`).
    public func fittingSize(for content: Content) -> CGSize {
        let scratch = UIButton(configuration: configuration(for: content, phase: .content))
        scratch.updateConfiguration()
        let fitted = scratch.sizeThatFits(UIView.layoutFittingCompressedSize)
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    // MARK: - Content

    /// Shows `content`. Animated, it is the content change a system glass
    /// button makes (`blurMorph`); the width follows in the same beat.
    public func setContent(_ content: Content, animated: Bool) {
        guard content != self.content else { return }
        let old = self.content
        self.content = content
        // The answer to a load drawn as held: on the model, under the
        // stand-in, until the load ends and the morph shows it.
        if heldLoad != nil {
            refresh()
            return
        }
        guard animated, window != nil, phase == .content else {
            land()
            return
        }
        morph(reduced: reducesMotion(), old: old)
    }

    /// Shows `content` and the selection together — Follow → Following is
    /// both a new title and a quiet ground — swapped under ONE blur (or one
    /// cross-fade), so the two never land a beat apart.
    public func setContent(_ content: Content, selected: Bool, animated: Bool) {
        guard selected != isSelected else {
            setContent(content, animated: animated)
            return
        }
        guard content != self.content else {
            setSelected(selected, animated: animated)
            return
        }
        let old = self.content
        self.content = content
        if heldLoad != nil {
            isSelected = selected
            refresh()
            return
        }
        guard animated, window != nil, phase == .content else {
            isSelected = selected
            land()
            return
        }
        morph(reduced: reducesMotion(), old: old) { self.isSelected = selected }
    }

    /// An immediate change: the content lands whole, at its own width, and a
    /// morph still running (a reused row's last person) ends here rather than
    /// swapping in later.
    private func land() {
        morphGeneration += 1
        endBlurMorph()
        veil.layer.removeAllAnimations()
        veil.effect = nil
        veil.isHidden = true
        refresh()
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }

    /// The old content blurs and fades out, the new one unblurs in; a
    /// cross-fade under Reduce Motion.
    private func morph(reduced: Bool, old: Content, swap: (() -> Void)? = nil) {
        morphGeneration += 1
        let generation = morphGeneration
        if reduced {
            record(.crossFade)
            UIView.transition(with: self, duration: Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                swap?()
                self.refresh()
                self.layoutIfNeeded()
            }
            resize(reduced: true)
            return
        }
        record(.blurMorph)
        if blurMorph(old: old, swap: swap) { return }
        // No host or no picture to draw (a material over a photograph, which
        // `layer.render` cannot draw): the veil.
        veil.isHidden = false
        let half = MorphMetrics.morphDuration / 2
        UIView.animate(withDuration: half, delay: 0, options: [.beginFromCurrentState, .curveEaseIn, .allowUserInteraction]) {
            self.veil.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        } completion: { _ in
            guard generation == self.morphGeneration else { return }
            swap?()
            self.refresh()
            self.resize(reduced: false)
            UIView.animate(withDuration: half, delay: 0.04, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]) {
                self.veil.effect = nil
            } completion: { _ in
                guard generation == self.morphGeneration else { return }
                self.veil.isHidden = true
            }
        }
    }

    /// The content change, as a system Liquid Glass button makes it, without
    /// its look (the owner, 2026-10-23; measured frame by frame on a bar
    /// item swapped for a longer one): the ground resizes on a spring, the
    /// neighbours with it, from the side `morphAnchor` keeps; the whole
    /// capsule swells as it changes size — by how fast it changes, a touch
    /// under as it springs back — its old and new looks cross-fading; the
    /// old content blurs out where it stood while the new one blurs in where
    /// it lands, both cut to the capsule, which reveals the new one as it
    /// grows.
    ///
    /// ⚠️ THE CAPSULE STAYS SHARP: a blur softens the capsule's own edge
    /// too, and a softened edge reads as an edge that moves (filmed, the
    /// owner 2026-10-23). Only the content blurs.
    ///
    /// ⚠️ A FEW PICTURES, CORE ANIMATION FOR THE REST. Each state is drawn
    /// once — its ground, its content at a few blur levels — and layers
    /// carry the motion. Baking every sample cost 400–530 ms before the
    /// morph began, read as a lag between the press and the change
    /// (measured, 2026-10-23).
    ///
    /// False when the button cannot be drawn: the caller falls back to the
    /// veil.
    private func blurMorph(old: Content, swap: (() -> Void)?) -> Bool {
        guard let host = superview, window != nil, aspect != .pill(.material) else { return false }
        let generation = morphGeneration
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pad = MorphMetrics.morphBlurRadius * 3
        let radius = MorphMetrics.morphBlurRadius * scale
        let spring = MorphMetrics.morphDuration
        let settle = MorphMetrics.morphSettle
        // ⚠️ A CHANGE MID-FLIGHT STARTS FROM WHAT IS ON SCREEN (the owner,
        // 2026-10-23: a double tap turns the morph around on its way): its
        // rect, its mixed ground, the content on show as blurred as it is;
        // the neighbours' spring retargets from where they are.
        let from: MorphSide
        if let resumed = resumedSide(in: host, scale: scale) {
            endBlurMorph()
            from = resumed
        } else {
            endBlurMorph()
            guard let drawn = drawnSide(in: host, pad: pad, scale: scale) else { return false }
            from = drawn
        }

        // The new state on the model — the button hidden under its stand-in
        // from this turn on — and the neighbours on their spring.
        swap?()
        refresh()
        updateConfiguration()
        invalidateIntrinsicContentSize()
        host.setNeedsLayout()
        let root = layoutRoot ?? host
        UIView.animate(
            springDuration: spring, bounce: MorphMetrics.morphBounce,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            root.layoutIfNeeded()
        }
        layoutIfNeeded()
        guard let to = drawnSide(in: host, pad: pad, scale: scale) else { return false }

        // The content's blur levels: the old one's rising from where it is,
        // the new one's falling. Gaussian blurs add in squares.
        let levels = MorphMetrics.morphBlurLevels
        let fromLevels = (0...levels).map {
            let level = from.blur + (1 - from.blur) * CGFloat($0) / CGFloat(levels)
            return AppButtonBlur.blurred(from.ink, radius: radius * max(0, level * level - from.blur * from.blur).squareRoot())
        }
        let toLevels = (0...levels).map { AppButtonBlur.blurred(to.ink, radius: radius * (1 - CGFloat($0) / CGFloat(levels))) }

        // The samples: the rect on its spring.
        let samples = MorphMetrics.morphSamples
        let times = (0...samples).map { settle * Double($0) / Double(samples) }
        func progress(_ time: TimeInterval) -> CGFloat {
            AppButtonBlur.springProgress(at: time, duration: spring, bounce: MorphMetrics.morphBounce)
        }
        // The swell, as the system's (measured): up to its crest at an eighth
        // of a second, back by a quarter, a touch under, settled by half.
        let change = max(abs(to.rect.width - from.rect.width), abs(to.rect.height - from.rect.height))
        let swellDepth = MorphMetrics.morphSwellBase + (MorphMetrics.morphSwell - MorphMetrics.morphSwellBase) * min(1, change / MorphMetrics.morphSwellReach)
        let swellCurve = MorphMetrics.morphSwellCurve
        func swell(_ time: TimeInterval) -> CGFloat {
            guard let next = swellCurve.firstIndex(where: { $0.time >= time }), next > 0 else { return 1 }
            let (a, b) = (swellCurve[next - 1], swellCurve[next])
            let share = CGFloat((time - a.time) / (b.time - a.time))
            return 1 + swellDepth * (a.share + (b.share - a.share) * share)
        }
        var flight = MorphFlight(host: host, start: host.layer.convertTime(CACurrentMediaTime(), from: nil), from: from, to: to)
        for time in times {
            flight.moments.append(MorphFlight.Moment(
                time: time,
                rect: anchoredRect(progress: progress(time), old: from.rect, new: to.rect),
                mix: AppButtonBlur.smoothstep(CGFloat(time), from: CGFloat(MorphMetrics.morphGroundMix.lowerBound), to: CGFloat(MorphMetrics.morphGroundMix.upperBound)),
                swell: swell(time)
            ))
        }

        // ⚠️ EVERY ANIMATION INSIDE THE TRANSACTION whose completion ends
        // the morph: one added before it does not count, and an empty
        // transaction completes at once — the stand-in went with it, and
        // UIKit's own resize showed instead.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, generation == self.morphGeneration else { return }
            self.endBlurMorph()
        }
        let moments = flight.moments
        let sampleTimes = times.map { NSNumber(value: $0 / settle) }
        func at(_ time: TimeInterval) -> NSNumber { NSNumber(value: min(max(time / settle, 0), 1)) }
        func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any], at keyTimes: [NSNumber]) {
            let animation = AppButtonBlur.keyframes(keyPath, values, duration: settle)
            animation.keyTimes = keyTimes
            layer.add(animation, forKey: "appButton.morph.\(keyPath)")
        }

        // The stand-in: a frame on the ground's rect, cut to its shape,
        // swelling about its middle.
        let frame = UIView()
        frame.isUserInteractionEnabled = false
        frame.layer.masksToBounds = true
        frame.layer.cornerCurve = .continuous
        frame.bounds = CGRect(origin: .zero, size: to.rect.size)
        frame.center = CGPoint(x: to.rect.midX, y: to.rect.midY)
        frame.layer.cornerRadius = cornerRadius(for: to.rect.size)
        animate(frame.layer, "bounds", moments.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.rect.size)) }, at: sampleTimes)
        animate(frame.layer, "position", moments.map { NSValue(cgPoint: CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }, at: sampleTimes)
        animate(frame.layer, "cornerRadius", moments.map { cornerRadius(for: $0.rect.size) }, at: sampleTimes)
        let swelling = AppButtonBlur.keyframes("transform.scale", swellCurve.map { 1 + swellDepth * $0.share } + [1], duration: settle)
        swelling.keyTimes = swellCurve.map { at($0.time) } + [1]
        swelling.calculationMode = .cubic
        frame.layer.add(swelling, forKey: "appButton.morph.swell")
        let centres = moments.map { NSValue(cgPoint: CGPoint(x: $0.rect.width / 2, y: $0.rect.height / 2)) }

        // The grounds, stretched to the frame, the new one fading in.
        for (side, opacity) in [(from, { (m: MorphFlight.Moment) in 1 - m.mix }), (to, { (m: MorphFlight.Moment) in m.mix })] {
            let ground = CALayer()
            ground.contents = side.inside
            ground.contentsGravity = .resize
            ground.frame = frame.bounds
            ground.opacity = Float(opacity(moments[moments.count - 1]))
            frame.layer.addSublayer(ground)
            animate(ground, "bounds", moments.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.rect.size)) }, at: sampleTimes)
            animate(ground, "position", centres, at: sampleTimes)
            animate(ground, "opacity", moments.map { Float(opacity($0)) }, at: sampleTimes)
        }

        // The contents, each where it stands — the old where it was, the new
        // where it lands — the old blurring out, the new blurring in.
        for (side, sideLevels, isNew) in [(from, fromLevels, false), (to, toLevels, true)] {
            let content = CALayer()
            content.contentsScale = scale
            content.contentsGravity = .resize
            content.bounds = CGRect(origin: .zero, size: CGSize(width: side.inkSize.width + pad * 2, height: side.inkSize.height + pad * 2))
            let positions = moments.map { NSValue(cgPoint: CGPoint(x: side.rect.midX - $0.rect.minX, y: side.rect.midY - $0.rect.minY)) }
            content.position = positions[positions.count - 1].cgPointValue
            content.contents = isNew ? sideLevels.last : sideLevels.first
            content.opacity = isNew ? 1 : 0
            frame.layer.addSublayer(content)
            animate(content, "position", positions, at: sampleTimes)
            let steps = sideLevels.count - 1
            let blurs = isNew ? MorphMetrics.morphContentSharpens : 0...MorphMetrics.morphContentOut.upperBound
            let levelTimes = (0...steps).map { at(blurs.lowerBound + (blurs.upperBound - blurs.lowerBound) * Double($0) / Double(steps)) }
            animate(content, "contents", [sideLevels[0]] + sideLevels + [sideLevels[steps]], at: [0] + levelTimes + [1])
            let fade = isNew ? MorphMetrics.morphContentIn : MorphMetrics.morphContentOut
            let (start, end): (Float, Float) = isNew ? (0, 1) : (1, 0)
            let opacity = AppButtonBlur.keyframes("opacity", [start, start, end, end], duration: settle)
            opacity.keyTimes = [0, at(fade.lowerBound), at(fade.upperBound), 1]
            content.add(opacity, forKey: "appButton.morph.fade")
        }

        // Handed over in two steps, not a cut: a stand-in resampled to its
        // frame never matches the button to the pixel, and a cut read as the
        // words twitching as the morph ended (the owner, 2026-10-23). The
        // button fades in under the stand-in first, then the stand-in fades
        // out over it: two half-faded layers at once read as a paler flash.
        func handoff(from: Float, to: Float, between start: TimeInterval, and end: TimeInterval) -> CAKeyframeAnimation {
            let fade = AppButtonBlur.keyframes("opacity", [from, from, to, to], duration: settle)
            fade.keyTimes = [0, at(start), at(end), 1]
            return fade
        }
        let handoffStart = settle - MorphMetrics.morphHandoff
        let handoffMiddle = settle - MorphMetrics.morphHandoff / 2
        frame.layer.add(handoff(from: 1, to: 0, between: handoffMiddle, and: settle), forKey: "appButton.morph.handoff")
        frame.layer.opacity = 0
        // ⚠️ HIDDEN BY A MASK, NOT AN ALPHA: UIKit skips a view under 0.01
        // alpha in hit-testing, and the second tap of a double tap fell
        // through the button (the owner, 2026-10-23).
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor
        mask.frame = bounds.insetBy(dx: -pad, dy: -pad)
        mask.add(handoff(from: 0, to: 1, between: handoffStart, and: handoffMiddle), forKey: "appButton.morph.handoff")
        layer.mask = mask
        // The press goes on over the stand-in: its swell now, its spring
        // back when the finger lifts.
        PressFeedback.copyPress(from: layer, to: frame.layer)
        pressFeedback?.mirrors = [frame.layer]
        host.insertSubview(frame, aboveSubview: self)
        blurOverlays = [frame]
        self.flight = flight
        CATransaction.commit()
        return true
    }

    /// A load, drawn: the content blurs as a morph's first beat does, then
    /// holds at its most blurred under a sheen sweeping the capsule — a
    /// skeleton of the button as it stood — until the load ends. False when
    /// the button cannot be drawn.
    private func holdLoad() -> Bool {
        guard let host = superview, window != nil, aspect != .pill(.material) else { return false }
        endBlurMorph()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pad = MorphMetrics.morphBlurRadius * 3
        let radius = MorphMetrics.morphBlurRadius * scale
        guard let side = drawnSide(in: host, pad: pad, scale: scale) else { return false }
        let levels = MorphMetrics.morphBlurLevels
        let images = (0...levels).map { AppButtonBlur.blurred(side.ink, radius: radius * CGFloat($0) / CGFloat(levels)) }
        let blurIn = MorphMetrics.morphContentOut.upperBound

        CATransaction.begin()
        let frame = UIView()
        frame.isUserInteractionEnabled = false
        frame.layer.masksToBounds = true
        frame.layer.cornerCurve = .continuous
        frame.bounds = CGRect(origin: .zero, size: side.rect.size)
        frame.center = CGPoint(x: side.rect.midX, y: side.rect.midY)
        frame.layer.cornerRadius = cornerRadius(for: side.rect.size)
        let ground = CALayer()
        ground.contents = side.inside
        ground.contentsGravity = .resize
        ground.frame = frame.bounds
        frame.layer.addSublayer(ground)
        let content = CALayer()
        content.contentsScale = scale
        content.contentsGravity = .resize
        content.bounds = CGRect(origin: .zero, size: CGSize(width: side.inkSize.width + pad * 2, height: side.inkSize.height + pad * 2))
        content.position = CGPoint(x: frame.bounds.midX, y: frame.bounds.midY)
        content.contents = images.last
        frame.layer.addSublayer(content)
        let blurring = AppButtonBlur.keyframes("contents", images, duration: blurIn)
        blurring.keyTimes = (0...levels).map { NSNumber(value: Double($0) / Double(levels)) }
        content.add(blurring, forKey: "appButton.load.blur")
        // The sheen: a light band crossing the capsule, over and over.
        let sheen = CAGradientLayer()
        sheen.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.45).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        let band = max(frame.bounds.height * 2, frame.bounds.width * 0.5)
        sheen.bounds = CGRect(x: 0, y: 0, width: band, height: frame.bounds.height)
        sheen.position = CGPoint(x: -band, y: frame.bounds.midY)
        frame.layer.addSublayer(sheen)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -band / 2
        sweep.toValue = frame.bounds.width + band / 2
        sweep.duration = MorphMetrics.loadingSheen
        sweep.beginTime = sheen.convertTime(CACurrentMediaTime(), from: nil) + blurIn
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sheen.add(sweep, forKey: "appButton.load.sheen")
        // Hidden by a mask, not an alpha (see `blurMorph`).
        layer.mask = CALayer()
        host.insertSubview(frame, aboveSubview: self)
        blurOverlays = [frame]
        heldLoad = MorphSide(rect: side.rect, inside: side.inside, ink: images[levels], inkSize: side.inkSize, blur: 1)
        CATransaction.commit()
        return true
    }

    /// One end of a morph: where the ground stands in the host, the inside
    /// of the ground to stretch, and the content as drawn — its own size,
    /// how blurred it already is.
    private struct MorphSide {
        var rect: CGRect
        /// The ground's inside, clear of its corners: stretched to any size.
        var inside: CGImage
        /// The content alone, at the weight the button draws it, on a
        /// margin for the blur.
        var ink: CGImage
        var inkSize: CGSize
        var blur: CGFloat = 0
    }

    /// The morph on show: when it started, in its host's time, its two ends,
    /// and where it stands at each sample — so a change landing mid-flight
    /// starts from what is on screen.
    private struct MorphFlight {
        struct Moment {
            var time: TimeInterval
            /// The ground's frame, in the host, before the swell.
            var rect: CGRect
            /// The new ground's share.
            var mix: CGFloat
            var swell: CGFloat
        }
        var host: UIView
        var start: CFTimeInterval
        var from: MorphSide
        var to: MorphSide
        var moments: [Moment] = []
    }

    /// The button as it stands now, drawn.
    ///
    /// ⚠️ THE CONTENT IS DRAWN ON ITS GROUND, then taken back off it: words
    /// drawn on a clear canvas come out thinner than on the button (font
    /// smoothing needs an opaque backdrop) and read as lighter words that
    /// twitched to their weight as the morph ended (the owner, 2026-10-23).
    private func drawnSide(in host: UIView, pad: CGFloat, scale: CGFloat) -> MorphSide? {
        let rect = groundRect
        guard let ground = drawnGround(pad: pad, scale: scale),
              let whole = AppButtonBlur.snapshot(of: self, rect: rect, pad: pad, scale: scale),
              let groundInside = AppButtonBlur.inside(of: ground, pad: pad, cap: cornerRadius(for: rect.size), scale: scale),
              let content = AppButtonBlur.ink(of: whole, over: ground, foreground: drawnForeground)
        else { return nil }
        return MorphSide(rect: convert(rect, to: host), inside: groundInside, ink: content, inkSize: rect.size)
    }

    /// The words' colour now, for `AppButtonBlur.ink`.
    private var drawnForeground: UIColor {
        (configuration?.baseForegroundColor ?? tintColor).resolvedColor(with: traitCollection)
    }

    /// The moment on show, as the start of the next morph, when one is in
    /// flight in `host`: the content most on show then, as blurred as it is.
    private func resumedSide(in host: UIView, scale: CGFloat) -> MorphSide? {
        if let heldLoad, !blurOverlays.isEmpty { return heldLoad }
        guard let flight, flight.host === host, !blurOverlays.isEmpty else { return nil }
        let elapsed = host.layer.convertTime(CACurrentMediaTime(), from: nil) - flight.start
        guard let moment = flight.moments.last(where: { $0.time <= elapsed }) ?? flight.moments.first,
              let inside = AppButtonBlur.mixed(flight.from.inside, flight.to.inside, mix: moment.mix)
        else { return nil }
        func share(_ time: TimeInterval, _ range: ClosedRange<TimeInterval>) -> CGFloat {
            CGFloat(min(max((time - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1))
        }
        let showsNew = share(elapsed, MorphMetrics.morphContentIn) >= 1 - share(elapsed, MorphMetrics.morphContentOut)
        let side = showsNew ? flight.to : flight.from
        let level = showsNew
            ? 1 - share(elapsed, MorphMetrics.morphContentSharpens)
            : side.blur + (1 - side.blur) * share(elapsed, 0...MorphMetrics.morphContentOut.upperBound)
        let added = showsNew ? level : max(0, level * level - side.blur * side.blur).squareRoot()
        let shown = AppButtonBlur.blurred(side.ink, radius: MorphMetrics.morphBlurRadius * scale * added)
        return MorphSide(rect: moment.rect, inside: inside, ink: shown, inkSize: side.inkSize, blur: level)
    }

    /// The button's ground alone, its content hidden.
    private func drawnGround(pad: CGFloat, scale: CGFloat) -> CGImage? {
        let content: [UIView] = [titleLabel, imageView].compactMap { $0 }
            .filter { $0.isDescendant(of: self) }
        let was = content.map(\.isHidden)
        content.forEach { $0.isHidden = true }
        defer { zip(content, was).forEach { $0.isHidden = $1 } }
        return AppButtonBlur.snapshot(of: self, rect: groundRect, pad: pad, scale: scale)
    }

    /// The ground at `progress` between `old` and `new`: its anchored edge
    /// where the layout moves it — still, for a row's trailing button or a
    /// reserved slot — the size all on the other side.
    private func anchoredRect(progress: CGFloat, old: CGRect, new: CGRect) -> CGRect {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        let size = CGSize(width: lerp(old.width, new.width), height: lerp(old.height, new.height))
        let x: CGFloat = switch horizontalAnchor {
        case .left: lerp(old.minX, new.minX)
        case .right: lerp(old.maxX, new.maxX) - size.width
        case .middle: lerp(old.midX, new.midX) - size.width / 2
        }
        let y: CGFloat = switch morphAnchor {
        case .top: lerp(old.minY, new.minY)
        case .bottom: lerp(old.maxY, new.maxY) - size.height
        case .leading, .center, .trailing: lerp(old.midY, new.midY) - size.height / 2
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private enum HorizontalAnchor { case left, middle, right }

    /// `morphAnchor` on screen: leading is the right in a right-to-left
    /// layout.
    private var horizontalAnchor: HorizontalAnchor {
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        switch (morphAnchor, rightToLeft) {
        case (.leading, false), (.trailing, true): return .left
        case (.trailing, false), (.leading, true): return .right
        case (.center, _), (.top, _), (.bottom, _): return .middle
        }
    }

    /// The button back in its own pixels, its stand-in gone.
    private func endBlurMorph() {
        guard !blurOverlays.isEmpty else { return }
        for overlay in blurOverlays {
            overlay.layer.removeAllAnimations()
            overlay.removeFromSuperview()
        }
        blurOverlays = []
        flight = nil
        heldLoad = nil
        pressFeedback?.mirrors = []
        layer.mask = nil
    }

    /// The width follows the content, the neighbours with it — a spring, or
    /// at once under Reduce Motion (the cross-fade covers it).
    private func resize(reduced: Bool) {
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        let host = layoutRoot ?? self
        guard !reduced else {
            host.layoutIfNeeded()
            return
        }
        UIView.animate(
            springDuration: Metrics.resizeDuration, bounce: Metrics.resizeBounce,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            host.layoutIfNeeded()
        }
    }

    // MARK: - Selected

    /// Selected (Following, liked, pinned): the ground and ink cross-fade.
    /// A fade, so it stays under Reduce Motion.
    public func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        guard animated, window != nil, heldLoad == nil else {
            isSelected = selected
            return
        }
        record(.stateTint)
        UIView.transition(with: self, duration: Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.isSelected = selected
            self.updateConfiguration()
            self.layoutIfNeeded()
        }
        resize(reduced: reducesMotion())
    }

    // MARK: - Phase

    /// Placeholder, loading or content. The width never jumps: a placeholder
    /// holds its reserved width, a load holds the width it started at.
    public func setPhase(_ phase: Phase, animated: Bool) {
        guard phase != self.phase else { return }
        let old = self.phase
        if phase == .loading {
            // ⚠️ MEASURED, NOT READ FROM `intrinsicContentSize`, when the
            // button has not been laid out yet: its configuration resolves at
            // the next update pass, and a load started before that held a
            // width too narrow for its own words ("S…").
            heldSize = bounds.width > 0 ? bounds.size : fittingSize(for: content)
        } else {
            heldSize = nil
        }
        self.phase = phase
        let animates = animated && window != nil
        // ⚠️ NO SPINNER (the owner, 2026-10-23): a load holds the button as
        // it stands the instant before its content changes — the content
        // blurred, a sheen going over it — and when it ends, the morph goes
        // on from there to whatever the answer brought.
        if phase == .loading, animates, !reducesMotion(), holdLoad() {
            refresh()
            announceBusy()
            return
        }
        if old == .loading, heldLoad != nil {
            // Into the answer, the morph; into a placeholder, the bone.
            if phase == .content, animates {
                invalidateIntrinsicContentSize()
                morphGeneration += 1
                record(.blurMorph)
                if blurMorph(old: content, swap: nil) { return }
            }
            endBlurMorph()
        }
        if phase == .placeholder {
            installBone()
        } else if old == .placeholder {
            removeBone(animated: animates)
        }
        refresh()
        if phase == .loading { announceBusy() }
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        if animates { resize(reduced: reducesMotion()) }
    }

    private func installBone() {
        guard bone == nil else { return }
        let bone = SkeletonBoneView(rounding: shape == .capsule ? .capsule : .fixed(Metrics.cardRadius))
        bone.frame = bounds
        addSubview(bone)
        self.bone = bone
    }

    private func removeBone(animated: Bool) {
        guard let bone else { return }
        self.bone = nil
        guard animated else {
            bone.removeFromSuperview()
            return
        }
        // Placeholder → content is a fade on every setting.
        record(.placeholderReveal)
        bone.fadeOutSkeleton(removing: true)
    }

    // MARK: - Taps

    /// ⚠️ **A BUTTON THAT IS NOT SHOWING ITS CONTENT TAKES NO TAP**: a
    /// placeholder claims no answer, and a load in flight ignores re-taps
    /// (`AppControl` refuses the touch).
    override open var acceptsTapsWhenEnabled: Bool { phase == .content }

    override open var showsGround: Bool { phase != .placeholder }

    // MARK: - Motion

    /// The placeholder's bone keeps its shimmer through an appear.
    override open func keepsAnimations(of view: UIView) -> Bool { view === bone }

    /// An action that came back fine: optionally the symbol changes (a
    /// checkmark), and the success notification plays if asked.
    public func succeed(showing symbol: String? = nil) {
        if notifiesCompletion { notify(.success) }
        guard let symbol else { return }
        var next = content
        next.symbol = symbol
        setContent(next, animated: true)
    }

    // MARK: - Accessibility

    private func announceBusy() {
        guard UIAccessibility.isVoiceOverRunning, accessibilityElementIsFocused() else { return }
        UIAccessibility.post(notification: .announcement, argument: busyText)
    }

    private var busyText: String { busyLabel ?? "In progress" }

    /// The label a caller gave ("Follow Ava"), which a refresh never
    /// overwrites; without one, the title, then UIKit's own.
    private var explicitAccessibilityLabel: String?

    override open var accessibilityLabel: String? {
        get {
            // A placeholder has no answer to name.
            guard phase != .placeholder else { return nil }
            return explicitAccessibilityLabel ?? content.title ?? super.accessibilityLabel
        }
        set { explicitAccessibilityLabel = newValue }
    }

    override open func refreshAccessibility() {
        super.refreshAccessibility()
        // A placeholder claims no answer — not even to VoiceOver (#933).
        isAccessibilityElement = phase != .placeholder
        if phase == .placeholder { accessibilityTraits.insert(.notEnabled) }
        switch phase {
        case .content: accessibilityValue = content.count.map(String.init)
        case .loading: accessibilityValue = busyText
        case .placeholder: accessibilityValue = nil
        }
        largeContentTitle = content.text ?? accessibilityLabel
        largeContentImage = content.symbol.flatMap { UIImage.symbol(named: $0) }
    }

    // MARK: - Configuration

    override open func refresh() {
        var config = configuration(for: content, phase: phase)
        let margins = slotMargins
        drawnSlotMargins = margins
        if margins != .zero {
            // The content centred on the ground, the system's own fill on it.
            config.contentInsets.top += margins.top
            config.contentInsets.leading += margins.leading
            config.contentInsets.bottom += margins.bottom
            config.contentInsets.trailing += margins.trailing
            config.background.backgroundInsets = margins
        }
        configuration = config
        refreshGrounds()
        refreshAccessibility()
    }

    /// The ground drawn now: the selected one when selected.
    override open var currentGround: Ground? {
        guard case .pill(let ground) = aspect else { return nil }
        guard isSelected else { return ground }
        if let selectedGround { return selectedGround }
        switch ground {
        case .prominent: return .quiet
        case .quiet: return .prominent
        case .tinted, .material: return ground
        }
    }

    /// The configuration for `content` in `phase`, at the button's aspect,
    /// size, shape and state.
    func configuration(for content: Content, phase: Phase) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch currentGround {
        case .prominent?:
            config = .filled()
            // The prominent view is the ground (#1178); the configuration's
            // fill stays clear over it.
            config.baseBackgroundColor = .clear
            config.baseForegroundColor = .white
        case .quiet?:
            config = .filled()
            config.baseBackgroundColor = HeroTray.fill
            config.baseForegroundColor = .label
        case .tinted?: config = .tinted()
        case .material?:
            config = .plain()
            config.baseForegroundColor = .label
            config.background.backgroundColor = .clear
        case nil:
            config = .plain()
            config.baseForegroundColor = .label
        }
        if let inkColor { config.baseForegroundColor = inkColor }

        switch shape {
        case .capsule:
            config.cornerStyle = .capsule
        case .card:
            config.cornerStyle = .fixed
            config.background.cornerRadius = Metrics.cardRadius
        }

        let font = Self.font(for: size)
        config.contentInsets = Self.insets(for: size)
        config.imagePadding = 6
        config.imagePlacement = content.imagePlacement
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font, scale: .small)
        config.image = content.symbol.flatMap { UIImage.symbol(named: $0) }
        config.titleLineBreakMode = .byTruncatingTail
        if let text = content.text {
            config.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: font]))
        }
        if size == .row { config.buttonSize = .small }

        if !isEnabled {
            // Greyed ground and ink, whatever the aspect.
            config.baseForegroundColor = .tertiaryLabel
            if currentGround != nil {
                config.background.backgroundColor = .tertiarySystemFill
            }
        }

        switch phase {
        case .content:
            break
        case .placeholder:
            // The bone is the whole picture: nothing claims an answer.
            config.baseForegroundColor = .clear
            config.background.backgroundColor = .clear
            config.image = nil
            config.attributedTitle = content.text.map {
                AttributedString($0, attributes: AttributeContainer([.font: font, .foregroundColor: UIColor.clear]))
            }
        case .loading:
            // No spinner: drawn, the load is the content blurred under a
            // sheen (`holdLoad`); undrawn — Reduce Motion, off screen — the
            // content stays, faded.
            config.baseForegroundColor = (config.baseForegroundColor ?? .label).withAlphaComponent(MorphMetrics.loadingInkAlpha)
        }
        return config
    }

    static func font(for size: Size) -> UIFont {
        switch size {
        case .row:
            UIFont.appFont(forTextStyle: .subheadline)
        case .header:
            // Capped (#482), as the tray's capsule.
            UIFont.scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 19)
        }
    }

    static func insets(for size: Size) -> NSDirectionalEdgeInsets {
        switch size {
        case .row: NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
        case .header: NSDirectionalEdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
        }
    }

    // MARK: - Cell accessory

    /// The button as a list cell's accessory, in a host sized now.
    ///
    /// ⚠️ **NEVER THE BARE BUTTON AS `customView`**: its configuration
    /// resolves at the next update pass, the accessory reserves a zero-wide
    /// slot, the button still DRAWS in place and every tap falls through to
    /// the cell (memory: cell-accessory hit-testing; the shop's hand-made
    /// host). The host measures with `fittingSize` and is frame-based, as
    /// UIKit asks of a custom accessory view — so its width is the content's
    /// when it was built: a cell whose button changes width (Follow →
    /// Following) asks for the accessory again in its configuration pass.
    public func cellAccessory(placement: UICellAccessory.Placement = .trailing()) -> UICellAccessory {
        let host = AccessoryHost(button: self)
        return .customView(configuration: .init(
            customView: host, placement: placement, reservedLayoutWidth: .custom(host.bounds.width)
        ))
    }

    /// The frame-based host `cellAccessory` puts the button in.
    final class AccessoryHost: UIView {
        let button: AppButton

        init(button: AppButton) {
            self.button = button
            let fitted = button.fittingSize(for: button.content)
            super.init(frame: CGRect(origin: .zero, size: fitted))
            button.frame = bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var intrinsicContentSize: CGSize { bounds.size }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            button.point(inside: convert(point, to: button), with: event)
        }
    }

    // MARK: - Tests

    #if DEBUG
    public var debugHeldSize: CGSize? { heldSize }
    public var debugHasBone: Bool { bone != nil }

    /// Whether the content change is covering the button — the veil, or
    /// the blurred stand-in.
    public var debugVeilIsShown: Bool { !veil.isHidden || !blurOverlays.isEmpty }
    /// Whether the button's own pixels are hidden under its stand-ins.
    public var debugIsUnderStandIn: Bool { layer.mask != nil }
    #endif
}
