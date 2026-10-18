import ObjectiveC
import UIKit

/// The app's one button (#931): a `UIButton` driven by its configuration, with
/// what UIKit does not do added on top — a press that scales, a placeholder
/// while the answer is unknown, a held width while an action is in flight, the
/// content-change and count motions, and the haptic and sound options.
///
/// ```
///   pill (a visible ground)                bare (content only)
///   ╭──────────────╮  prominent · quiet    ♡ 1.2K   ▢ save   ↻
///   │  ✓ Following │  tinted · material
///   ╰──────────────╯                       Button Shapes on → a quiet capsule
/// ```
///
/// ⚠️ **IT RENDERS A STATE; IT OWNS NO BUSINESS LOGIC.** Optimistic updates,
/// rollback and "one mutation in flight" stay in the view models. A caller
/// says what the button shows (`setContent`, `setSelected`, `setPhase`) and
/// reacts to its action; the button never decides what a tap means.
///
/// ⚠️ **NEVER GLASS.** No `.glass()` / `.prominentGlass()` / `UIGlassEffect`
/// here: the buttons that wear glass today keep their own implementation
/// (decided 2026-10-11). Over a photograph the pill wears a blur MATERIAL, for
/// the reasons `PostMetaPillView` gives. `AppButtonTests` scans this file.
///
/// ⚠️ **ONE PRESS (#866).** `PressFeedback` is attached once, at init, and is
/// the only thing that scales the button under a finger; UIKit's configuration
/// only resolves a highlight, which is the dim. Its symbol animation stays OFF
/// (#1376): on, UIKit shrinks the icon alone on every highlight. The sound option is decided at
/// init for the same reason: re-attaching would stack a second press.
///
/// ⚠️ **EVERY MOTION ASKS `reducesMotion`** (by default `MotionPreference`:
/// the iPhone's Reduce Motion, the app's switch and Power Saving), never
/// `UIAccessibility` directly, and each one has its fallback: the press
/// becomes the highlight, the bounce-in a fade, the blur and the resize a
/// cross-fade, the symbol bounce and the shake a colour flash. Nothing loops
/// at rest (#580): the placeholder's sweep is `SkeletonBoneView`'s, which
/// stills itself.
@MainActor
open class AppButton: UIButton {
    // MARK: - Look

    /// What a pill stands on.
    public enum Ground: Equatable, Sendable {
        /// The one action that matters (Follow): a pink-to-white gradient
        /// (`Palette.primaryGradient`), white words (#1178, the owner
        /// 2026-10-15) — the same in both appearances.
        case prominent
        /// The profile tray's quiet fill (`HeroTray.fill`): Message, Following.
        case quiet
        /// The tint, washed: a price.
        case tinted
        /// A blur material, for a button over a photograph. Never glass.
        case material
    }

    public enum Aspect: Equatable, Sendable {
        /// Content on a visible ground.
        case pill(Ground)
        /// Content only. A press shows a transient wash; Button Shapes gives
        /// it a visible ground.
        case bare
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
        /// A 44pt circle holding one symbol (`HeroTray.bubbleSize`).
        case icon
        /// A card's action: a symbol and its count.
        case inline
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
        /// An action is in flight: a spinner, the width held, re-taps ignored,
        /// still focusable for VoiceOver with a busy label.
        case loading
    }

    /// The haptic a tap plays, through the `Haptics` wrappers.
    public enum Haptic: Equatable, Sendable {
        case none
        /// A toggle.
        case selection
        case lightImpact
        case mediumImpact
    }

