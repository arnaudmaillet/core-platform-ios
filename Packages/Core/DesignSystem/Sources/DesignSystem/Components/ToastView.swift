import UIKit

/// A toast — the answer to actions whose only evidence is off-screen
/// ("Copied", "Report sent", "Couldn't follow @ava"). A floating, interactive
/// Liquid Glass bubble at one of six positions (#954).
///
/// Deliberately not a `UIAlertController`: those demand a dismissal tap for
/// something the user has already finished doing. Deliberately not a nav-bar
/// prompt either — the profile's bar is transparent over media and owns no
/// spare row.
///
/// ⚠️ CALL `Feedback`, NOT THIS (#804). `Feedback.success/failure/warning/info`
/// picks the host (the topmost presented screen, so a toast fired under a
/// sheet shows above it), the style and the paired haptic; this type only
/// draws. `FeedbackTests` fails the suite if `present` is called anywhere
/// else.
///
/// Toasts are self-owning: the caller fires and forgets. Only one shows at a
/// time per position in a container — a second replaces the first rather
/// than stacking, so a fast double-tap can't build a tower. `Feedback` draws
/// them in the scene's `ToastOverlay`; drawing in the screen itself is the
/// fallback for a window that is not the scene's key one (a package test
/// host's).
///
/// ## Content
///
/// A glyph (the kind's, or the caller's), a title and an optional detail
/// line, and in the trailing slot ONE of: an action ("Retry", "View") or a
/// close button — the close button whenever the toast does not leave on its
/// own (a failure).
///
/// ## Time (`duration(for:message:detail:hasAction:assistiveTechnologyRunning:)`)
///
/// - success, info, warning: `max(4 s, 2 s + 0.3 s × words)`;
/// - failure: until closed, acted on or replaced — an error that fades on a
///   timer gets missed (owner's decision, 2026-10-11);
/// - a toast with an action never leaves on its own while VoiceOver or Switch
///   Control runs (WCAG 2.2.1: timing adjustable).
///
/// The countdown (`ToastCountdown`) pauses while a finger is on the toast,
/// while VoiceOver's focus is on it and while the scene is inactive.
///
/// ## Touch
///
/// The glass is interactive (it flexes under the finger). A swipe toward the
/// toast's own edge dismisses it — down for a bottom toast, up for a top one,
/// and sideways toward its side for a leading or trailing one — on distance
/// or velocity; any other way it rubber-bands and springs back. A tap runs
/// the action, if there is one.
///
/// ## VoiceOver
///
/// The bubble is one element: its label is the text, the action is a custom
/// action, and the escape gesture dismisses it. It is announced (queued, a
/// turn later), with high priority for a failure; it never takes focus.
///
/// ## Why the animation looks the way it does
///
/// Two house rules about glass constrain it, both learned the expensive way
/// elsewhere in this app:
/// - **Never move a glass lens with `CGAffineTransform`** (the Messages
///   header's finding): a transform moves the *rendered* material, so the
///   capsule carries a stale backdrop as it travels and its edge softens. The
///   slide — and the swipe — drive layout constraints instead, which
///   re-render the glass at its true position every frame.
/// - **Never animate a `UIVisualEffectView`'s alpha** (the chat input bar's
///   rule), which includes fading an ancestor — group opacity reaches the
///   effect view just the same. The capsule arrives and leaves by swapping
///   `effect` inside the animation block, which is how UIKit interpolates
///   glass; only the content row, which is ordinary content, uses alpha.
///
/// Under Reduce Motion (`MotionPreference`) there is no slide: the glass
/// materialises and the row fades, in place.
@MainActor
public final class ToastView: UIView {
    enum Metrics {
        /// Gap between the capsule and the edge it stands on (or hangs from).
        static let bottomGap: CGFloat = Spacing.lg
        /// How far the capsule travels on entrance/exit.
        static let travel: CGFloat = 24
        static let transitionDuration: TimeInterval = 0.32
        /// Resting shadow strength. Soft and low-contrast: the glass already
        /// separates itself; the shadow only grounds it.
        static let shadowOpacity: Float = 0.22
        /// The touch target's floor.
        static let minimumHeight: CGFloat = 44
        /// Never wider than this, however wide the screen (iPad).
        static let maximumWidth: CGFloat = 420
        /// A swipe toward the edge dismisses past this distance…
        static let dismissDistance: CGFloat = 44
        /// …or this speed (points per second).
        static let dismissVelocity: CGFloat = 500
        /// How far a pull the wrong way can stretch, at most.
        static let rubberBandLimit: CGFloat = 24
    }

