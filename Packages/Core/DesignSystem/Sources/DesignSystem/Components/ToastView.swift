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
/// ONE LINE (#1034): a glyph (the kind's, or the caller's), a short message
/// — tail-truncated, two lines only at accessibility text sizes — and in the
/// trailing slot ONE of: an action ("Retry", "View", Undo) or a close button,
/// the close button whenever the toast does not leave on its own (a failure).
/// No second text line: one idea per toast, the references' rule (Polaris,
/// Material's snackbar, Avaya); two levels made it too big (owner, #1034).
///
/// A toast with an action spans the margins (capped at `maximumWidth`), its
/// control flush with the trailing edge; without one, the capsule hugs its
/// text. 48 pt tall with an action, 44 pt without.
///
/// ## Time (`duration(for:message:hasAction:assistiveTechnologyRunning:)`)
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
/// So the "scale" in and out (#1034) is a MORPH through layout: the capsule
/// arrives at `Metrics.morphScale` of its size and springs to it (a slight
/// overshoot) while it slides in, the glass materialises and the content —
/// ordinary content, where a transform is fine — fades and scales up from
/// `contentScale`. It leaves the same way back, shorter and without the
/// bounce. The content keeps its own size during the morph (centred, clipped
/// by the capsule), so the text never re-wraps or truncates mid-flight.
///
/// Under Reduce Motion (`MotionPreference`) there is no slide, no morph and
/// no scale: the glass materialises and the row fades, in place.
@MainActor
public final class ToastView: UIView {

    /// The ink a toast's glyph is drawn in: a glyph with a colour of its own
    /// keeps it — the Points heart its pink, the saved star its gold (#1190:
    /// a like's toast drew its heart in the label's ink) — on a toast that
    /// says things went well; any other glyph takes the style's ink.
    static func glyphTint(symbol: String, style: Style) -> UIColor {
        guard style == .confirmation else { return style.glyphTint }
        switch symbol {
        case PointsSymbol.glyph: return PointsSymbol.tint
        case SaveStar.glyph: return SaveStar.tint
        default: return style.glyphTint
        }
    }
    enum Metrics {
        /// Gap between the capsule and the edge it stands on (or hangs from).
        static let bottomGap: CGFloat = Spacing.lg
        /// How far the capsule travels on entrance/exit.
        static let travel: CGFloat = 24
        static let transitionDuration: TimeInterval = 0.32
        /// The entrance's spring (#1034): the capsule grows from
        /// `morphScale` of its size and overshoots a little.
        static let entranceDuration: TimeInterval = 0.55
        static let entranceDamping: CGFloat = 0.72
        /// The exit: shorter, no bounce.
        static let exitDuration: TimeInterval = 0.26
        /// The capsule's size before it arrives and as it leaves, against its
        /// own — reached through its CONSTRAINTS, never a transform on glass.
        static let morphScale = CGSize(width: 0.7, height: 0.85)
        /// The content's scale on the way in and out (ordinary content: a
        /// transform is fine there).
        static let contentScale: CGFloat = 0.9
        /// A bar item toast (#1058): its height inside the bar's platter, and
        /// its row's leading inset there.
        static let barHeight: CGFloat = 36
        static let barInset: CGFloat = 10
        /// Resting shadow strength. Soft and low-contrast: the glass already
        /// separates itself; the shadow only grounds it.
        static let shadowOpacity: Float = 0.22
        /// The height of a toast without an action — the touch target's
        /// floor — and with one (#1034), at the default text size.
        static let minimumHeight: CGFloat = 44
        static let actionHeight: CGFloat = 48
        /// Between the glyph and the message, and between the message and
        /// the trailing control (#1034: ≥ 16 pt, the references' gap).
        static let glyphGap: CGFloat = 10
        static let controlGap: CGFloat = Spacing.lg
        /// Never wider than this, however wide the screen (iPad).
        static let maximumWidth: CGFloat = 420
        /// A swipe toward the edge dismisses past this distance…
        static let dismissDistance: CGFloat = 44
        /// …or this speed (points per second).
        static let dismissVelocity: CGFloat = 500
        /// How far a pull the wrong way can stretch, at most.
        static let rubberBandLimit: CGFloat = 24
    }

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
        /// without its sound"). The glyph takes the system yellow.
        case warning
        /// Under way ("Posting…"): a spinner instead of a glyph, until the
        /// same `id` updates it to its outcome.
        case loading