    public enum Metrics {
        /// The smallest region a finger can hit, whatever is drawn (HIG).
        public static let minimumHitSide: CGFloat = 44
        /// A card's corner radius.
        public static let cardRadius: CGFloat = 12
        /// The bounce-in's starting scale — the app's one appear motion
        /// (`AppearMotion`, #1151).
        public static let appearScale: CGFloat = AppearMotion.appearScale
        public static let appearDuration: TimeInterval = AppearMotion.appearDuration
        public static let disappearDuration: TimeInterval = AppearMotion.disappearDuration
        /// The content change: blur out, swap, unblur in (the 0.36 s the
        /// profile's Follow morphed in before it became this button).
        public static let morphDuration: TimeInterval = 0.36
        /// A fade: the state tint, the Reduce Motion fallbacks.
        public static let fadeDuration: TimeInterval = 0.22
        /// The fluid resize's spring.
        public static let resizeDuration: TimeInterval = 0.45
        public static let resizeBounce: CGFloat = 0.18
        /// The failure shake: how far, how long.
        public static let shakeAmplitude: CGFloat = 8
        public static let shakeDuration: TimeInterval = 0.4
        /// A long press that holds the screen (the card actions' hold).
        /// Shorter than a context menu's own timing, so the held state is
        /// visible before a menu lifts.
        public static let holdDuration: TimeInterval = 0.25
        /// The `.label` wash a card action shows under a finger, then held
        /// (`washesOnPress`). Measured on a card's fill (227 in light mode):
        /// 0.08 lands at ~209, 0.16 at ~191 — two steps an eye tells apart
        /// without either reading as a new colour.
        public static let pressedWash: CGFloat = 0.08
        public static let heldWash: CGFloat = 0.16
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
    /// A bare button's SYMBOL ink while selected (a liked heart's red). The
    /// words and the count keep the ink: the heart says "yours", the number
    /// stays the post's (#934, as the card's like always drew it). Nil keeps
    /// the ink.
    public var selectedTint: UIColor? { didSet { refresh() } }
    /// The ink at rest. Nil: the ground's own.
    public var inkColor: UIColor? { didSet { refresh() } }
    /// Selected, the symbol is the POINTS HEART (#1128): the heart in the
    /// points gradient (`PointsHeartView`) drawn over the button's own glyph,
    /// which goes clear — the button still lays it out, so nothing moves. At
    /// rest the glyph is the button's own, in its ink. Off by default.
    public var drawsPointsHeart = false { didSet { refresh() } }
    /// The gradient heart, while it is shown.
    public private(set) var pointsHeart: PointsHeartView?

    /// Played on a tap. Off by default.
    public var haptic: Haptic = .none
    /// `succeed` / `fail` play the success or error notification. Off by
    /// default.
    public var notifiesCompletion = false
    /// A tap also bounces the symbol (a like). Off by default.
    public var bouncesSymbolOnTap = false
    /// Whether the button is a toggle (Follow, like, pin): VoiceOver says so.
    public var isToggle = false { didSet { refreshAccessibility() } }

    /// The placeholder's width, when the caller knows it.
    public var reservedWidth: CGFloat? { didSet { invalidateIntrinsicContentSize() } }
    /// Or the contents the answer may bring: the placeholder holds the
    /// widest, so the answer never moves its neighbours.
    public var reservedContents: [Content] = [] { didSet { invalidateIntrinsicContentSize() } }
    /// What VoiceOver hears while an action is in flight ("Following…").
    /// Nil: "In progress".
    public var busyLabel: String? { didSet { refreshAccessibility() } }

    /// A long press holds the screen: the scroller under the button stops
    /// for as long as the finger stays, and a lift inside still taps.
    public var holdFreezesScrolling = false { didSet { syncHold() } }

    /// ⚠️ **A CARD ACTION'S PRESS (#934): THE CONTRAST STEP, NOT A FADE.** A
    /// bare button's press is a dim, which on a card's action reads as
    /// "disabled" as much as "pressed". With this on, a `.label` wash rises
    /// inside the button's shape instead — one step on the press, a second
    /// while held (`holdFreezesScrolling`) — darker in light mode, lighter in
    /// dark, the way the system's highlighted cells go. The ground appears
    /// only while a finger is on it. Build such a button with `dims: false`.
    public var washesOnPress = false { didSet { applyWash() } }

    /// A menu raised by holding the button (the like's stake menu), built
    /// when it lifts so it reads current state; nil for none. The button
    /// lifts as itself — its capsule, not a rectangle.
    public var menuProvider: (() -> UIMenu?)? {
        didSet { isContextMenuInteractionEnabled = menuProvider != nil }
    }

    /// Draws the symbol at this point size, medium weight, instead of the
    /// size's text-matched one — a card's actions stand level with its lone
    /// glyphs (`PostActionPillView.glyphPointSize`). Nil: the size's own.
    public var symbolPointSize: CGFloat? { didSet { refresh() } }

    /// Whether a finger has held the button past `Metrics.holdDuration`.
    public private(set) var isHolding = false
    private var isHeldInside = false
    private let wash = UIView()
    private lazy var holdDelegate = HoldDelegate(button: self)

