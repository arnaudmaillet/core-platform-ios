import ObjectiveC
import UIKit

/// What every app button does the same, written once (#1666): the press (a
/// system Liquid Glass button's swell, `PressFeedback`), the haptics and the
/// sound, the 44pt hit region, the gate on taps, VoiceOver's traits, the
/// appear and go, the menu that morphs back, the hold that freezes the
/// scroller, the grounds a button can stand on and the failure shake.
///
/// ```
///   AppControl ─┬─ AppButton      words: Follow · Message · a price
///               └─ AppIconButton  one symbol: a 44pt bubble, or a bare glyph
///                                 with its count (a card's ♡ 1.2K)
/// ```
///
/// A subclass says what it draws — `groundRect`, `groundCornerRadius`,
/// `currentGround` — and refreshes its own configuration; everything else
/// is here.
///
/// ⚠️ **IT RENDERS A STATE; IT OWNS NO BUSINESS LOGIC.** Optimistic updates,
/// rollback and "one mutation in flight" stay in the view models. A caller
/// says what the button shows and reacts to its action; the button never
/// decides what a tap means.
///
/// ⚠️ **NEVER GLASS.** No `.glass()` / `.prominentGlass()` / `UIGlassEffect`:
/// the buttons that wear glass keep their own implementation (decided
/// 2026-10-11). Over a photograph the ground is a blur MATERIAL. The tests
/// scan these files.
///
/// ⚠️ **ONE PRESS (#866).** `PressFeedback` is attached once, at init, and is
/// the only thing that scales the button under a finger; UIKit's
/// configuration only resolves a highlight. The symbol animation stays OFF
/// (#1376): on, UIKit shrinks the icon alone on every highlight. The sound
/// is decided at init for the same reason: re-attaching would stack a
/// second press.
///
/// ⚠️ **NO REDUCE MOTION (the owner, 2026-10-23: "always the same
/// behaviour").** `reducesMotion` answers false; the fallbacks each motion
/// keeps — a fade for the bounce, a flash for the shake — stay reachable
/// for the tests that ask.
@MainActor
open class AppControl: UIButton {
    // MARK: - Look

    /// What a button stands on.
    public enum Ground: Equatable, Sendable {
        /// The one action that matters (Follow): a solid fill,
        /// `prominentColor`, white ink — the same in both appearances
        /// (the owner, 2026-10-23: no more pink-to-white gradient, #1178).
        case prominent
        /// The profile tray's quiet fill (`HeroTray.fill`): Message, Following.
        case quiet
        /// The tint, washed: a price.
        case tinted
        /// A blur material, for a button over a photograph. Never glass.
        case material
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
        /// A fade: the state tint, the fallbacks.
        public static let fadeDuration: TimeInterval = 0.22
        /// The fluid resize's spring: the width following the content.
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

    /// The role a tap plays (#1881) — `tick` for a choice, `toggleOn` for a
    /// state added, `commit` for a weighty action. Nil, the default: a
    /// plain button plays nothing.
    public var haptic: Haptic?
    /// `succeed` / `fail` play the success or error notification. Off by
    /// default.
    public var notifiesCompletion = false
    /// The prominent ground's colour (the owner, 2026-10-23: plain colours,
    /// no gradient), under white ink.
    public var prominentColor: UIColor = Palette.prominentFill {
        didSet { prominentGround.backgroundColor = prominentColor }
    }
    /// The ink at rest. Nil: the ground's own.
    public var inkColor: UIColor? { didSet { refresh() } }
    /// Whether the button is a toggle (Follow, like, pin): VoiceOver says so.
    public var isToggle = false { didSet { refreshAccessibility() } }

    /// A long press holds the screen: the scroller under the button stops
    /// for as long as the finger stays, and a lift inside still taps.
    public var holdFreezesScrolling = false { didSet { syncHold() } }

    /// ⚠️ **A CARD ACTION'S PRESS (#934): THE CONTRAST STEP, NOT A FADE.** A
    /// dim on a card's action reads as "disabled" as much as "pressed". With
    /// this on, a `.label` wash rises inside the button's shape instead —
    /// one step on the press, a second while held (`holdFreezesScrolling`) —
    /// darker in light mode, lighter in dark, the way the system's
    /// highlighted cells go. Build such a button with `dims: false`.
    public var washesOnPress = false { didSet { applyWash() } }