    /// Marks the toast at a position in a container, so the next one there
    /// can retire it instead of overlapping.
    private static let hostTag = 0x70A570

    /// How the bubble reads. One material for all — the glass is the toast's
    /// identity — so the difference rides on the glyph's tint.
    public enum Style: Sendable {
        /// Something the user did has happened ("Copied", "Report sent").
        case confirmation
        /// Something the user did has NOT happened: it was rolled back, or
        /// must be retried (#804). The glyph takes the system red — over a
        /// glass that resolves its own luminance, a tinted glyph is the one
        /// mark that still reads as "this went wrong" at a glance, without a
        /// second material or a coloured capsule.
        case failure
        /// It happened, but with a catch the viewer should know ("Saved
        /// without its sound"). The glyph takes the system orange.
        case warning

        var glyphTint: UIColor {
            switch self {
            case .confirmation: .label
            case .failure: .systemRed
            case .warning: .systemOrange
            }
        }
    }

    /// The trailing action ("Retry", "View"): its title, and what it does.
    /// The toast leaves once it has run.
    public struct Action {
        public let title: String
        public let handler: @MainActor () -> Void

        public init(_ title: String, handler: @escaping @MainActor () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    /// The style this toast was drawn in (read by tests).
    public let style: Style
    /// Its title and detail line.
    public let message: String
    public let detail: String?
    /// Where the toast sits (#954).
    public private(set) var position: ToastPosition = .bottom
    /// How long it stays up, in seconds; nil: until closed (`duration`).
    public let duration: TimeInterval?
    let action: Action?

    /// Called once the toast has left its superview — so the scene overlay
    /// that holds it can hide its window when it holds no more (#954).
    var onRemoved: (() -> Void)?

    /// The time left; nil for a toast that stays until closed.
    private(set) var countdown: ToastCountdown?

    private let backdrop = UIVisualEffectView(effect: nil)
    /// Pins the capsule to its edge. Driven instead of a transform (see the
    /// type doc): `offConstant` while off — `travel` further out than its
    /// resting place, below it for a bottom toast, above it for a top one —
    /// and `restConstant` at rest. The swipe moves it too.
    private var slide: NSLayoutConstraint?
    private var restConstant: CGFloat = 0
    private var offConstant: CGFloat = 0
    /// Pins the capsule along its edge; the sideways swipe moves it.
    private var along: NSLayoutConstraint?
    /// Keep it between the container's margins; off while a swipe moves it.
    private var marginConstraints: [NSLayoutConstraint] = []
    /// The bubble's one-line width (`measureIdealWidth`).
    private lazy var idealWidth = widthAnchor.constraint(equalToConstant: 0)
    private var rowInsets: CGFloat = 0
    private var textLabels: [UILabel] = []
    private let row = UIStackView()
    let closeButton: UIButton?
    let actionButton: UIButton?
    private var isLeaving = false
    private var sceneObservers: [NSObjectProtocol] = []

    /// The glass view (tests).
    var glassView: UIVisualEffectView { backdrop }
    /// How far the capsule slides on its way in: zero under Reduce Motion
    /// (tests).
    var entranceTravel: CGFloat { abs(offConstant - restConstant) }
    /// Whether it is on its way out (tests).
    var isDismissing: Bool { isLeaving }

    // MARK: - Presenting

    /// Shows `message` over `host`, replacing any toast already up there.
    ///
    /// - Parameters:
    ///   - message: the text — short, past-tense, no punctuation.
    ///   - symbol: an optional SF Symbol leading the text.
    ///   - host: the view to present in. Pass the view controller's `view`;
    ///     the capsule pins to its safe area, so it clears tab and tool bars.
    ///   - floor: what the capsule stands on instead of the safe area — the
    ///     top of a composer resting on it, which would otherwise cover it
    ///     (#729).
    ///   - style: a confirmation, a failure (#804) or a warning.
    @discardableResult
    public static func present(
        _ message: String,
        symbol: String? = "checkmark.circle.fill",
        in host: UIView,
        above floor: NSLayoutYAxisAnchor? = nil,
        style: Style = .confirmation
    ) -> ToastView {
        present(
            message, detail: nil, symbol: symbol, style: style, action: nil, position: .bottom, in: host,
            edge: floor ?? host.safeAreaLayoutGuide.bottomAnchor
        )
    }

    /// Shows a toast at `position` in `container`, replacing any toast
    /// already at that position there.
    ///
    /// - Parameter edge: what the capsule hangs from (a top position) or
    ///   stands on (a bottom one). The container's own safe area edge unless
    ///   told otherwise.
    static func present(
        _ message: String,
        detail: String? = nil,
        symbol: String?,
        style: Style,
        action: Action? = nil,
        position: ToastPosition,
        in container: UIView,
        edge: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        let tag = hostTag + position.rawValue
        container.viewWithTag(tag).flatMap { $0 as? ToastView }?.dismiss(animated: false)

        let toast = ToastView(
            message: message, detail: detail, symbol: symbol, style: style, action: action,
            duration: duration(
                for: style, message: message, detail: detail, hasAction: action != nil,
                assistiveTechnologyRunning: isAssistiveTechnologyRunning()
            )
        )
        toast.tag = tag
        toast.position = position
        let reduces = MotionPreference.reducesMotion
        let slide: NSLayoutConstraint
        if position.isTop {
            toast.restConstant = Metrics.bottomGap
            toast.offConstant = reduces ? toast.restConstant : Metrics.bottomGap - Metrics.travel
            slide = toast.topAnchor.constraint(
                equalTo: edge ?? container.safeAreaLayoutGuide.topAnchor, constant: toast.offConstant
            )
        } else {
            toast.restConstant = -Metrics.bottomGap
            toast.offConstant = reduces ? toast.restConstant : -Metrics.bottomGap + Metrics.travel
            slide = toast.bottomAnchor.constraint(
                equalTo: edge ?? container.safeAreaLayoutGuide.bottomAnchor, constant: toast.offConstant
            )
        }
        toast.slide = slide
        let margins = container.layoutMarginsGuide
        let along: NSLayoutConstraint = switch position.alignment {
        case .leading: toast.leadingAnchor.constraint(equalTo: margins.leadingAnchor)
        case .center: toast.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        case .trailing: toast.trailingAnchor.constraint(equalTo: margins.trailingAnchor)
        }
        toast.along = along
        // The margins hold, above the labels' compression resistance (they
        // wrap at the margins, not before) — except while a swipe carries the
        // toast past them (`swiped`).
        let keepsLeading = toast.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor)
        let keepsTrailing = toast.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor)
        keepsLeading.priority = .required - 1
        keepsTrailing.priority = .required - 1
        toast.marginConstraints = [keepsLeading, keepsTrailing]
        toast.constrain(in: container) { _ in
            along
            slide
            // Never wider than the container, however long the message.
            keepsLeading
            keepsTrailing
        }
        toast.animateIn()
        return toast
    }