    /// Whether motion is reduced — `MotionPreference` unless a test says.
    public var reducesMotion: @MainActor () -> Bool = { MotionPreference.reducesMotion }
    /// Whether the iPhone's Button Shapes setting is on — UIKit's unless a
    /// test says.
    public var buttonShapes: @MainActor () -> Bool = { UIAccessibility.buttonShapesEnabled } {
        didSet { refresh() }
    }

    /// The single press feedback (#866), attached at init.
    public private(set) var pressFeedback: PressFeedback?

    private let veil = UIVisualEffectView(effect: nil)
    private let materialGround = UIVisualEffectView(effect: nil)
    /// The prominent ground's gradient (#1178), under the content.
    private let gradientGround = BrandGradientView(colors: Palette.primaryGradient)
    private let flash = UIView()
    private var bone: SkeletonBoneView?
    /// The size an in-flight action holds: the spinner is taller than a
    /// line of words, and narrower than most.
    private var heldSize: CGSize?
    private var hold: UILongPressGestureRecognizer?
    private var morphGeneration = 0
    private var impact: HapticImpact?
    private var selection: HapticSelection?
    private var notification: HapticNotification?

    // MARK: - Init

    /// - Parameters:
    ///   - sound: the tick a tap plays (`UISound.tap`, gated by Interface
    ///     Sounds). Nil by default. Decided here, once: see the type's note.
    ///   - dims: the press also fades the button a little (the app-wide
    ///     press). Bare buttons default to it, as they have no ground to
    ///     highlight.
    public init(
        aspect: Aspect, size: Size, shape: Shape = .capsule, content: Content,
        sound: UISound? = nil, dims: Bool? = nil
    ) {
        self.aspect = aspect
        self.size = size
        self.shape = shape
        self.content = content
        super.init(frame: .zero)
        // ⚠️ OFF (#1376). On, UIKit shrinks the symbol to about half on every
        // highlight — a second press on the icon alone, the title left at
        // `PressFeedback`'s scale. The symbol replace it brought comes from
        // the configuration's `symbolContentTransition` instead.
        isSymbolAnimationEnabled = false
        setUp()
        pressFeedback = PressFeedback.attach(
            to: self, sound: sound, dims: dims ?? (aspect == .bare),
            reducesMotion: { [weak self] in self?.reducesMotion() ?? MotionPreference.reducesMotion }
        )
        // The wash follows the SAME finger decisions as the press.
        pressFeedback?.onPressChanged = { [weak self] _ in self?.applyWash() }
        refresh()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUp() {
        wash.backgroundColor = .label
        wash.alpha = 0
        wash.isUserInteractionEnabled = false
        insertSubview(wash, at: 0)

        materialGround.isUserInteractionEnabled = false
        materialGround.clipsToBounds = true
        insertSubview(materialGround, at: 0)

        gradientGround.clipsToBounds = true
        gradientGround.alpha = 0
        insertSubview(gradientGround, aboveSubview: materialGround)

        veil.isUserInteractionEnabled = false
        veil.clipsToBounds = true
        veil.isHidden = true
        addSubview(veil)

        flash.isUserInteractionEnabled = false
        flash.alpha = 0
        flash.backgroundColor = .systemRed
        addSubview(flash)

        addAction(UIAction { [weak self] _ in self?.prepareHaptic() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)

        if size == .icon || size == .inline {
            // Fixed-size and icon-only buttons do not grow with the text size:
            // a long press shows them large.
            showsLargeContentViewer = true
            scalesLargeContentImage = true
            addInteraction(UILargeContentViewerInteraction())
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilitySettingChanged),
            name: UIAccessibility.buttonShapesEnabledStatusDidChangeNotification, object: nil
        )
    }

    @objc private func accessibilitySettingChanged() { refresh() }

    // MARK: - Layout

    override open func layoutSubviews() {
        super.layoutSubviews()
        let radius = cornerRadius
        materialGround.frame = bounds
        materialGround.layer.cornerRadius = radius
        materialGround.layer.cornerCurve = .continuous
        sendSubviewToBack(materialGround)
        gradientGround.frame = bounds
        gradientGround.layer.cornerRadius = radius
        gradientGround.layer.cornerCurve = .continuous
        insertSubview(gradientGround, aboveSubview: materialGround)
        wash.frame = bounds
        wash.layer.cornerRadius = radius
        wash.layer.cornerCurve = .continuous
        insertSubview(wash, aboveSubview: gradientGround)
        veil.frame = bounds
        veil.layer.cornerRadius = radius
        flash.frame = bounds
        flash.layer.cornerRadius = radius
        bone?.frame = bounds
        if let pointsHeart, let imageView {
            pointsHeart.frame = imageView.convert(imageView.bounds, to: self)
            bringSubviewToFront(pointsHeart)
        }
        bringSubviewToFront(flash)
        bringSubviewToFront(veil)
        if let bone { bringSubviewToFront(bone) }
    }

    private var cornerRadius: CGFloat {
        switch shape {
        case .capsule: bounds.height / 2
        case .card: Metrics.cardRadius
        }
    }

    override open var intrinsicContentSize: CGSize {
        if size == .icon {
            return CGSize(width: HeroTray.bubbleSize, height: HeroTray.bubbleSize)
        }
        if let heldSize { return heldSize }
        var measured = super.intrinsicContentSize
        if phase == .placeholder, let reserved = placeholderWidth {
            measured.width = reserved
        }
        return measured
    }

    /// The width a placeholder holds: the one given, else the widest of the
    /// contents the answer may bring.
    public var placeholderWidth: CGFloat? {
        if let reservedWidth { return reservedWidth }
        guard !reservedContents.isEmpty else { return nil }
        return reservedContents.map { fittingSize(for: $0).width }.max()
    }

    /// The size the button takes for `content`, resolved now — not at the
    /// next update pass (a configuration resolves late: the cell-accessory
    /// trap, see `cellAccessory`).
    public func fittingSize(for content: Content) -> CGSize {
        let scratch = UIButton(configuration: configuration(for: content, phase: .content))
        scratch.updateConfiguration()
        let fitted = scratch.sizeThatFits(UIView.layoutFittingCompressedSize)
        if size == .icon { return CGSize(width: HeroTray.bubbleSize, height: HeroTray.bubbleSize) }
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    /// A finger lands anywhere within 44×44 around the button, however small
    /// it is drawn.
    override open func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitRegion.contains(point)
    }

    /// ⚠️ **A TOUCH INSIDE STAYS THE BUTTON'S, EVEN WHILE IT TAKES NO TAP.**
    /// UIKit skips a disabled control in hit-testing, and the finger lands on
    /// whatever is under it: a greyed price SELECTED ITS ROW, which closed the
    /// shop and flew the map to the country (filmed on the simulator, #935;
    /// a no-op recogniser on the button did not stop it, as the touch never
    /// reached it). Returned here, the touch meets `touchesBegan`, which
    /// swallows it as it does for a placeholder or a load.
    override open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let view = super.hitTest(point, with: event) { return view }
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        return self
    }