        /// The style's own ink for a glyph — see `ToastView.glyphTint(symbol:style:)`
        /// for the glyphs that carry their colour.
        var glyphTint: UIColor {
            switch self {
            case .confirmation, .loading: .label
            case .failure: .systemRed
            // Yellow, not orange (#1124): orange is the brand's tint now,
            // and a warning in it would read as a button.
            case .warning: Warning.glyphTint
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

    /// An action the toast COMMITS when it leaves, unless the viewer undoes
    /// it first (#954): `commit` and `undo`, exactly one of which runs, once.
    ///
    /// Either model fits: a deferred commit (`commit` sends it — nothing has
    /// gone out yet, like Undo Send) or an optimistic one (it is already done;
    /// `commit` confirms it and `undo` sends the compensating call).
    ///
    /// It commits when its time runs out, when it is closed, swiped away or
    /// replaced, when another undoable toast arrives (one undo slot), and at
    /// once when the app goes to the background. Leaving the screen does not
    /// commit it: the toast is the scene's, not the screen's.
    public struct Undoable {
        public let commit: @MainActor () -> Void
        public let undo: @MainActor () -> Void

        public init(commit: @escaping @MainActor () -> Void, undo: @escaping @MainActor () -> Void) {
            self.commit = commit
            self.undo = undo
        }
    }

    /// How an undoable toast was settled.
    enum Resolution: Equatable {
        case committed, undone
    }

    /// Everything a toast shows and does — what an update by `id` replaces.
    @MainActor
    struct Content {
        var message: String
        var symbol: String?
        var style: Style
        var action: Action?
        var undoable: Undoable?
        var duration: TimeInterval?
        /// What identifies it for an update or a repeat: the caller's `id`,
        /// or else its style and words.
        var key: String
        /// A CONDITION ("Offline", #955): it stays, with no close button,
        /// until the same `id` says the condition has cleared; it takes
        /// priority over the plain confirmations at its position, and nothing
        /// preempts it.
        var isCondition = false

        init(
            message: String, symbol: String?, style: Style, action: Action?,
            undoable: Undoable?, id: String?, isCondition: Bool = false
        ) {
            self.isCondition = isCondition
            self.message = message
            self.symbol = symbol
            self.style = style
            // Undo IS the toast's action: the trailing control, a tap on the
            // bubble, and VoiceOver's custom action.
            self.action = undoable != nil ? Action("Undo") {} : action
            self.undoable = undoable
            duration = ToastView.duration(
                for: style, message: message, hasAction: action != nil || undoable != nil,
                isUndoable: undoable != nil, assistiveTechnologyRunning: ToastView.isAssistiveTechnologyRunning()
            )
            key = id ?? "\(style)|\(message)"
            if isCondition { duration = nil }
        }
    }

    private(set) var content: Content
    /// The style this toast was drawn in (read by tests).
    public var style: Style { content.style }
    /// Its one line of text.
    public var message: String { content.message }
    /// Where the toast sits (#954).
    public private(set) var position: ToastPosition = .bottom
    /// How long it stays up, in seconds; nil: until closed (`duration`).
    public var duration: TimeInterval? { content.duration }
    var action: Action? { content.action }
    var undoable: Undoable? { content.undoable }
    /// Once settled, never again.
    private(set) var resolution: Resolution?
    /// The undoable toast on screen, if any: a second one commits it (one
    /// undo slot) — wherever it is drawn (`NavigationBarToasts` too).
    static weak var pendingUndo: ToastView?

    /// Where the toast is drawn.
    enum Chrome {
        /// Its own glass capsule, in the scene's overlay (the default).
        case capsule
        /// A navigation bar item's content (#1058, `-toast-in-navbar`): the
        /// bar's own platter is the glass, so no capsule, shadow, slide or
        /// swipe; `NavigationBarToasts` places it, sizes it and takes it away.
        case barItem
    }
    let chrome: Chrome
    /// Bar items only: glyph alone, a perfect bubble, when the bar has no
    /// room for its text (`NavigationBarToasts`).
    var isCollapsedInBar = false {
        didSet {
            guard isCollapsedInBar != oldValue else { return }
            row.arrangedSubviews.dropFirst(hasGlyph ? 1 : 0).forEach { $0.isHidden = isCollapsedInBar }
            // The glyph alone sits at the bubble's exact centre (owner,
            // #1058), not at the expanded row's leading inset.
            collapsedCentre.isActive = isCollapsedInBar
        }
    }
    /// Centres the row — the glyph alone — in a collapsed bar item; required,
    /// over the row's edges (`.required - 1`).
    private lazy var collapsedCentre = row.centerXAnchor.constraint(equalTo: backdrop.contentView.centerXAnchor)
    /// Bar items only: what the bar is told — it left, a collapsed one was
    /// tapped, its content changed (its width may have).
    var onBarLeave: ((ToastView) -> Void)?
    var onBarTap: ((ToastView) -> Void)?
    var onBarContentChange: ((ToastView) -> Void)?
    /// Left the window while still up: its screen may have been pushed over
    /// or popped (`NavigationBarToasts` follows the screen on top).
    var onBarDetached: ((ToastView) -> Void)?
    /// Bar items only: its row's width with the text on one line.
    private(set) var barIdealWidth: CGFloat = 0
    private var hasGlyph = false

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
    /// The slide's resting constant for the front of the stack…
    private var baseConstant: CGFloat = 0
    /// …and for this toast where it stands in it (`restack`).
    private var restConstant: CGFloat = 0
    private var offConstant: CGFloat = 0
    /// Pins the capsule along its edge; the sideways swipe moves it.
    private var along: NSLayoutConstraint?
    /// Keep it between the container's margins; off while a swipe moves it.
    private var marginConstraints: [NSLayoutConstraint] = []
    /// Its size and place behind the front toast, while it is collapsed
    /// there (`restack`).
    private var stackLocks: [NSLayoutConstraint] = []
    /// Behind the front toast, its content hidden.
    private(set) var isCollapsedBehind = false {
        didSet { accessibilityElementsHidden = isCollapsedBehind }
    }
    /// Its entrance has begun: from then on `restack` moves it.
    private var hasArrived = false
    /// The bubble's one-line width (`measureIdealWidth`).
    private lazy var idealWidth = widthAnchor.constraint(equalToConstant: 0)
    private var rowInsets: CGFloat = 0
    private var textLabels: [UILabel] = []
    /// The text's own vertical inset, rebuilt with the label (#1034).
    private var textInset: NSLayoutConstraint?
    /// Below required: the entrance/exit morph squeezes the capsule past it.
    private lazy var minimumHeightConstraint: NSLayoutConstraint = {
        let constraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight)
        constraint.priority = .required - 1
        return constraint
    }()
    /// The capsule's size and the content's while it morphs in or out.
    private var morphConstraints: [NSLayoutConstraint] = []
    private let row = UIStackView()
    private(set) var closeButton: UIButton?
    private(set) var actionButton: UIButton?
    /// An undoable toast's trailing control: the ring and "Undo".
    private(set) var undoButton: ToastUndoButton?
    private var rowTrailing: NSLayoutConstraint?
    private var isLeaving = false
    private var sceneObservers: [NSObjectProtocol] = []

    /// The glass view (tests).
    var glassView: UIVisualEffectView { backdrop }
    /// How far the capsule slides on its way in: zero under Reduce Motion
    /// (tests, here and in the packages that show toasts).
    public var entranceTravel: CGFloat { abs(offConstant - restConstant) }
    /// Whether it is on its way out — what a stake surface reads to know its
    /// undo window is still open (#1375), and tests.
    public var isDismissing: Bool { isLeaving }

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
            message, symbol: symbol, style: style, action: nil, position: .bottom, in: host,
            edge: floor ?? host.safeAreaLayoutGuide.bottomAnchor
        )
    }

    /// Shows a toast at `position` in `container` (#954):
    /// - the same toast again — the same `id`, or with none the same style
    ///   and words — UPDATES the one up there in place (a loading toast turns
    ///   into its outcome; a repeat restarts its time) instead of stacking;
    /// - a failure PREEMPTS the plain confirmations up at its position;
    /// - otherwise it goes in front of the position's STACK, at most
    ///   `maximumStack` visible, the oldest leaving first.
    ///
    /// - Parameter edge: what the capsule hangs from (a top position) or
    ///   stands on (a bottom one). The container's own safe area edge unless
    ///   told otherwise.
    static func present(
        _ message: String,
        symbol: String?,
        style: Style,
        action: Action? = nil,
        undoable: Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        position: ToastPosition,
        in container: UIView,
        edge: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        let content = Content(
            message: message, symbol: symbol, style: style, action: action,
            undoable: undoable, id: id, isCondition: isCondition
        )
        let existing = stack(at: position, in: container).last { $0.content.key == content.key }
        // One undo slot: a second undoable action commits the first at once
        // (unless it is the same toast, being updated).
        if undoable != nil, let pending = pendingUndo, pending !== existing {
            pending.dismiss(animated: true)
        }
        if let existing {
            existing.update(to: content)
            return existing
        }
        // A failure, or a condition, preempts the plain confirmations there —
        // never an undo, which must be settled, nor a condition.
        if style == .failure || isCondition {
            for toast in stack(at: position, in: container)
            where toast.style == .confirmation && toast.undoable == nil && !toast.content.isCondition {
                toast.dismiss(animated: true)
            }
        }

        let toast = ToastView(content: content)
        if undoable != nil { pendingUndo = toast }
        toast.position = position
        let reduces = MotionPreference.reducesMotion
        let slide: NSLayoutConstraint
        if position.isTop {
            toast.baseConstant = Metrics.bottomGap
            toast.offConstant = reduces ? toast.baseConstant : Metrics.bottomGap - Metrics.travel
            slide = toast.topAnchor.constraint(
                equalTo: edge ?? container.safeAreaLayoutGuide.topAnchor, constant: toast.offConstant
            )
        } else {
            toast.baseConstant = -Metrics.bottomGap
            toast.offConstant = reduces ? toast.baseConstant : -Metrics.bottomGap + Metrics.travel
            slide = toast.bottomAnchor.constraint(
                equalTo: edge ?? container.safeAreaLayoutGuide.bottomAnchor, constant: toast.offConstant
            )
        }
        toast.restConstant = toast.baseConstant
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
        // The ones behind it step back before it arrives — and into a spread
        // stack it arrives held, like the others.
        if isSpread(at: position, in: container) { toast.countdown?.hold(.spread) }
        restack(at: position, in: container, animated: true)
        toast.animateIn()
        return toast
    }

    /// A toast drawn as a navigation bar item's content (#1058), for
    /// `NavigationBarToasts`.
    static func makeForBar(_ content: Content) -> ToastView {
        let toast = ToastView(content: content, chrome: .barItem)
        // It is at the top of the screen, in its bar.
        toast.position = .top
        toast.measureIdealWidth()
        return toast
    }

    /// Bar items only: the size the bar gave it, as REQUIRED constraints —
    /// a frame alone loses to the row's own fitting width, which UIKit reads
    /// and then sweeps the item into `•••` (#1058). The text gives way.
    private var barSize: [NSLayoutConstraint] = []

    func sizeInBar(width: CGFloat) {
        NSLayoutConstraint.deactivate(barSize)
        barSize = [
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Metrics.barHeight),
        ]
        NSLayoutConstraint.activate(barSize)
        frame = CGRect(x: 0, y: 0, width: width, height: Metrics.barHeight)
    }

    /// Starts a bar item toast's time — its arrival is the bar's.
    func startInBar() {
        hasArrived = true
        countdown?.start()
    }

    /// Replaces this toast's content in place: a loading toast becomes its
    /// outcome, a repeat restarts its time. Brought to the front of its stack.
    func update(to content: Content) {
        guard !isLeaving else { return }
        // A change away from an unsettled undo commits it first: the action
        // it stood for must not be lost with its toast.
        if undoable != nil, resolution == nil { resolve(.committed) }
        resolution = nil
        if Self.pendingUndo === self, content.undoable == nil { Self.pendingUndo = nil }
        if content.undoable != nil { Self.pendingUndo = self }
        if chrome == .capsule { superview?.bringSubviewToFront(self) }
        UIView.transition(with: row, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.apply(content)
        }
        if chrome == .barItem {
            onBarContentChange?(self)
        } else if let container = superview {
            Self.restack(at: position, in: container, animated: true)
        }
        countdown?.start()
        Self.announce(content.message, style: content.style)
    }

    // MARK: - The stack

    /// How many toasts one position shows at once.
    static let maximumStack = 3
    /// How far each toast behind the front one peeks out, and how much
    /// narrower it is on each side.
    static let stackPeek: CGFloat = 8
    static let stackInset: CGFloat = 10
    /// The gap between toasts when the stack is spread out.
    static let stackGap: CGFloat = Spacing.sm

    /// The toasts up at `position` in `container`, oldest first (the last is
    /// in front).
    static func stack(at position: ToastPosition, in container: UIView) -> [ToastView] {
        container.subviews.compactMap { $0 as? ToastView }.filter { $0.position == position && !$0.isLeaving }
    }

    /// The stacks that are spread out, by container and position.
    private static var spreadStacks: Set<String> = []

    private static func stackKey(_ position: ToastPosition, _ container: UIView) -> String {
        "\(ObjectIdentifier(container).hashValue)-\(position.rawValue)"
    }

    /// Whether the stack at `position` is spread out (tests).
    static func isSpread(at position: ToastPosition, in container: UIView) -> Bool {
        spreadStacks.contains(stackKey(position, container))
    }

    /// Spreads the stack out — every toast readable, one above the other —
    /// or collapses it back behind its front toast. Spread, their time is
    /// held: the viewer is reading them.
    static func setSpread(_ spread: Bool, at position: ToastPosition, in container: UIView) {
        let key = stackKey(position, container)
        guard spread != spreadStacks.contains(key) else { return }
        if spread { spreadStacks.insert(key) } else { spreadStacks.remove(key) }
        for toast in stack(at: position, in: container) {
            if spread { toast.countdown?.hold(.spread) } else { toast.countdown?.release(.spread) }
        }
        restack(at: position, in: container, animated: true)
    }

    /// Lays the stack at `position` out: the front toast at its place, the
    /// ones behind it peeking out narrower above it (below it for a top
    /// position), their content hidden — or, spread, all of them one above
    /// the other. Never a transform: constraints, as for the slide.
    static func restack(at position: ToastPosition, in container: UIView, animated: Bool) {
        var toasts = stack(at: position, in: container)
        // The oldest leave first past the limit — failures included.
        while toasts.count > maximumStack {
            toasts.removeFirst().dismiss(animated: animated)
        }
        // A lone toast is never spread: fold back, and let its time run.
        if toasts.count < 2, spreadStacks.remove(stackKey(position, container)) != nil {
            toasts.forEach { $0.countdown?.release(.spread) }
        }
        let spread = isSpread(at: position, in: container)
        guard let front = toasts.last else { return }
        // Spread, each toast stands at its own height: free them all from
        // the front's size BEFORE measuring, or a two-line toast behind a
        // one-line front is measured one line tall and overlaps.
        if spread {
            for toast in toasts {
                NSLayoutConstraint.deactivate(toast.stackLocks)
                toast.stackLocks = []
                toast.along?.isActive = true
            }
        }
        container.layoutIfNeeded()
        let away: CGFloat = position.isTop ? 1 : -1
        var offset: CGFloat = 0
        for (depth, toast) in toasts.reversed().enumerated() {
            NSLayoutConstraint.deactivate(toast.stackLocks)
            toast.stackLocks = []
            if depth == 0 || spread {
                toast.restConstant = toast.baseConstant + away * offset
                toast.along?.isActive = true
                toast.isCollapsedBehind = false
                offset += toast.bounds.height + stackGap
            } else {
                // Behind: the front's size less an inset, peeking out.
                let inset = stackInset * CGFloat(depth)
                toast.restConstant = toast.baseConstant + away * stackPeek * CGFloat(depth)
                toast.along?.isActive = false
                toast.stackLocks = [
                    toast.widthAnchor.constraint(equalTo: front.widthAnchor, constant: -2 * inset),
                    toast.heightAnchor.constraint(equalTo: front.heightAnchor),
                    toast.centerXAnchor.constraint(equalTo: front.centerXAnchor),
                ]
                NSLayoutConstraint.activate(toast.stackLocks)
                toast.isCollapsedBehind = true
            }
            if toast.hasArrived { toast.slide?.constant = toast.restConstant }
        }
        let settle = {
            container.layoutIfNeeded()
            for toast in toasts where toast.hasArrived {
                toast.row.alpha = toast.isCollapsedBehind ? 0 : 1
            }
        }
        if animated, !MotionPreference.reducesMotion {
            UIView.animate(
                withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: settle
            )
        } else {
            settle()
        }
    }

    // MARK: - Time

    /// How long a toast stays up, in seconds; nil: until it is closed, acted
    /// on or replaced (see the type doc).
    public static func duration(
        for style: Style, message: String, hasAction: Bool,
        isUndoable: Bool = false, assistiveTechnologyRunning: Bool
    ) -> TimeInterval? {
        // A loading toast waits for its outcome (an update by `id`).
        if style == .failure || style == .loading { return nil }
        if hasAction, assistiveTechnologyRunning { return nil }
        if isUndoable { return undoDuration }
        let words = message.split(whereSeparator: \.isWhitespace).count
        return max(4, 2 + 0.3 * Double(words))
    }

    /// How long an undoable toast waits before it commits.
    public static let undoDuration: TimeInterval = 8

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

    private init(content: Content, chrome: Chrome = .capsule) {
        self.content = content
        self.chrome = chrome
        super.init(frame: .zero)

        // The capsule's shape is driven by the corner CONFIGURATION, not a
        // layer radius: the glass renders its own boundary refraction against
        // that shape, and a layer radius would clip a material that doesn't
        // know it has been clipped. `.capsule()` keeps the ends circular at
        // any height Dynamic Type resolves to. No border of our own: the
        // glass draws its own specular edge.
        backdrop.clipsToBounds = true
        backdrop.cornerConfiguration = .capsule()
        backdrop.pin(to: self)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        // Ordinary content, so alpha is the right lever here — the rule the
        // type doc cites is about the effect view, not what rides inside it.
        row.alpha = 0
        let trailing = row.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor)
        rowTrailing = trailing
        // Thin: the height is the toast's own (44/48 pt, #1034), and the
        // trailing control must not push it — the TEXT keeps its own inset
        // (`textInset`), which matters at large text sizes. Below required,
        // so the morph can hold the content at its size inside a smaller
        // capsule (`morph(to:)`).
        let edges = [
            row.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: Spacing.xs / 2),
            row.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor, constant: -Spacing.xs / 2),
            row.leadingAnchor.constraint(
                equalTo: backdrop.contentView.leadingAnchor, constant: chrome == .barItem ? Metrics.barInset : Spacing.lg
            ),
            trailing,
        ]
        edges.forEach { $0.priority = .required - 1 }
        row.translatesAutoresizingMaskIntoConstraints = false
        backdrop.contentView.addSubview(row)
        NSLayoutConstraint.activate(edges)
        // ⚠️ THE WIDTH IS MEASURED, NOT LEFT TO THE LABELS. Two-line labels
        // in a stack give Auto Layout no width of their own: the bubble came
        // out narrow and wrapped "Couldn't send" over two lines with the
        // screen's width to spare. It asks for its one-line width, above the
        // labels' compression resistance and below the margins — so the text
        // wraps only where the margins stop it.
        idealWidth.priority = .defaultHigh + 10
        if chrome == .capsule {
            NSLayoutConstraint.activate([
                minimumHeightConstraint,
                widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumWidth),
                idealWidth,
            ])
        } else {
            // In the bar from the first frame: no entrance of its own — the
            // bar's replace transition is the arrival.
            row.alpha = 1
        }
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
        accessibilityTraits = .staticText

        if chrome == .capsule {
            addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(swiped(_:))))
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        apply(content)
        // Announced rather than read on focus: the user's attention is on what
        // they just did.
        Self.announce(content.message, style: content.style)
    }

    /// Builds the row, the trailing control, VoiceOver's element and the
    /// countdown for `content` — at birth, and again for an update by `id`.
    private func apply(_ content: Content) {
        self.content = content
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = UILabel()
        title.text = content.message
        title.font = .appFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        // Adaptive colors over an adaptive material: `UIGlassEffect` resolves
        // its own luminance against whatever it sits over, so the label tracks
        // it in both appearances without a hand-picked color.
        title.textColor = .label
        title.numberOfLines = textLineCount
        title.lineBreakMode = .byTruncatingTail
        // The message takes the room the control leaves — with an action the
        // toast spans the margins and the control sits flush trailing — and
        // is the one thing that gives way.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = title

        var arranged: [UIView] = []
        hasGlyph = false
        if content.style == .loading {
            let spinner = AppLoaderView(size: .medium)
            spinner.startAnimating()
            arranged.append(spinner)
            // The leading mark a collapsed bar item keeps (#1058).
            hasGlyph = true
        } else if let symbol = content.symbol, let image = UIImage.symbol(named: symbol) {
            let tint = Self.glyphTint(symbol: symbol, style: content.style)
            // A glyph with a colour of its own carries it (`.alwaysOriginal`):
            // the toast's glass would wash a tinted template out to a pale
            // version of it (`sheet-glass-vibrancy-ink`).
            let ownsColour = tint != content.style.glyphTint
            let glyph = UIImageView(image: ownsColour ? image.withTintColor(tint, renderingMode: .alwaysOriginal) : image)
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
            glyph.tintColor = tint
            glyph.contentMode = .scaleAspectFit
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(glyph)
            hasGlyph = true
        }
        arranged.append(texts)

        undoButton = content.undoable != nil ? ToastUndoButton() : nil
        undoButton?.showsTitle = chrome == .capsule
        actionButton = content.undoable == nil ? content.action.map { Self.makeActionButton(title: $0.title) } : nil
        // Something has to close a toast that does not leave on its own — a
        // loading one leaves when its outcome replaces it.
        closeButton = content.action == nil && content.duration == nil && content.style != .loading
            && !content.isCondition ? Self.makeCloseButton() : nil
        if let actionButton {
            actionButton.addAction(UIAction { [weak self] _ in self?.runAction() }, for: .primaryActionTriggered)
            arranged.append(actionButton)
        }
        if let undoButton {
            undoButton.addAction(UIAction { [weak self] _ in self?.runAction() }, for: .primaryActionTriggered)
            arranged.append(undoButton)
        }
        if let closeButton {
            closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
            arranged.append(closeButton)
        }
        row.addArrangedSubviews(arranged)
        if let glyph = arranged.first, glyph !== texts { row.setCustomSpacing(Metrics.glyphGap, after: glyph) }
        row.setCustomSpacing(Metrics.controlGap, after: texts)
        minimumHeightConstraint.constant = content.action != nil ? Metrics.actionHeight : Metrics.minimumHeight
        textInset?.isActive = false
        if chrome == .capsule {
            textInset = heightAnchor.constraint(greaterThanOrEqualTo: title.heightAnchor, constant: 2 * Spacing.md)
            textInset?.priority = .required - 1
            textInset?.isActive = true
        }
        if chrome == .barItem, isCollapsedInBar {
            arranged.dropFirst(hasGlyph ? 1 : 0).forEach { $0.isHidden = true }
        }
        let hasControl = actionButton != nil || closeButton != nil || undoButton != nil
        let leading = chrome == .barItem ? Metrics.barInset : Spacing.lg
        let trailing = chrome == .barItem ? (hasControl ? Spacing.xs : Metrics.barInset) : (hasControl ? Spacing.sm : Spacing.lg)
        rowTrailing?.constant = -trailing
        rowInsets = leading + trailing
        textLabels = [title]
        measureIdealWidth()

        accessibilityLabel = content.message
        var actions: [UIAccessibilityCustomAction] = []
        if let action = content.action {
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

        countdown?.cancel()
        countdown = nil
        if let duration = content.duration {
            let countdown = ToastCountdown(seconds: duration, clock: ToastClock.current) { [weak self] in
                self?.dismiss(animated: true)
            }
            if let undoButton {
                countdown.onChange = { [weak undoButton, weak countdown] running, remaining in
                    undoButton?.follow(isRunning: running, remaining: remaining, total: countdown?.total ?? 0)
                }
            }
            self.countdown = countdown
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
        let floor = button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight)
        floor.priority = .required - 1 // a bar item (#1058) is shorter; its platter is the target
        floor.isActive = true
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

    /// One line; two at accessibility text sizes, where one would cut most
    /// of the message.
    private var textLineCount: Int {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    }

    /// The width it asks for: with an action, all the margins allow (capped
    /// at `maximumWidth`), so the control sits flush trailing (#1034);
    /// without one, its row with the text on one line.
    private func measureIdealWidth() {
        textLabels.forEach { $0.numberOfLines = textLineCount }
        if chrome == .barItem {
            // One line, always: the bar is one line high.
            textLabels.forEach { $0.numberOfLines = 1 }
            let collapsed = isCollapsedInBar
            if collapsed { row.arrangedSubviews.forEach { $0.isHidden = false } }
            barIdealWidth = ceil(row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + rowInsets)
            if collapsed { row.arrangedSubviews.dropFirst(hasGlyph ? 1 : 0).forEach { $0.isHidden = true } }
            return
        }
        if content.action != nil {
            idealWidth.constant = Metrics.maximumWidth
            return
        }
        textLabels.forEach { $0.numberOfLines = 1 }
        let width = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        textLabels.forEach { $0.numberOfLines = textLineCount }
        idealWidth.constant = ceil(width + rowInsets)
    }


    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Built before it had a window: the text size it was measured at may
        // not be the window's (one line, or two at accessibility sizes).
        if window != nil { measureIdealWidth() }
        if chrome == .barItem, window == nil, !isLeaving { onBarDetached?(self) }
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
        guard !hasMaterialized, chrome == .capsule else { return }
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
        guard chrome == .capsule else { return }
        let radius = backdrop.effectiveRadius(corner: .allCorners)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    // MARK: - The scene

    /// Holds the countdown while the scene is inactive: a toast never runs
    /// out unseen in the app switcher.
    private func observeScene() {
        guard sceneObservers.isEmpty else { return }
        let center = NotificationCenter.default
        if undoable != nil {
            sceneObservers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitForBackground() }
            })
        }
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

    /// A tap: on a stack still collapsed, it spreads the stack out (unless
    /// it lands on the front toast's action); on a toast with an action, it
    /// runs it; on a spread stack otherwise, it collapses it.
    @objc private func tapped() {
        if chrome == .barItem {
            guard !isLeaving else { return }
            if isCollapsedInBar { onBarTap?(self) } else if action != nil { runAction() }
            return
        }
        guard !isLeaving, let container = superview else { return }
        let count = Self.stack(at: position, in: container).count
        let spread = Self.isSpread(at: position, in: container)
        if isCollapsedBehind || (count > 1 && !spread && action == nil) {
            Self.setSpread(true, at: position, in: container)
        } else if action != nil {
            runAction()
        } else if spread {
            Self.setSpread(false, at: position, in: container)
        }
    }

    private func runAction() {
        guard let action, !isLeaving else { return }
        if undoable != nil {
            resolve(.undone)
        } else {
            action.handler()
        }
        dismiss(animated: true)
    }

    /// Settles an undoable toast, once: the first of commit and undo wins,
    /// and undo is refused once the commit has started.
    func resolve(_ how: Resolution) {
        guard let undoable, resolution == nil else { return }
        resolution = how
        if Self.pendingUndo === self { Self.pendingUndo = nil }
        switch how {
        case .committed: undoable.commit()
        case .undone: undoable.undo()
        }
    }

    /// The app is going to the background: an undoable toast commits now,
    /// inside a background task, and leaves.
    private func commitForBackground() {
        guard undoable != nil, resolution == nil else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask { application.endBackgroundTask(task) }
        resolve(.committed)
        dismiss(animated: false)
        if task != .invalid { application.endBackgroundTask(task) }
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
        guard !isLeaving, !isCollapsedBehind, let container = superview else { return }
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
        // `travel` out, with no glass and no shadow to inherit — and, laid
        // out at its real size first, squeezed to its morph size.
        superview?.layoutIfNeeded()
        let reduces = MotionPreference.reducesMotion
        if !reduces {
            morph(to: Metrics.morphScale)
            row.transform = CGAffineTransform(scaleX: Metrics.contentScale, y: Metrics.contentScale)
            superview?.layoutIfNeeded()
        }
        slide?.constant = restConstant
        hasArrived = true
        let arrive = {
            // Layout drives the slide and the morph, so the material
            // re-renders in place each frame instead of being carried as a
            // stale image.
            self.morph(to: nil)
            self.superview?.layoutIfNeeded()
            self.backdrop.effect = Self.makeGlass()
            self.row.alpha = 1
            self.row.transform = .identity
            // A CALayer property set inside a UIView animation block adopts
            // that block's timing, so the shadow arrives with the capsule
            // instead of snapping on at frame 0.
            self.layer.shadowOpacity = Metrics.shadowOpacity
        }
        if reduces {
            UIView.animate(
                withDuration: Metrics.transitionDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction],
                animations: arrive
            )
        } else {
            UIView.animate(
                withDuration: Metrics.entranceDuration, delay: 0, usingSpringWithDamping: Metrics.entranceDamping,
                initialSpringVelocity: 0, options: [.allowUserInteraction], animations: arrive
            )
        }
        countdown?.start()
    }

    /// Squeezes the capsule to `scale` of its current size through its
    /// constraints — never a transform on glass (see the type doc) — with the
    /// content held at its own size, centred and clipped; nil lets both go.
    private func morph(to scale: CGSize?) {
        NSLayoutConstraint.deactivate(morphConstraints)
        morphConstraints = []
        guard let scale, bounds.width > 0, stackLocks.isEmpty else { return }
        let content = backdrop.contentView
        morphConstraints = [
            widthAnchor.constraint(equalToConstant: bounds.width * scale.width),
            heightAnchor.constraint(equalToConstant: bounds.height * scale.height),
            row.widthAnchor.constraint(equalToConstant: row.bounds.width),
            row.heightAnchor.constraint(equalToConstant: row.bounds.height),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ]
        NSLayoutConstraint.activate(morphConstraints)
    }

    /// Takes the toast away — animated: it slides back out (none under
    /// Reduce Motion) while the glass dissolves.
    func dismiss(animated: Bool) {
        leave(animated: animated, moving: true)
    }

    private func leave(animated: Bool, moving: Bool) {
        guard !isLeaving else { return }
        isLeaving = true
        // Any way out but Undo commits: time, close, swipe, a replacement,
        // a second undoable toast, the background.
        resolve(.committed)
        countdown?.cancel()
        stopObservingScene()
        isUserInteractionEnabled = false
        if chrome == .barItem {
            // The bar takes the item away, with its own transition.
            onBarLeave?(self)
            let removed = onRemoved
            onRemoved = nil
            removed?()
            return
        }
        // The ones behind it move up as it leaves (it is out of the stack
        // already: `isLeaving`).
        if let container = superview {
            Self.restack(at: position, in: container, animated: animated)
        }
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
        let reduces = MotionPreference.reducesMotion
        UIView.animate(
            withDuration: reduces ? Metrics.transitionDuration : Metrics.exitDuration, delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            // The way it came, back: squeezed, its content shrinking — unless
            // it is collapsed behind another, whose size it is locked to.
            if !reduces, !self.isCollapsedBehind {
                self.morph(to: Metrics.morphScale)
                self.row.transform = CGAffineTransform(scaleX: Metrics.contentScale, y: Metrics.contentScale)
            }
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