    /// A menu raised by holding the button (the like's stake menu), built
    /// when it lifts so it reads current state; nil for none. The button
    /// lifts as itself — its shape, not a rectangle.
    public var menuProvider: (() -> UIMenu?)? {
        didSet { isContextMenuInteractionEnabled = menuProvider != nil }
    }

    /// Whether a finger has held the button past `Metrics.holdDuration`.
    public private(set) var isHolding = false
    private var isHeldInside = false

    /// Whether motion is reduced: never, whatever the system setting. A
    /// test may still ask for the fallbacks.
    public var reducesMotion: @MainActor () -> Bool = { false }
    /// Whether the iPhone's Button Shapes setting is on — UIKit's unless a
    /// test says.
    public var buttonShapes: @MainActor () -> Bool = { UIAccessibility.buttonShapesEnabled } {
        didSet { refresh() }
    }

    /// The single press feedback (#866), attached at init.
    public private(set) var pressFeedback: PressFeedback?

    /// The grounds a subclass's configuration cannot draw: a material, the
    /// prominent fill (animatable, so a morph fades it), the press's wash
    /// and the failure's flash — each laid on `groundRect`.
    let materialGround = UIVisualEffectView(effect: nil)
    let prominentGround = UIView()
    let wash = UIView()
    let flash = UIView()
    private var hold: UILongPressGestureRecognizer?
    private lazy var holdDelegate = HoldDelegate(control: self)
    /// The stand-in that scales out in the button's place (`disappear`).
    private weak var ghost: UIView?

    // MARK: - Init