    /// The region a touch counts in: the bounds, grown to at least 44×44.
    public var hitRegion: CGRect {
        let dx = max(0, (Metrics.minimumHitSide - bounds.width) / 2)
        let dy = max(0, (Metrics.minimumHitSide - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy)
    }

    // MARK: - Content

    /// Shows `content`. Animated, it picks the motion the change asks for: a
    /// count rolls, a symbol alone is replaced, anything else blurs out and
    /// in; the width follows in the same beat.
    public func setContent(_ content: Content, animated: Bool) {
        guard content != self.content else { return }
        let old = self.content
        self.content = content
        guard animated, window != nil, phase == .content else {
            land()
            return
        }
        let reduced = reducesMotion()
        if old.title == content.title, old.symbol == content.symbol, old.count != content.count {
            rollCount(from: old.count ?? 0, to: content.count ?? 0, reduced: reduced)
        } else if old.title == content.title, old.count == content.count, old.symbol != content.symbol,
                  content.symbol != nil, old.symbol != nil {
            replaceSymbol(reduced: reduced)
        } else {
            morph(reduced: reduced)
        }
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
        self.content = content
        guard animated, window != nil, phase == .content else {
            isSelected = selected
            land()
            return
        }
        morph(reduced: reducesMotion()) { self.isSelected = selected }
    }

    /// An immediate change: the content lands whole, at its own width, and a
    /// morph still running (a reused row's last person) ends here rather than
    /// swapping in later.
    private func land() {
        morphGeneration += 1
        veil.layer.removeAllAnimations()
        veil.effect = nil
        veil.isHidden = true
        refresh()
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }

    /// The count's own transition: the digits are pushed up when it grows,
    /// down when it shrinks; a fade under Reduce Motion.
    private func rollCount(from old: Int, to new: Int, reduced: Bool) {
        let transition = CATransition()
        transition.duration = Metrics.fadeDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if reduced {
            transition.type = .fade
            record(.countFade)
        } else {
            transition.type = .push
            transition.subtype = new >= old ? .fromTop : .fromBottom
            record(.countRoll(up: new >= old))
        }
        refresh()
        updateConfiguration()
        layoutIfNeeded()
        titleLabel?.layer.add(transition, forKey: "appButton.count")
        resize(reduced: reduced)
    }

    /// A symbol swapped for another: UIKit's replace transition.
    private func replaceSymbol(reduced: Bool) {
        record(reduced ? .symbolFade : .symbolReplace)
        if reduced {
            UIView.transition(with: self, duration: Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.refresh()
                self.layoutIfNeeded()
            }
        } else {
            refresh()
        }
        resize(reduced: reduced)
    }

    /// The old content blurs and fades out, the new one unblurs in; a
    /// cross-fade under Reduce Motion.
    private func morph(reduced: Bool, swap: (() -> Void)? = nil) {
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
        veil.isHidden = false
        let half = Metrics.morphDuration / 2
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

    /// The width follows the content, the neighbours with it — a spring, or
    /// at once under Reduce Motion (the cross-fade covers it).
    private func resize(reduced: Bool) {
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        let host = superview ?? self
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
        guard animated, window != nil else {
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

    override open var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            refresh()
        }
    }

    /// Disabled: greyed, `.notEnabled`, no press, no action, no feedback —
    /// and still the target of a touch inside it (`hitTest`), so the finger
    /// never reaches what is under it.
    override open var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            refresh()
        }
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
    /// placeholder claims no answer, and a load in flight ignores re-taps. The
    /// touch is refused before the control tracks it, so neither the press
    /// nor the action starts.
    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTaps else { return }
        super.touchesBegan(touches, with: event)
    }