    // MARK: - Time

    /// How long a toast stays up, in seconds; nil: until it is closed, acted
    /// on or replaced (see the type doc).
    public static func duration(
        for style: Style, message: String, detail: String?, hasAction: Bool,
        assistiveTechnologyRunning: Bool
    ) -> TimeInterval? {
        if style == .failure { return nil }
        if hasAction, assistiveTechnologyRunning { return nil }
        let words = ([message] + (detail.map { [$0] } ?? []))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count
        return max(4, 2 + 0.3 * Double(words))
    }

    /// VoiceOver or Switch Control. Swappable for tests.
    static var isAssistiveTechnologyRunning: () -> Bool = {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    // MARK: - VoiceOver

    /// What VoiceOver is handed: the message, as a QUEUED announcement, with
    /// a high priority for a failure.
    ///
    /// ⚠️ QUEUED, AND POSTED ON THE NEXT RUN LOOP. A toast usually follows a
    /// menu row (Copy, Mute, Report): posted at once from `init`, the
    /// announcement competed with the context menu's own dismissal and was
    /// dropped. Queued behind whatever VoiceOver is saying, a turn later, it
    /// is heard.
    static func announcement(_ message: String, style: Style = .confirmation) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .accessibilitySpeechQueueAnnouncement: true,
            .accessibilitySpeechAnnouncementPriority: style == .failure
                ? UIAccessibilityPriority.high : UIAccessibilityPriority.default,
        ])
    }

    private static func announce(_ message: String, style: Style) {
        // A task, so it runs on a LATER turn of the main actor, never inline.
        Task { @MainActor in
            UIAccessibility.post(notification: .announcement, argument: announcement(message, style: style))
        }
    }

    public override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    public override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        countdown?.hold(.voiceOverFocus)
    }

    public override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        countdown?.release(.voiceOverFocus)
    }

    // MARK: - Building

    private init(
        message: String, detail: String?, symbol: String?, style: Style, action: Action?,
        duration: TimeInterval?
    ) {
        self.style = style
        self.message = message
        self.detail = detail
        self.action = action
        self.duration = duration
        actionButton = action.map { Self.makeActionButton(title: $0.title) }
        // Something has to close a toast that does not leave on its own.
        closeButton = action == nil && duration == nil ? Self.makeCloseButton() : nil
        super.init(frame: .zero)
        // Announced rather than read on focus: the user's attention is on what
        // they just did.
        Self.announce([message, detail].compactMap { $0 }.joined(separator: ". "), style: style)

        // The capsule's shape is driven by the corner CONFIGURATION, not a
        // layer radius: the glass renders its own boundary refraction against
        // that shape, and a layer radius would clip a material that doesn't
        // know it has been clipped. `.capsule()` keeps the ends circular at
        // any height Dynamic Type resolves to. No border of our own: the
        // glass draws its own specular edge.
        backdrop.clipsToBounds = true
        backdrop.cornerConfiguration = .capsule()
        backdrop.pin(to: self)

        let title = UILabel()
        title.text = message
        title.font = .appFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        // Adaptive colors over an adaptive material: `UIGlassEffect` resolves
        // its own luminance against whatever it sits over, so the label tracks
        // it in both appearances without a hand-picked color.
        title.textColor = .label
        title.numberOfLines = 2
        let texts = UIStackView(arrangedSubviews: [title])
        texts.axis = .vertical
        texts.spacing = 2
        if let detail {
            let line = UILabel()
            line.text = detail
            line.font = .appFont(forTextStyle: .footnote)
            line.adjustsFontForContentSizeCategory = true
            line.textColor = .secondaryLabel
            line.numberOfLines = 2
            texts.addArrangedSubview(line)
        }

        var arranged: [UIView] = []
        if let symbol, let image = UIImage(systemName: symbol) {
            let glyph = UIImageView(image: image)
            glyph.tintColor = style.glyphTint
            glyph.contentMode = .scaleAspectFit
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(glyph)
        }
        arranged.append(texts)
        if let actionButton {
            actionButton.addAction(UIAction { [weak self] _ in self?.runAction() }, for: .primaryActionTriggered)
            arranged.append(actionButton)
        }
        if let closeButton {
            closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
            arranged.append(closeButton)
        }

        row.addArrangedSubviews(arranged)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        // Ordinary content, so alpha is the right lever here — the rule the
        // type doc cites is about the effect view, not what rides inside it.
        row.alpha = 0
        let trailing = actionButton != nil || closeButton != nil ? Spacing.sm : Spacing.lg
        row.constrain(in: backdrop.contentView) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.md)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.md)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -trailing)
        }
        rowInsets = Spacing.lg + trailing
        textLabels = texts.arrangedSubviews.compactMap { $0 as? UILabel }
        // ⚠️ THE WIDTH IS MEASURED, NOT LEFT TO THE LABELS. Two-line labels
        // in a stack give Auto Layout no width of their own: the bubble came
        // out narrow and wrapped "Couldn't send" over two lines with the
        // screen's width to spare. It asks for its one-line width, above the
        // labels' compression resistance and below the margins — so the text
        // wraps only where the margins stop it.
        idealWidth.priority = .defaultHigh + 10
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight),
            widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumWidth),
            idealWidth,
        ])
        measureIdealWidth()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (toast: ToastView, _) in
            toast.measureIdealWidth()
        }

        // The shadow lives on self, never on the backdrop: that view clips to
        // its capsule, and a clipping view cannot cast a shadow.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        // One element for VoiceOver: the text, the action, the escape.
        isAccessibilityElement = true
        accessibilityLabel = [message, detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .staticText
        var actions: [UIAccessibilityCustomAction] = []
        if let action {
            actions.append(UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                self?.runAction()
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: "Dismiss") { [weak self] _ in
            self?.dismiss(animated: true)
            return true
        })
        accessibilityCustomActions = actions

        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        addGestureRecognizer(pan)
        if action != nil {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        if let duration {
            countdown = ToastCountdown(seconds: duration, clock: ToastClock.current) { [weak self] in
                self?.dismiss(animated: true)
            }
        }
    }

    private static func makeActionButton(title: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
            return attributes
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let button = UIButton(configuration: configuration)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private static func makeCloseButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Dismiss"
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Measures the row with its text on one line.
    private func measureIdealWidth() {
        textLabels.forEach { $0.numberOfLines = 1 }
        let width = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        textLabels.forEach { $0.numberOfLines = 2 }
        idealWidth.constant = ceil(width + rowInsets)
    }


    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Materialized on window attach, never in init: building a real effect
        // off-screen contacts the render server and stalls the main actor for
        // tens of seconds on headless CI simulators (the rule `CommentsInputBar`
        // and `InboxCategoryBar` both follow).
        //
        // Only the FIRST attach seeds it; from then on `animateIn`/`dismiss`
        // own the effect, and re-seeding here would refill a capsule that is
        // deliberately mid-dissolve.
        guard window != nil else { return }
        observeScene()
        guard !hasMaterialized else { return }
        hasMaterialized = true
        backdrop.effect = Self.makeGlass()
    }

    private var hasMaterialized = false

    /// Regular glass — the system's floating-chrome material — and
    /// INTERACTIVE: it flexes under the finger, as the toast takes touches.
    private static func makeGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Trace the shadow onto the capsule the corner configuration actually
        // resolved, rather than assuming height/2 — `.capsule()` clamps itself
        // on very short or very wide bounds.
        let radius = backdrop.effectiveRadius(corner: .allCorners)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    // MARK: - The scene

    /// Holds the countdown while the scene is inactive: a toast never runs
    /// out unseen in the app switcher.
    private func observeScene() {
        guard sceneObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for (name, inactive) in [
            (UIScene.willDeactivateNotification, true),
            (UIScene.didActivateNotification, false),
        ] {
            sceneObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let scene = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, scene != nil, scene == self.window?.windowScene.map(ObjectIdentifier.init) else { return }
                    if inactive { self.countdown?.hold(.sceneInactive) } else { self.countdown?.release(.sceneInactive) }
                }
            })
        }
    }

    private func stopObservingScene() {
        sceneObservers.forEach(NotificationCenter.default.removeObserver)
        sceneObservers = []
    }

    // MARK: - Touch

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        countdown?.hold(.touch)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        countdown?.release(.touch)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        // A pan that recognised cancels the touches; it holds on its own.
        if !isSwiping { countdown?.release(.touch) }
    }

    @objc private func tapped() {
        runAction()
    }

    private func runAction() {
        guard let action, !isLeaving else { return }
        action.handler()
        dismiss(animated: true)
    }

    private var isSwiping = false

    /// Which way a swipe dismisses: toward the toast's own edge, and toward
    /// its side for a leading or trailing one (in screen terms: right to
    /// left flips the side).
    struct SwipeDirections: Equatable {
        /// +1 down, -1 up.
        var vertical: CGFloat
        /// +1 right, -1 left, 0 none.
        var horizontal: CGFloat
    }

    static func swipeDirections(for position: ToastPosition, rightToLeft: Bool) -> SwipeDirections {
        let vertical: CGFloat = position.isTop ? -1 : 1
        let side: CGFloat = switch position.alignment {
        case .leading: -1
        case .center: 0
        case .trailing: 1
        }
        return SwipeDirections(vertical: vertical, horizontal: rightToLeft ? -side : side)
    }

    /// How far the toast follows a pull of `distance` along an axis whose
    /// dismissing direction is `direction` (±1; 0: no dismissal that way):
    /// all the way toward it, a stretching fraction the other way.
    static func followed(_ distance: CGFloat, direction: CGFloat) -> CGFloat {
        if direction != 0, distance * direction > 0 { return distance }
        let limit = Metrics.rubberBandLimit
        let stretched = (1 - 1 / (abs(distance) / limit * 0.55 + 1)) * limit
        return distance < 0 ? -stretched : stretched
    }

    /// Whether a swipe that ended at `translation` with `velocity` dismisses.
    static func dismisses(translation: CGPoint, velocity: CGPoint, directions: SwipeDirections) -> Bool {
        let towardY = translation.y * directions.vertical
        let speedY = velocity.y * directions.vertical
        if towardY > Metrics.dismissDistance || speedY > Metrics.dismissVelocity { return true }
        guard directions.horizontal != 0 else { return false }
        let towardX = translation.x * directions.horizontal
        let speedX = velocity.x * directions.horizontal
        return towardX > Metrics.dismissDistance || speedX > Metrics.dismissVelocity
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        guard !isLeaving, let container = superview else { return }
        let directions = Self.swipeDirections(
            for: position, rightToLeft: container.effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        let translation = pan.translation(in: container)
        switch pan.state {
        case .began:
            isSwiping = true
            countdown?.hold(.touch)
            NSLayoutConstraint.deactivate(marginConstraints)
        case .changed:
            slide?.constant = restConstant + Self.followed(translation.y, direction: directions.vertical)
            along?.constant = alongSign * Self.followed(translation.x, direction: directions.horizontal)
        case .ended, .cancelled, .failed:
            isSwiping = false
            let velocity = pan.velocity(in: container)
            if pan.state == .ended, Self.dismisses(translation: translation, velocity: velocity, directions: directions) {
                leaveBySwipe(translation: translation, directions: directions)
            } else {
                countdown?.release(.touch)
                slide?.constant = restConstant
                along?.constant = 0
                NSLayoutConstraint.activate(marginConstraints)
                UIView.animate(
                    withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    container.layoutIfNeeded()
                }
            }
        default:
            break
        }
    }

    /// Screen points to `along`'s constant: a leading or trailing anchor's
    /// constant grows toward the trailing side, which is the LEFT in a
    /// right-to-left layout — the swipe works in screen points.
    private var alongSign: CGFloat {
        position.alignment != .center && effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    }

    /// Carries the toast off the way it was swiped, dissolving the glass.
    private func leaveBySwipe(translation: CGPoint, directions: SwipeDirections) {
        let sideways = directions.horizontal != 0 && abs(translation.x) > abs(translation.y)
        if sideways {
            along?.constant = alongSign * directions.horizontal * (bounds.width + Metrics.bottomGap)
        } else {
            slide?.constant = restConstant + directions.vertical * (bounds.height + Metrics.bottomGap)
        }
        leave(animated: true, moving: false)
    }

    // MARK: - Arrival and departure

    private func animateIn() {
        // Land the pre-entrance state before animating: the capsule sits one
        // `travel` out, with no glass and no shadow to inherit.
        superview?.layoutIfNeeded()
        slide?.constant = restConstant
        UIView.animate(
            withDuration: Metrics.transitionDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]
        ) {
            // Layout drives the slide, so the material re-renders in place
            // each frame instead of being carried as a stale image.
            self.superview?.layoutIfNeeded()
            self.backdrop.effect = Self.makeGlass()
            self.row.alpha = 1
            // A CALayer property set inside a UIView animation block adopts
            // that block's timing, so the shadow arrives with the capsule
            // instead of snapping on at frame 0.
            self.layer.shadowOpacity = Metrics.shadowOpacity
        }
        countdown?.start()
    }

    /// Takes the toast away — animated: it slides back out (none under
    /// Reduce Motion) while the glass dissolves.
    func dismiss(animated: Bool) {
        leave(animated: animated, moving: true)
    }

    private func leave(animated: Bool, moving: Bool) {
        guard !isLeaving else { return }
        isLeaving = true
        countdown?.cancel()
        stopObservingScene()
        // The outgoing toast must stop answering `viewWithTag` immediately, or
        // a replacement arriving mid-fade would find and re-dismiss it.
        tag = 0
        isUserInteractionEnabled = false
        guard animated else {
            finish()
            return
        }
        // Settle whatever the container has pending BEFORE the exit animates —
        // the same line `animateIn` has, for the same reason: this can fire
        // from a timer, on whatever the container holds by then, and a view
        // installed in the meantime that has not had its first pass would take
        // it inside the block below, growing out of the top-left corner.
        if moving {
            superview?.layoutIfNeeded()
            slide?.constant = offConstant
        }
        UIView.animate(withDuration: Metrics.transitionDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.superview?.layoutIfNeeded()
            // Dissolving the effect is how glass leaves; fading the view would
            // put group opacity on the effect view (see the type doc).
            self.backdrop.effect = nil
            self.row.alpha = 0
            // Without this the capsule dissolves and leaves its shadow behind
            // as a grey smear for the length of the exit.
            self.layer.shadowOpacity = 0
        } completion: { _ in
            self.finish()
        }
    }

    private func finish() {
        removeFromSuperview()
        let removed = onRemoved
        onRemoved = nil
        removed?()
    }
}

private extension UIStackView {
    func addArrangedSubviews(_ views: [UIView]) {
        views.forEach(addArrangedSubview)
    }
}