    /// - Parameters:
    ///   - pressStyle: how the button answers the finger — the system glass
    ///     swell for every app button (the owner, 2026-10-24).
    ///   - sound: the tick a tap plays (`UISound.tap`, gated by Interface
    ///     Sounds). Decided here, once: see the type's note.
    ///   - dims: the press also fades the button a little.
    init(pressStyle: PressFeedback.Style, sound: UISound?, dims: Bool) {
        super.init(frame: .zero)
        // ⚠️ OFF (#1376). On, UIKit shrinks the symbol to about half on every
        // highlight — a second press on the icon alone. A symbol replace
        // comes from the configuration's `symbolContentTransition` instead.
        isSymbolAnimationEnabled = false
        setUpGrounds()
        pressFeedback = PressFeedback.attach(
            to: self, style: pressStyle, sound: sound, dims: dims,
            reducesMotion: { [weak self] in self?.reducesMotion() ?? false }
        )
        // The wash follows the SAME finger decisions as the press.
        pressFeedback?.onPressChanged = { [weak self] _ in self?.applyWash() }
        // The ground swells by its own size, about its own middle.
        pressFeedback?.drawnRect = { [weak self] in self?.groundRect ?? .zero }
        addAction(UIAction { [weak self] _ in self?.prepareHaptic() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilitySettingChanged),
            name: UIAccessibility.buttonShapesEnabledStatusDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpGrounds() {
        wash.backgroundColor = .label
        wash.alpha = 0
        wash.isUserInteractionEnabled = false
        insertSubview(wash, at: 0)

        materialGround.isUserInteractionEnabled = false
        materialGround.clipsToBounds = true
        insertSubview(materialGround, at: 0)

        prominentGround.isUserInteractionEnabled = false
        prominentGround.clipsToBounds = true
        prominentGround.backgroundColor = prominentColor
        prominentGround.alpha = 0
        insertSubview(prominentGround, aboveSubview: materialGround)

        flash.isUserInteractionEnabled = false
        flash.alpha = 0
        flash.backgroundColor = .systemRed
        addSubview(flash)
    }

    @objc private func accessibilitySettingChanged() { refresh() }

    // MARK: - What a subclass draws

    /// Where the ground is drawn, in the bounds. The bounds by default.
    open var groundRect: CGRect { bounds }

    /// The ground's corner radius: a capsule's — half its shorter side — by
    /// default.
    open var groundCornerRadius: CGFloat { groundCornerRadius(for: groundRect.size) }

    /// The corner radius a ground of `size` has.
    open func groundCornerRadius(for size: CGSize) -> CGFloat {
        min(size.width, size.height) / 2
    }

    /// The ground drawn now; nil for none.
    open var currentGround: Ground? { nil }

    /// Whether a ground is drawn at all now — false while a placeholder's
    /// bone is the whole picture.
    open var showsGround: Bool { true }

    /// Whether the prominent fill is the ground now: not when greyed, nor
    /// while no ground shows.
    public var usesProminentFill: Bool {
        currentGround == .prominent && isEnabled && showsGround
    }

    var usesMaterial: Bool {
        currentGround == .material && isEnabled && showsGround
    }

    /// Applies the state: the subclass's configuration, then the grounds
    /// and the accessibility. A subclass overrides it and calls
    /// `refreshGrounds()` and `refreshAccessibility()` itself.
    open func refresh() {
        refreshGrounds()
        refreshAccessibility()
    }

    /// The material and prominent grounds for `currentGround`.
    func refreshGrounds() {
        materialGround.effect = usesMaterial ? UIBlurEffect(style: .systemThinMaterial) : nil
        materialGround.isHidden = !usesMaterial
        // An alpha, not `isHidden`: Follow → Following inside a morph fades
        // the prominent fill into the quiet one.
        prominentGround.alpha = usesProminentFill ? 1 : 0
    }

    /// VoiceOver's traits: a button, a toggle, selected, not enabled. A
    /// subclass adds its value and label.
    open func refreshAccessibility() {
        var traits: UIAccessibilityTraits = .button
        if isToggle { traits.insert(.toggleButton) }
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    // MARK: - Layout

    override open func layoutSubviews() {
        super.layoutSubviews()
        let ground = groundRect
        let radius = groundCornerRadius
        for view in [materialGround, prominentGround, wash, flash] {
            view.frame = ground
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
        }
        sendSubviewToBack(materialGround)
        insertSubview(prominentGround, aboveSubview: materialGround)
        insertSubview(wash, aboveSubview: prominentGround)
        bringSubviewToFront(flash)
    }

    /// A finger lands anywhere within 44×44 around the ground, however small
    /// it is drawn.
    override open func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitRegion.contains(point)
    }

    /// ⚠️ **A TOUCH INSIDE STAYS THE BUTTON'S, EVEN WHILE IT TAKES NO TAP.**
    /// UIKit skips a disabled control in hit-testing, and the finger lands on
    /// whatever is under it: a greyed price SELECTED ITS ROW, which closed the
    /// shop and flew the map to the country (filmed on the simulator, #935).
    /// Returned here, the touch meets `touchesBegan`, which swallows it.
    override open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let view = super.hitTest(point, with: event) { return view }
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        return self
    }

    /// The region a touch counts in: the ground, grown to at least 44×44.
    public var hitRegion: CGRect {
        let ground = groundRect
        let dx = max(0, (Metrics.minimumHitSide - ground.width) / 2)
        let dy = max(0, (Metrics.minimumHitSide - ground.height) / 2)
        return ground.insetBy(dx: -dx, dy: -dy)
    }

    /// Where a change of the button's size is laid out, animated: past the
    /// stacks it sits in, to the view holding the outermost.
    ///
    /// ⚠️ NOT THE SUPERVIEW: laid out alone, a row stack animated its
    /// arranged views and its own size, but its parent stack moved it in a
    /// second, unanimated pass — the whole row jumped aside, then slid back
    /// (filmed, the owner 2026-10-24).
    var layoutRoot: UIView? {
        var view = superview
        while let current = view, current is UIStackView, let parent = current.superview {
            view = parent
        }
        return view
    }

    // MARK: - Selected and enabled

    override open var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            refresh()
        }
    }