    override open func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard acceptsTaps else { return false }
        return super.beginTracking(touch, with: event)
    }

    override open func sendAction(_ action: UIAction) {
        guard acceptsTaps else { return }
        super.sendAction(action)
    }

    override open func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard acceptsTaps else { return }
        super.sendAction(action, to: target, for: event)
    }

    /// Whether a tap reaches the action now.
    public var acceptsTaps: Bool { phase == .content && isEnabled }

    override open func accessibilityActivate() -> Bool {
        // Busy: VoiceOver can still focus it and hears "in progress"; a
        // double tap does nothing, and says it did nothing.
        guard acceptsTaps else { return true }
        return super.accessibilityActivate()
    }

    private func prepareHaptic() {
        switch haptic {
        case .none: return
        case .selection:
            if selection == nil { selection = HapticSelection() }
            selection?.prepare()
        case .lightImpact, .mediumImpact:
            if impact == nil { impact = HapticImpact(style: haptic == .lightImpact ? .light : .medium) }
            impact?.prepare()
        }
    }

    private func tapped() {
        switch haptic {
        case .none: break
        case .selection:
            if selection == nil { selection = HapticSelection() }
            selection?.selectionChanged()
            record(.haptic(.selection))
        case .lightImpact, .mediumImpact:
            if impact == nil { impact = HapticImpact(style: haptic == .lightImpact ? .light : .medium) }
            impact?.impactOccurred()
            record(.haptic(haptic))
        }
        if bouncesSymbolOnTap { playSymbolEffect() }
    }

    private func syncHold() {
        if holdFreezesScrolling, hold == nil {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))
            recognizer.minimumPressDuration = Metrics.holdDuration
            // Shares the finger with the button's OWN recognisers — its menu's
            // — and with nothing above: the scrollers, a pager, the back swipe
            // are exactly what a recognised hold is meant to stop.
            recognizer.delegate = holdDelegate
            // ⚠️ FALSE: the hold only exists to be RECOGNISED — a recognised
            // long press stops the scroller's pan from ever beginning — while
            // the button keeps tracking the same finger, so its press stays
            // held and a lift inside is still its tap.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            addGestureRecognizer(recognizer)
            hold = recognizer
        } else if !holdFreezesScrolling, let hold {
            removeGestureRecognizer(hold)
            self.hold = nil
        }
    }

    @objc private func holdChanged(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isHolding = true
            isHeldInside = true
            applyWash()
            // The tick that says "held — the screen is yours". A button with
            // a menu is about to get the menu's own; two in half a second is
            // one too many.
            if menuProvider == nil { HapticImpact(style: .soft).impactOccurred() }
        case .changed:
            let inside = point(inside: recognizer.location(in: self), with: nil)
            guard inside != isHeldInside else { return }
            isHeldInside = inside
            applyWash()
        default:
            isHolding = false
            isHeldInside = false
            applyWash()
        }
    }

    /// The wash for the current state: held and inside, pressed, or none.
    private func applyWash() {
        let target: CGFloat
        if !washesOnPress {
            target = 0
        } else if isHolding && isHeldInside {
            target = Metrics.heldWash
        } else {
            target = pressFeedback?.isPressed == true ? Metrics.pressedWash : 0
        }
        guard wash.alpha != target else { return }
        UIView.animate(
            withDuration: PressFeedback.Metrics.response, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.wash.alpha = target
        }
    }

    // MARK: - Menu

    override open func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menuProvider else {
            return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menuProvider() }
    }

    private static let highlightPreviewSelector = #selector(
        UIContextMenuInteractionDelegate.contextMenuInteraction(_:configuration:highlightPreviewForItemWithIdentifier:)
    )
    private static let dismissalPreviewSelector = #selector(
        UIContextMenuInteractionDelegate.contextMenuInteraction(_:configuration:dismissalPreviewForItemWithIdentifier:)
    )

    override open func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        guard menuProvider != nil else {
            // ⚠️ ONLY IF UIBUTTON ANSWERS IT: on iOS 27 it does not, and the
            // super call trapped with an unrecognized selector the moment a
            // native menu opened (the profile's "..." — #1344). Nil is
            // UIKit's own preview.
            guard UIButton.instancesRespond(to: Self.highlightPreviewSelector) else { return nil }
            return super.contextMenuInteraction(
                interaction, configuration: configuration, highlightPreviewForItemWithIdentifier: identifier
            )
        }
        return shapedPreview()
    }

    override open func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        guard menuProvider != nil else {
            // Same guard as the highlight preview's.
            guard UIButton.instancesRespond(to: Self.dismissalPreviewSelector) else { return nil }
            return super.contextMenuInteraction(
                interaction, configuration: configuration, dismissalPreviewForItemWithIdentifier: identifier
            )
        }
        return shapedPreview()
    }

    /// The button lifted as its own shape.
    private func shapedPreview() -> UITargetedPreview? {
        guard window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: parameters)
    }

    // MARK: - Motion

    /// Comes in: a bounce from small, or a fade under Reduce Motion — the
    /// shared `AppearMotion`. Its neighbours make room in the same beat.
    public func appear(animated: Bool) {
        guard animated, window != nil else {
            isHidden = false
            alpha = 1
            transform = .identity
            return
        }
        let host = superview
        let kind = AppearMotion.appear(self, reducesMotion: reducesMotion()) {
            self.isHidden = false
            host?.layoutIfNeeded()
        }
        record(Self.event(kind))
    }

    /// Goes: scales out and fades, the stack closing the gap in the same
    /// beat; a fade under Reduce Motion. Hidden at the end.
    public func disappear(animated: Bool, completion: (() -> Void)? = nil) {
        guard animated, window != nil, !isHidden else {
            isHidden = true
            completion?()
            return
        }
        let host = superview
        let kind = AppearMotion.disappear(self, reducesMotion: reducesMotion()) {
            self.isHidden = true
            host?.layoutIfNeeded()
        } completion: { finished in
            // An appear that took over mid-flight owns the alpha and scale.
            if finished {
                self.transform = .identity
                self.alpha = 1
            }
            completion?()
        }
        record(Self.event(kind))
    }

    private static func event(_ kind: AppearMotion.Kind) -> Event {
        switch kind {
        case .bounceIn: .bounceIn
        case .fadeIn: .fadeIn
        case .scaleOut: .scaleOut
        case .fadeOut: .fadeOut
        }
    }

    /// The symbol's own effect on an action (a like): a bounce, or a short
    /// flash of the ink under Reduce Motion.
    public func playSymbolEffect() {
        guard content.symbol != nil, let imageView else { return }
        if reducesMotion() {
            record(.symbolFlash)
            imageView.alpha = 0.35
            UIView.animate(withDuration: Metrics.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
                imageView.alpha = 1
            }
        } else {
            record(.symbolBounce)
            if let pointsHeart { pointsHeart.bounce() } else { imageView.addSymbolEffect(.bounce) }
        }
    }

    /// An action that came back fine: optionally the symbol morphs (a
    /// checkmark), and the success notification plays if asked.
    public func succeed(showing symbol: String? = nil) {
        if notifiesCompletion { notify(.success) }
        guard let symbol else { return }
        var next = content
        next.symbol = symbol
        setContent(next, animated: true)
    }

    /// An action that failed: a short shake, a red flash under Reduce Motion,
    /// and the error notification if asked.
    public func fail() {
        if notifiesCompletion { notify(.error) }
        if reducesMotion() {
            record(.failureFlash)
            flash.alpha = 0.35
            UIView.animate(withDuration: Metrics.fadeDuration * 2, delay: 0, options: [.allowUserInteraction]) {
                self.flash.alpha = 0
            }
        } else {
            record(.shake)
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            let amplitude = Metrics.shakeAmplitude
            shake.values = [0, -amplitude, amplitude, -amplitude * 0.66, amplitude * 0.66, -amplitude * 0.33, 0]
            shake.duration = Metrics.shakeDuration
            shake.isAdditive = true
            shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(shake, forKey: "appButton.shake")
        }
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        if notification == nil { notification = HapticNotification() }
        notification?.notificationOccurred(type)
        record(.notification(success: type == .success))
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

    private func refreshAccessibility() {
        // A placeholder claims no answer — not even to VoiceOver (#933).
        isAccessibilityElement = phase != .placeholder
        var traits: UIAccessibilityTraits = .button
        if isToggle { traits.insert(.toggleButton) }
        if isSelected { traits.insert(.selected) }
        if !isEnabled || phase == .placeholder { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        switch phase {
        case .content: accessibilityValue = content.count.map(String.init)
        case .loading: accessibilityValue = busyText
        case .placeholder: accessibilityValue = nil
        }
        largeContentTitle = content.text ?? accessibilityLabel
        largeContentImage = content.symbol.flatMap { UIImage.symbol(named: $0) }
    }

    // MARK: - Configuration

    /// Whether the gradient heart stands for the glyph now.
    private var showsPointsHeart: Bool {
        drawsPointsHeart && isSelected && content.symbol != nil && phase == .content && isEnabled
    }

    private func refresh() {
        configuration = configuration(for: content, phase: phase)
        refreshPointsHeart()
        materialGround.effect = usesMaterial ? UIBlurEffect(style: .systemThinMaterial) : nil
        materialGround.isHidden = !usesMaterial
        // An alpha, not `isHidden`: Follow → Following inside a morph fades
        // the gradient into the quiet fill.
        gradientGround.alpha = usesGradient ? 1 : 0
        refreshAccessibility()
    }

    /// The ground drawn now: the selected one when selected.
    public var currentGround: Ground? {
        switch aspect {
        case .bare:
            return buttonShapes() ? .quiet : nil
        case .pill(let ground):
            guard isSelected else { return ground }
            if let selectedGround { return selectedGround }
            switch ground {
            case .prominent: return .quiet
            case .quiet: return .prominent
            case .tinted, .material: return ground
            }
        }
    }

    /// Whether the prominent gradient is the ground now: not when greyed, nor
    /// as a placeholder's bone. A busy button keeps it (#1180): its fill is
    /// clear, so without the gradient its white spinner would stand on nothing.
    public var usesGradient: Bool {
        currentGround == .prominent && isEnabled && phase != .placeholder
    }

    private var usesMaterial: Bool {
        currentGround == .material && isEnabled && phase != .placeholder
    }

    /// The configuration for `content` in `phase`, at the button's aspect,
    /// size, shape and state.
    func configuration(for content: Content, phase: Phase) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch currentGround {
        case .prominent?:
            config = .filled()
            // The gradient view is the ground (#1178); the fill stays clear
            // over it.
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
            // ⚠️ `.plain()` GROWS A TINTED GROUND WHEN SELECTED (a liked heart
            // came out on a blue pill). Bare means no ground in every state;
            // the press is the dim.
            config.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        }
        if let inkColor { config.baseForegroundColor = inkColor }
        if isSelected, case .bare = aspect, let selectedTint {
            config.imageColorTransformer = UIConfigurationColorTransformer { _ in selectedTint }
        }
        if showsPointsHeart {
            // The gradient heart draws it (`pointsHeart`); the button's own
            // glyph only holds the place.
            config.imageColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        }

        switch shape {
        case .capsule:
            config.cornerStyle = .capsule
        case .card:
            config.cornerStyle = .fixed
            config.background.cornerRadius = Metrics.cardRadius
        }

        let font = Self.font(for: size)
        config.contentInsets = Self.insets(for: size)
        config.imagePadding = size == .inline ? Spacing.xs : 6
        config.imagePlacement = content.imagePlacement
        config.preferredSymbolConfigurationForImage = symbolPointSize.map {
            UIImage.SymbolConfiguration(pointSize: $0, weight: .medium, scale: .medium)
        } ?? UIImage.SymbolConfiguration(font: font, scale: size == .icon ? .medium : .small)
        config.image = content.symbol.flatMap { UIImage.symbol(named: $0) }
        // A symbol swapped for another is replaced — the one symbol motion
        // UIKit does here; under reduced motion the swap cross-fades instead
        // (`replaceSymbol`).
        config.symbolContentTransition = reducesMotion() ? nil : UISymbolContentTransition(.replace)
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
            config.showsActivityIndicator = true
            if config.image == nil {
                // Words only: the spinner replaces them, in the held width.
                config.attributedTitle = nil
            }
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
        case .icon:
            UIFont.scaledSystemFont(ofSize: 17, weight: .regular, relativeTo: .body, maximumPointSize: 22)
        case .inline:
            UIFont.scaledMonospacedDigitSystemFont(ofSize: 13, weight: .semibold, relativeTo: .footnote, maximumPointSize: 17)
        }
    }

    static func insets(for size: Size) -> NSDirectionalEdgeInsets {
        switch size {
        case .row: NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
        case .header: NSDirectionalEdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
        case .icon: .zero
        case .inline: NSDirectionalEdgeInsets(top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs, trailing: Spacing.sm)
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
            let fitted = button.size == .icon
                ? CGSize(width: HeroTray.bubbleSize, height: HeroTray.bubbleSize)
                : button.fittingSize(for: button.content)
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

    /// What the button did, in order — the motion it picked, the haptic it
    /// played. A test reads the DECISION, which is what the fallbacks are.
    public enum Event: Equatable, Sendable {
        case bounceIn, fadeIn, scaleOut, fadeOut
        case blurMorph, crossFade
        case countRoll(up: Bool), countFade
        case symbolReplace, symbolFade
        case symbolBounce, symbolFlash
        case stateTint, placeholderReveal
        case shake, failureFlash
        case haptic(Haptic)
        case notification(success: Bool)
    }

    public private(set) var events: [Event] = []

    private func record(_ event: Event) {
        if events.count >= 32 { events.removeFirst() }
        events.append(event)
    }

    #if DEBUG
    public var debugHeldSize: CGSize? { heldSize }
    public var debugHasBone: Bool { bone != nil }
    public var debugHoldRecognizer: UILongPressGestureRecognizer? { hold }

    public var debugVeilIsShown: Bool { !veil.isHidden }
    /// The wash's current target.
    public var debugWashAlpha: CGFloat { wash.alpha }
    /// A hold beginning, then lifting inside or outside — the action fires
    /// on a lift inside, as a finger's would.
    public func debugHold(liftInside inside: Bool) {
        isHolding = true
        isHeldInside = true
        applyWash()
        isHolding = false
        isHeldInside = false
        applyWash()
        if inside { debugTap() }
    }
    public var debugMaterialIsShown: Bool { !materialGround.isHidden }
    /// The tap a finger would make, through the same gate.
    public func debugTap() {
        guard acceptsTaps else { return }
        sendActions(for: .primaryActionTriggered)
    }
    #endif
}

/// The hold's delegate: it shares the finger with the button's own
/// recognisers (its menu's, its press's) and with nothing above it.
@MainActor
private final class HoldDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var button: AppButton?

    init(button: AppButton) {
        self.button = button
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard let button, let view = other.view else { return false }
        return view.isDescendant(of: button)
    }
}

// MARK: - The points heart

extension AppButton {
    /// Mounts or removes the gradient heart for the current state, sized as
    /// the button sizes its glyph.
    fileprivate func refreshPointsHeart() {
        guard showsPointsHeart, let symbol = content.symbol else {
            pointsHeart?.removeFromSuperview()
            pointsHeart = nil
            return
        }
        let heart = pointsHeart ?? {
            let view = PointsHeartView()
            addSubview(view)
            pointsHeart = view
            return view
        }()
        heart.configuration = configuration?.preferredSymbolConfigurationForImage ?? AppSymbol.fixed(15)
        heart.setLiked(symbol == PointsSymbol.glyph || symbol == AppSymbol.liked.rawValue, animated: false)
        heart.ink = configuration?.baseForegroundColor ?? .label
        setNeedsLayout()
    }
}