    /// Disabled: greyed, `.notEnabled`, no press, no action, no feedback —
    /// and still the touch's owner (`hitTest`).
    override open var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            refresh()
        }
    }

    // MARK: - Taps

    /// Whether a tap reaches the action now, the button enabled — false for
    /// a placeholder or a load in flight.
    open var acceptsTapsWhenEnabled: Bool { true }

    /// Whether a tap reaches the action now.
    public var acceptsTaps: Bool { isEnabled && acceptsTapsWhenEnabled }

    /// ⚠️ **A BUTTON THAT TAKES NO TAP TAKES NO TOUCH**: the touch is refused
    /// before the control tracks it, so neither the press nor the action
    /// starts.
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

    override open func accessibilityActivate() -> Bool {
        // Busy: VoiceOver can still focus it; a double tap does nothing, and
        // says it did nothing.
        guard acceptsTaps else { return true }
        return super.accessibilityActivate()
    }

    private func prepareHaptic() {
        if let haptic { Haptics.prepare(haptic) }
        // The hold's own (`held`), ahead of it.
        if holdFreezesScrolling, menuProvider == nil { Haptics.prepare(.held) }
    }

    private func tapped() {
        if let haptic {
            Haptics.play(haptic)
            record(.haptic(haptic))
        }
        didTap()
    }

    /// After a tap's haptic — a subclass's own answer to it (a like's
    /// bounce).
    open func didTap() {}

    // MARK: - Hold

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

    /// The hold recognised: the held wash, and `held` — "the screen is
    /// yours" (#1881). A button with a menu is about to get the menu's own;
    /// two in half a second is one too many.
    private func beginHold() {
        isHolding = true
        isHeldInside = true
        applyWash()
        if menuProvider == nil {
            Haptics.play(.held)
            record(.haptic(.held))
        }
    }

    @objc private func holdChanged(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginHold()
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
        // A provider that answers nil raises NOTHING: no lifted preview round
        // an empty menu (a guest's like has no stake menu, #1146).
        guard let menu = menuProvider() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    private static let highlightPreviewSelector = #selector(
        UIContextMenuInteractionDelegate.contextMenuInteraction(_:configuration:highlightPreviewForItemWithIdentifier:)
    )
    private static let dismissalPreviewSelector = #selector(
        UIContextMenuInteractionDelegate.contextMenuInteraction(_:configuration:dismissalPreviewForItemWithIdentifier:)
    )

    /// ⚠️ A PLAIN MENU'S PREVIEWS ARE UIKIT'S. Answering them — even with
    /// nil — told the interaction this button had previews of its own; a
    /// nil DISMISSAL preview faded the menu out in place rather than
    /// morphing it back into the button, which UIKit then showed again only
    /// once its clean-up ran, a beat with nothing on screen (the owner,
    /// 2026-10-23). With no `menuProvider`, and no `UIButton` answer to
    /// defer to (iOS 27), the button says it has none.
    override open func responds(to aSelector: Selector!) -> Bool {
        if menuProvider == nil,
           aSelector == Self.highlightPreviewSelector || aSelector == Self.dismissalPreviewSelector,
           !UIButton.instancesRespond(to: aSelector) {
            return false
        }
        return super.responds(to: aSelector)
    }

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
        parameters.visiblePath = UIBezierPath(roundedRect: groundRect, cornerRadius: groundCornerRadius)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: parameters)
    }

    // MARK: - Appear and go

    /// Comes in: a bounce from small with a fade — the shared
    /// `AppearMotion` — WHERE IT WILL STAND, about its ground's middle, over
    /// its neighbours, which glide to make room in the same beat.
    ///
    /// ⚠️ ITS OWN FRAME DOES NOT ANIMATE. Un-hidden inside the animation, a
    /// stack grew it from the zero frame a hidden arranged view has, at its
    /// top-left corner — a button that looked not laid out (the owner,
    /// 2026-10-23). The frame changes the layout gave it and its insides are
    /// dropped, so only the bounce and the fade run.
    public func appear(animated: Bool) {
        ghost?.removeFromSuperview()
        guard animated, window != nil else {
            isHidden = false
            alpha = 1
            transform = .identity
            return
        }
        let host = superview
        // Over its neighbours while it grows: the one making room slid OVER
        // it otherwise.
        host?.bringSubviewToFront(self)
        let root = layoutRoot
        let before = host?.bounds.size ?? .zero
        let kind = AppearMotion.appear(self, reducesMotion: reducesMotion(), pivot: groundOffset) {
            self.isHidden = false
            root?.layoutIfNeeded()
        }
        dropLayoutAnimations()
        // Its middle follows the row's as the row grows to take it, so it
        // comes in centred on its neighbours, which are on their way too.
        let shift = Self.midlineShift(in: host, from: before)
        if shift != .zero {
            let final = center
            UIView.performWithoutAnimation { center = CGPoint(x: final.x - shift.x, y: final.y - shift.y) }
            UIView.animate(springDuration: AppearMotion.appearDuration, bounce: AppearMotion.appearBounce, options: [.allowUserInteraction]) {
                self.center = final
            }
        }
        record(Self.event(kind))
    }

    /// Goes: scales out and fades WHERE IT STOOD, about its ground's middle,
    /// over its neighbours, the stack closing the gap in the same beat.
    /// Hidden at once — the callers read `isHidden` — so what scales out is
    /// a stand-in, the button's own pixels.
    ///
    /// ⚠️ NOT THE BUTTON ITSELF: hidden inside the animation, a stack shrank
    /// its frame to its top-left corner while it scaled (the owner,
    /// 2026-10-23).
    public func disappear(animated: Bool, completion: (() -> Void)? = nil) {
        guard animated, window != nil, !isHidden, let host = superview else {
            isHidden = true
            completion?()
            return
        }
        ghost?.removeFromSuperview()
        let stand = snapshotView(afterScreenUpdates: false)
        if let stand {
            stand.isUserInteractionEnabled = false
            stand.bounds = bounds
            stand.center = center
            stand.transform = transform
            // Over its neighbours: the one closing the gap slid OVER it and
            // read as the button pushed aside (the owner, 2026-10-23).
            host.addSubview(stand)
            ghost = stand
        }
        isHidden = true
        transform = .identity
        alpha = 1
        let reduced = reducesMotion()
        let root = layoutRoot ?? host
        let before = host.bounds.size
        UIView.animate(withDuration: reduced ? AppearMotion.fadeDuration : AppearMotion.disappearDuration,
                       delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            root.layoutIfNeeded()
            // The ghost rides the row's midline as the row closes on it.
            if let stand {
                let shift = Self.midlineShift(in: host, from: before)
                stand.center = CGPoint(x: stand.center.x + shift.x, y: stand.center.y + shift.y)
            }
        }
        guard let stand else {
            record(reduced ? .fadeOut : .scaleOut)
            completion?()
            return
        }
        let kind = AppearMotion.disappear(stand, reducesMotion: reduced, pivot: groundOffset, completion: { _ in
            stand.removeFromSuperview()
            completion?()
        })
        record(Self.event(kind))
    }

    /// How far a centring stack's midline moved from a size `before` to its
    /// size now — the line its arranged views ride on: a horizontal stack's
    /// vertical middle, a vertical one's horizontal middle.
    private static func midlineShift(in host: UIView?, from before: CGSize) -> CGPoint {
        guard let stack = host as? UIStackView, stack.alignment == .center else { return .zero }
        let after = stack.bounds.size
        return stack.axis == .horizontal
            ? CGPoint(x: 0, y: (after.height - before.height) / 2)
            : CGPoint(x: (after.width - before.width) / 2, y: 0)
    }

    /// Removes what a layout inside the appear's animation block added: the
    /// button's own frame and corner animations, and every animation of its
    /// insides but those a subclass keeps — only the bounce and the fade run.
    ///
    /// ⚠️ THE CORNERS TOO: laid out inside the block, the grounds' corner
    /// radius grew from the zero frame's — a SQUARE button rounding as it
    /// bounced in (the owner, 2026-10-23).
    private func dropLayoutAnimations() {
        for key in layer.animationKeys() ?? [] where !key.hasPrefix("opacity") && !key.hasPrefix("transform") {
            layer.removeAnimation(forKey: key)
        }
        func dropAll(in view: UIView) {
            guard !keepsAnimations(of: view) else { return }
            view.layer.removeAllAnimations()
            view.layer.sublayers?.forEach { $0.removeAllAnimations() }
            view.subviews.forEach(dropAll(in:))
        }
        subviews.forEach(dropAll(in:))
    }

    /// Whether `view`, inside the button, keeps its animations through an
    /// appear — a placeholder's shimmering bone.
    open func keepsAnimations(of view: UIView) -> Bool { false }

    /// The ground's middle, from the button's: off-centre in a wider slot,
    /// where it bounces in and scales out about.
    private var groundOffset: CGPoint {
        let ground = groundRect
        return CGPoint(x: ground.midX - bounds.midX, y: ground.midY - bounds.midY)
    }

    private static func event(_ kind: AppearMotion.Kind) -> Event {
        switch kind {
        case .bounceIn: .bounceIn
        case .fadeIn: .fadeIn
        case .scaleOut: .scaleOut
        case .fadeOut: .fadeOut
        }
    }

    // MARK: - Outcome

    /// An action that failed: a short shake (a red flash for a test asking
    /// for the fallback), and the error notification if asked.
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

    /// The success or error notification.
    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        Haptics.play(type == .success ? .success : type == .warning ? .warning : .error)
        record(.notification(success: type == .success))
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

    func record(_ event: Event) {
        if events.count >= 32 { events.removeFirst() }
        events.append(event)
    }

    #if DEBUG
    public var debugHoldRecognizer: UILongPressGestureRecognizer? { hold }
    /// The wash's current target.
    public var debugWashAlpha: CGFloat { wash.alpha }
    /// A hold beginning, then lifting inside or outside — the action fires
    /// on a lift inside, as a finger's would.
    public func debugHold(liftInside inside: Bool) {
        beginHold()
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
    weak var control: AppControl?

    init(control: AppControl) {
        self.control = control
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard let control, let view = other.view else { return false }
        return view.isDescendant(of: control)
    }
}
