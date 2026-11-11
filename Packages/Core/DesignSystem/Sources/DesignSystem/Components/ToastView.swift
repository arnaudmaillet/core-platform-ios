import UIKit

/// A toast — the answer to actions whose only evidence is off-screen
/// ("Copied", "Report sent", "Couldn't follow @ava"). A floating, interactive
/// Liquid Glass bubble, in one place on every screen: just under the top bar
/// of the screen in view (#2143, `ToastAnchor`).
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
/// Toasts are self-owning: the caller fires and forgets. ONE result toast
/// shows at a time (#2143): a new one replaces the one up, and the same `id`
/// updates it in place. A CONDITION ("Offline") is its own line: it holds the
/// place, and a result fired meanwhile hangs just under it. `Feedback` draws
/// them in the scene's `ToastOverlay`; drawing in the screen itself is the
/// fallback for a window that is not the scene's key one (a package test
/// host's).
///
/// ## Content
///
/// ONE LINE (#1034): a glyph (the kind's, or the caller's), a short message
/// — tail-truncated, never wrapped, at every text size (#2143) — and in the
/// trailing slot ONE of: an action ("Retry", "View", Undo) or a close button,
/// the close button whenever the toast does not leave on its own and has no
/// action (none since #1448: a failure leaves on the common timer).
/// No second text line: one idea per toast, the references' rule (Polaris,
/// Material's snackbar, Avaya); two levels made it too big (owner, #1034).
///
/// The capsule HUGS its content, with an action or without (#2143, the
/// owner's device check: an action toast spanning the screen read as a
/// banner): glyph, text, then the action flush with its trailing edge — the
/// system pills' shape. It never grows past the margins or `maximumWidth`;
/// there the text truncates and the action stays whole. Before #2143 a toast
/// with an action spanned the margins (#1034); without one, it hugged its
/// text. 48 pt tall with an action, 44 pt without.
///
/// ## Time (`duration(for:message:hasAction:assistiveTechnologyRunning:)`)
///
/// - success, info, warning, failure: `max(4 s, 2 s + 0.3 s × words)` — a
///   failure on the same timer as the others (owner, 2026-10-19, #1448; it
///   replaces #954's "until closed": a failure that never left outstayed
///   the screen it was about);
/// - loading and conditions: until updated in place by their `id`;
/// - a `.long` toast (`Length`): at least `longDuration` — for the rare one
///   that is the only trace of something lost ("Couldn't publish your
///   post", #1459);
/// - a toast with an action never leaves on its own while VoiceOver or Switch
///   Control runs (WCAG 2.2.1: timing adjustable).
///
/// The countdown (`ToastCountdown`) pauses while a finger is on the toast,
/// while VoiceOver's focus is on it and while the scene is inactive.
///
/// ## Touch
///
/// The glass is interactive (it flexes under the finger). A swipe up
/// dismisses it, on distance or velocity; any other way it rubber-bands and
/// springs back. A tap runs
/// the action, if there is one — unless the message is cut (#1449): then a
/// tap on the toast's body opens its whole message in a bottom sheet
/// (`ToastMessageSheet`), and the action runs from its own trailing control
/// or from the sheet. Cut is measured at the label's width now, not by the
/// message's length.
///
/// ## VoiceOver
///
/// The bubble is one element: its label is the text, the action is a custom
/// action ("Show Full Message" too, while the text is cut), and the escape
/// gesture dismisses it. It is announced (queued, a
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
/// So the toast UNFOLDS FROM ITS MARK (#2285, after the map's bubble,
/// `MapFeaturedHalo`, #2203): it starts as a circle round its mark (the
/// disc, or the loader), as tall as it will be, centred where it will
/// stand, and widens both ways to its width through its width constraint;
/// the mark slides to the capsule's leading end, the glass materialises
/// with the shadow, and the words and the action fade in on its right at
/// their own size — never scaled — held from the leading end and revealed
/// by the widening capsule. It folds back the same way: the words and the
/// action go, the capsule narrows to the circle round its mark as the glass
/// dissolves, then it is removed. No slide and no scale (the morph and the
/// slide of #1034 went with #2285). A swipe up carries it off and dissolves
/// it on the way.
///
/// A new result while one is up takes over its capsule where it stands, and
/// the WHOLE content blurs — the mark, the words and the action (#2285,
/// `flowContent`); a new one while one is folding turns the fold around
/// into the new toast.
///
/// Under Reduce Motion (`MotionPreference`) there is no unfold: the glass
/// materialises and the row fades, in place; a content change cross-fades.
@MainActor
public final class ToastView: UIView {

    /// The ink a toast's glyph is drawn in: a glyph with a colour of its own
    /// keeps it — the Points heart its pink, the saved star its gold (#1190:
    /// a like's toast drew its heart in the label's ink) — on a toast that
    /// says things went well; any other glyph takes the style's ink.
    /// The leading disc's fill and its glyph's ink (`ToastBadge`): the
    /// glyph's own colour where it has one, else the style's — the app's
    /// primary for what went well.
    static func badgeColours(symbol: String, style: Style) -> (fill: UIColor, ink: UIColor) {
        switch style {
        case .failure: return (.systemRed, .white)
        case .warning: return (Warning.glyphTint, .black)
        case .confirmation, .loading:
            let own = glyphTint(symbol: symbol, style: style)
            return own == style.glyphTint ? (Palette.primaryFill, Palette.onPrimary) : (own, .white)
        }
    }

    static func glyphTint(symbol: String, style: Style) -> UIColor {
        guard style == .confirmation else { return style.glyphTint }
        switch symbol {
        case LikesSymbol.glyph: return LikesSymbol.tint
        case SaveStar.glyph: return SaveStar.tint
        default: return style.glyphTint
        }
    }
    enum Metrics {
        /// Gap between the capsule and the anchor it hangs from (#2143).
        static let topGap: CGFloat = Spacing.sm
        /// Under Reduce Motion, the fade in and out, in place.
        static let transitionDuration: TimeInterval = 0.32
        /// THE UNFOLD (#2285): the capsule widens from the circle round its
        /// mark on a spring. The map's bubble (#2203) takes 0.6 s; a toast is
        /// brief, so a touch quicker, with the same bounce.
        static let unfoldDuration: TimeInterval = 0.5
        static let unfoldBounce: CGFloat = 0.15
        /// The words and the action fade in on the capsule's right as it
        /// opens (the map's: 0.3 s from 0.18 s, a touch quicker too).
        static let contentInDelay: TimeInterval = 0.15
        static let contentInDuration: TimeInterval = 0.25
        /// The mark comes in with the glass, at the start.
        static let markInDuration: TimeInterval = 0.2
        /// THE FOLD, the unfold backwards (the map's): the words and the
        /// action go first, while the capsule narrows back to its circle on
        /// a spring with no bounce, the glass dissolving; the mark goes last,
        /// once the capsule is nearly round it.
        static let foldDuration: TimeInterval = 0.5
        static let contentOutDuration: TimeInterval = 0.15
        static let markOutDelay: TimeInterval = 0.15
        static let markOutDuration: TimeInterval = 0.3
        /// A swipe's exit: the glass dissolving as the throw carries it off.
        static let exitDuration: TimeInterval = 0.26
        /// Resting shadow strength. Soft and low-contrast: the glass already
        /// separates itself; the shadow only grounds it.
        static let shadowOpacity: Float = 0.22
        /// ONE HEIGHT for every toast at the default text size (the owner,
        /// 2026-11-06, after the system's pills): the leading disc and the
        /// action capsule (`ToastBadge.side`) with the same `inset` all round
        /// — concentric with the toast.
        static let minimumHeight: CGFloat = 48
        static let actionHeight: CGFloat = 48
        static let inset: CGFloat = (minimumHeight - ToastBadge.side) / 2
        /// Between the disc and the message, and between the message and the
        /// trailing control.
        static let glyphGap: CGFloat = 10
        static let controlGap: CGFloat = 12
        /// Never wider than this, however wide the screen (iPad).
        static let maximumWidth: CGFloat = 420
        /// A swipe up dismisses past this distance…
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
        /// until the same `id` says the condition has cleared; it holds the
        /// top line, a result toast hangs under it, and nothing replaces it.
        var isCondition = false

        init(
            message: String, symbol: String?, style: Style, action: Action?,
            undoable: Undoable?, id: String?, isCondition: Bool = false, length: Length = .standard
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
            if length == .long, let timed = duration { duration = max(timed, ToastView.longDuration) }
            if isCondition { duration = nil }
        }
    }

    private(set) var content: Content
    /// The style this toast was drawn in (read by tests).
    public var style: Style { content.style }
    /// Its one line of text.
    public var message: String { content.message }
    /// A condition ("Offline"), which holds its own line (#2143).
    public var isCondition: Bool { content.isCondition }
    /// Born a condition, so on its own line for good: "Back online", the
    /// same toast updated in place, keeps the top line it held and leaves on
    /// its timer, rather than swapping lines with a result up under it.
    private(set) var holdsOwnLine = false
    /// How long it stays up, in seconds; nil: until closed (`duration`).
    public var duration: TimeInterval? { content.duration }
    var action: Action? { content.action }
    var undoable: Undoable? { content.undoable }
    /// Once settled, never again.
    private(set) var resolution: Resolution?
    /// The undoable toast on screen, if any: a second one commits it (one
    /// undo slot) — wherever it is drawn.
    static weak var pendingUndo: ToastView?

    /// Called once the toast has left its superview — so the scene overlay
    /// that holds it can hide its window when it holds no more (#954).
    var onRemoved: (() -> Void)?

    /// The time left; nil for a toast that stays until closed.
    private(set) var countdown: ToastCountdown?

    private let backdrop = UIVisualEffectView(effect: nil)
    /// Hangs the capsule from the ceiling, at `restConstant`. Driven instead
    /// of a transform (see the type doc): the swipe moves it, and a swell
    /// hangs it up by half its growth.
    private var slide: NSLayoutConstraint?
    /// The slide's resting constant on the top line…
    private var baseConstant: CGFloat = 0
    /// …and for this toast on its own line (`restack`): under a condition,
    /// a result hangs lower.
    private var restConstant: CGFloat = 0
    /// Centres the capsule; a sideways pull stretches it.
    private var along: NSLayoutConstraint?
    /// Keep it between the container's margins; off while a swipe moves it.
    private var marginConstraints: [NSLayoutConstraint] = []
    /// Its entrance has begun: from then on `restack` moves it.
    private var hasArrived = false
    /// The bubble's one-line width (`measureIdealWidth`).
    private lazy var idealWidth = widthAnchor.constraint(equalToConstant: 0)
    private var rowInsets: CGFloat = 0
    private var textLabels: [UILabel] = []
    /// The words' slot in the row (`apply`).
    private var textSlot: ToastWords?
    /// The text's own vertical inset, rebuilt with the label (#1034).
    private var textInset: NSLayoutConstraint?
    /// Below required, as it always was; the unfold never squeezes the
    /// height (#2285: as tall as it will be from the first frame).
    private lazy var minimumHeightConstraint: NSLayoutConstraint = {
        let constraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight)
        constraint.priority = .required - 1
        return constraint
    }()
    /// While it unfolds or folds (#2285): the capsule's width, the side of
    /// the circle round its mark (`fold(_:)`)…
    private var foldWidth: NSLayoutConstraint?
    /// …and the row held at its own width from the leading end, its
    /// trailing edge let go, so the capsule reveals it as it widens.
    private var rowHeld: NSLayoutConstraint?
    /// The row's leading inset at rest (`apply`).
    private var restLeading: CGFloat = Spacing.lg
    /// Bumped by each entrance, exit and change: a completion from an older
    /// one does nothing.
    private var motionGeneration = 0
    /// How the glass is coming or going, to tell how much of it shows mid-
    /// way (`glassLevel`) — what a toast taking this capsule over starts
    /// its glass from (#2285).
    private var glassRamp: GlassRamp?
    /// The glass coming back from where a taken-over capsule had it
    /// (`materialiseGlass(from:)`).
    private var glassAnimator: UIViewPropertyAnimator?
    /// It leaves through the fold (or Reduce Motion's fade), not a swipe nor
    /// at once: a new result may still turn it around (#2285).
    private var leavesByFolding = false
    /// A new toast took its capsule over: it is gone, whatever its exit was
    /// doing.
    private var isTakenOver = false
    private let row = UIStackView()
    private(set) var closeButton: UIButton?
    private(set) var actionButton: UIButton?
    /// An undoable toast's trailing control: the ring and "Undo".
    private(set) var undoButton: ToastUndoButton?
    private var rowTrailing: NSLayoutConstraint?
    private var rowLeading: NSLayoutConstraint?
    private var isLeaving = false
    private var sceneObservers: [NSObjectProtocol] = []

    /// The glass view (tests).
    var glassView: UIVisualEffectView { backdrop }
    /// Whether it is on its way out — what a stake surface reads to know its
    /// undo window is still open (#1375), and tests.
    public var isDismissing: Bool { isLeaving }

    // MARK: - Presenting

    /// Shows `message` at the top of `host`, replacing any result toast
    /// already up there.
    ///
    /// - Parameters:
    ///   - message: the text — short, past-tense, no punctuation.
    ///   - symbol: an optional SF Symbol leading the text.
    ///   - host: the view to present in. Pass the view controller's `view`;
    ///     the capsule hangs under its safe area top.
    ///   - style: a confirmation, a failure (#804) or a warning.
    @discardableResult
    public static func present(
        _ message: String,
        symbol: String? = "checkmark.circle.fill",
        in host: UIView,
        style: Style = .confirmation
    ) -> ToastView {
        present(message, symbol: symbol, style: style, action: nil, in: host)
    }

    /// Shows a toast in `container`, hanging under `ceiling` (#954, #2143):
    /// - the same toast again — the same `id`, or with none the same style
    ///   and words — UPDATES the one up there in place (a loading toast turns
    ///   into its outcome; a repeat restarts its time);
    /// - a condition takes its own line, at the top;
    /// - any other toast REPLACES the result toast up (an undo it replaces
    ///   commits), and hangs under the conditions.
    ///
    /// - Parameter ceiling: what the capsule hangs from — the anchor's foot
    ///   (`ToastOverlay.ceiling`); the container's own safe area top unless
    ///   told otherwise.
    static func present(
        _ message: String,
        symbol: String?,
        style: Style,
        action: Action? = nil,
        undoable: Undoable? = nil,
        id: String? = nil,
        isCondition: Bool = false,
        length: Length = .standard,
        in container: UIView,
        ceiling: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        let content = Content(
            message: message, symbol: symbol, style: style, action: action,
            undoable: undoable, id: id, isCondition: isCondition, length: length
        )
        let shown = stack(in: container)
        let existing = shown.last { $0.content.key == content.key }
        // One undo slot: a second undoable action commits the first at once
        // (unless it is the same toast, being updated).
        if undoable != nil, let pending = pendingUndo, pending !== existing {
            pending.dismiss(animated: true)
        }
        if let existing {
            existing.update(to: content)
            return existing
        }
        // One result at a time, and ONE CAPSULE (#2143, the owner's device
        // check): a result that has arrived hands its place to this one,
        // which takes over its capsule where it stands — at its width on
        // screen, unfolding or up — and only the content and the width
        // change. Two capsules crossing on the same line (one leaving, one
        // arriving) read as a glitch on a fast toggle. A result not laid out
        // yet leaves the usual way. A condition replaces nothing, and is
        // never taken over.
        var takenOver: Handover?
        if !isCondition {
            for toast in shown where !toast.holdsOwnLine {
                if takenOver == nil, toast.hasArrived, toast.bounds.width > 0 {
                    takenOver = toast.handOver()
                } else {
                    toast.dismiss(animated: true)
                }
            }
            // ⚠️ A CLOSE TURNS AROUND INTO THE NEW TOAST (the owner, 2026-11-11,
            // #2285): a result folding away is out of the lines (`stack(in:)`),
            // but still on screen — this one takes its capsule over from where
            // the fold has it, rather than arriving as a second capsule on the
            // same line. It was committed when its close began.
            if takenOver == nil, let closing = closingCapsule(in: container) {
                takenOver = closing.handOver()
            }
        }

        let toast = ToastView(content: content)
        toast.holdsOwnLine = isCondition
        if undoable != nil { pendingUndo = toast }
        toast.baseConstant = Metrics.topGap
        toast.restConstant = toast.baseConstant
        let slide = toast.topAnchor.constraint(
            equalTo: ceiling ?? container.safeAreaLayoutGuide.topAnchor, constant: toast.baseConstant
        )
        toast.slide = slide
        let along = toast.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        toast.along = along
        // The margins hold, above the labels' compression resistance (they
        // truncate at the margins, not before) — except while a swipe carries
        // the toast past them (`swiped`).
        let margins = container.layoutMarginsGuide
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
        // Its line (under a condition, lower), where it unfolds — no slide.
        restack(in: container, animated: true)
        slide.constant = toast.restConstant
        if let takenOver {
            toast.lastChange = takenOver.changedAt
            toast.takeOver(takenOver)
            return toast
        }
        toast.animateIn()
        return toast
    }

    /// What a toast taking a capsule over starts from: its width on screen,
    /// its content where it stands, when its content last changed, and how
    /// much of its glass shows.
    struct Handover {
        let width: CGFloat
        let content: [Leaving]
        let changedAt: CFTimeInterval
        let glass: CGFloat
    }

    /// A result folding away in `container` that a new result may turn
    /// around (#2285): still on screen, leaving by its fold (or Reduce
    /// Motion's fade) — never a swipe, never a condition.
    private static func closingCapsule(in container: UIView) -> ToastView? {
        container.subviews.compactMap { $0 as? ToastView }.last { toast in
            toast.isLeaving && toast.leavesByFolding && !toast.isTakenOver
                && !toast.holdsOwnLine && toast.bounds.width > 0
        }
    }

    /// Hands this toast's capsule over to the toast replacing it, and goes
    /// at once: up, it leaves as any replaced toast does (an undo commits);
    /// folding, its close had already settled it.
    private func handOver() -> Handover {
        let handed = Handover(
            width: widthOnScreen, content: takeContentOut(), changedAt: lastChange, glass: glassLevel
        )
        isTakenOver = true
        if isLeaving {
            finish()
        } else {
            dismiss(animated: false)
        }
        return handed
    }

    /// Arrives in the capsule of the result toast it replaced: already
    /// there, at that toast's width on screen, holding its content, its
    /// glass coming back from wherever that one's was; then the content
    /// changes the way one capsule's does (`flowContent`).
    private func takeOver(_ handover: Handover) {
        tookOver = true
        takeOverWidth = handover.width
        row.alpha = 1
        hasArrived = true
        apply(content)
        materialiseGlass(from: handover.glass)
        flowContent(fromWidth: handover.width, leaving: handover.content)
        countdown?.start()
    }

    /// A piece of the content on its way out of a change: the very view, out
    /// of the row, where it stood — pinned to its end of the capsule — and
    /// how much of it still showed.
    struct Leaving {
        enum Role: Hashable { case mark, text, control }
        let view: UIView
        let role: Role
        var opacity: Float = 1
    }

    /// The role a piece of the row plays in a change.
    private static func role(of view: UIView) -> Leaving.Role {
        if view is ToastWords { return .text }
        return (view is ToastBadge || view is AppLoaderView) ? .mark : .control
    }

    /// How a piece keeps its end of the capsule as the capsule resizes about
    /// its centre: the mark the leading end, the control the trailing one,
    /// the words the middle.
    private static func pinning(_ role: Leaving.Role) -> UIView.AutoresizingMask {
        switch role {
        case .mark: [.flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        case .control: [.flexibleLeftMargin, .flexibleTopMargin, .flexibleBottomMargin]
        case .text: [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        }
    }

    /// Takes the content out of the row for a change: each piece stays
    /// WHERE IT SHOWS — mid-unfold or mid-fold, where the animation has it,
    /// not where it will land — pinned to its end of the capsule
    /// (`pinning`), so as the capsule resizes about its centre, none of
    /// them travels sideways.
    func takeContentOut() -> [Leaving] {
        let rowShown = row.layer.presentation()
        let rowOrigin = rowShown?.frame.origin ?? row.frame.origin
        let rowOpacity = rowShown?.opacity ?? Float(row.alpha)
        return row.arrangedSubviews.map { view in
            let shown = view.layer.presentation()
            let shownFrame = (shown?.frame ?? view.frame).offsetBy(dx: rowOrigin.x, dy: rowOrigin.y)
            let opacity = (shown?.opacity ?? Float(view.alpha)) * rowOpacity
            let pieceRole = Self.role(of: view)
            // Whatever was carrying it (its fade, its slide) ends here.
            view.layer.removeAllAnimations()
            view.transform = .identity
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            view.frame = shownFrame
            view.autoresizingMask = Self.pinning(pieceRole)
            view.isUserInteractionEnabled = false
            return Leaving(view: view, role: pieceRole, opacity: opacity)
        }
    }

    static let flowDuration: TimeInterval = 0.4

    /// The pieces of a change still on their way out.
    private var flowLeaving: [UIView] = []
    /// The pictures standing in for pieces while they blur (`blurPiece`).
    private var flowStands: [UIView] = []
    private var flowGeneration = 0

    /// What the last content change did to each piece (tests): blurred away
    /// and in — or, under Reduce Motion, cross-faded.
    struct ChangeMotion: Equatable {
        var crossFades = false
        var blurredOut: Set<Leaving.Role> = []
        var blurredIn: Set<Leaving.Role> = []
        /// How far the new mark slid to the leading end, from where the
        /// old one stood.
        var markSlide: CGFloat = 0
    }

    private(set) var lastChangeMotion: ChangeMotion?

    /// ONE CAPSULE CHANGING ITS MIND, THE DYNAMIC ISLAND'S WAY (the owner,
    /// 2026-11-06, after a fast toggle filmed twice): the mark stays at the
    /// leading end and the action at the trailing one, each going with its
    /// end as the capsule springs from `width` to its own.
    ///
    /// - THE WHOLE CONTENT BLURS (#2285): the mark (the disc with its glyph,
    ///   or the loader), the words and the action. The old ones blur away
    ///   first, the new ones come out of a blur just after, so the two are
    ///   never sharp on each other. Each is blurred from a picture of it in
    ///   its own ink (`ToastPictured`): a render inside the glass comes out
    ///   in its vibrant white (#2166).
    /// - The disc never goes through the symbol transition (it left the disc
    ///   empty between two unrelated glyphs, #2166): the old disc blurs out,
    ///   the new one in, and a change of colour happens inside the blur.
    /// - The mark slides from where the old one stood to the leading end —
    ///   a fold turned around, an unfold taken over, a loader becoming a
    ///   disc.
    /// - Only real views and their pictures move, inside the glass.
    /// - A change mid-change starts from the width on screen (`lastChange`).
    /// - Under Reduce Motion: a cross-fade, no blur, no spring.
    private func flowContent(fromWidth width: CGFloat, leaving: [Leaving]) {
        flowGeneration += 1
        // ⚠️ THE LATEST WINS, FROM WHAT IS ON SCREEN (the owner, 2026-11-06,
        // a toggle spammed: pieces of three states piled in one capsule, an
        // old Undo over the new words). A change that comes mid-change does
        // not start a whole change over: what was still leaving goes at once,
        // the content that was arriving — still blurred — goes at once too,
        // the new one comes out of the blur straight away, and the capsule
        // springs on from its width on screen without swelling again.
        // Nothing is lost: the latest state always shows, at once.
        let now = CACurrentMediaTime()
        let midChange = now - lastChange < Self.flowSettle
        lastChange = now
        flowLeaving.forEach { $0.removeFromSuperview() }
        flowLeaving = []
        dropStands()
        stopSwell()
        superview?.layoutIfNeeded()
        let reduces = MotionPreference.reducesMotion
        let finalSize = bounds.size
        // ⚠️ THE WORDS AT THEIR WHOLE WIDTH, FROM THE FIRST FRAME (filmed: held
        // to the narrow start, they showed "Notifica" until the change ended,
        // then jumped whole).
        let words = textSlot
        words?.holdWhole()
        let startsAt = widthAnchor.constraint(equalToConstant: width)
        startsAt.isActive = true
        superview?.layoutIfNeeded()
        // What leaves: what still showed of it, where it stood — none of it
        // mid-change.
        let glassContent = backdrop.contentView
        let shown = midChange ? [] : leaving.filter { $0.opacity > 0.02 }
        for piece in shown {
            piece.view.alpha = CGFloat(piece.opacity)
            glassContent.addSubview(piece.view)
        }
        flowLeaving = shown.map(\.view)
        let arriving = row.arrangedSubviews.filter { $0 !== words }
        // Where the mark slides from: where the old one stood.
        let mark = leadingMark
        let markLands = mark.map { $0.convert($0.bounds, to: glassContent).midX }
        let oldMark = leaving.first { $0.role == .mark }?.view.frame.midX
        let markShift = (oldMark ?? markLands ?? 0) - (markLands ?? 0)
        startsAt.isActive = false

        // The capsule: its width on a spring, swelling as it goes (`swell`),
        // through its constraints frame by frame — never a transform on glass.
        if reduces {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.superview?.layoutIfNeeded()
            }
        } else {
            startSwell(from: width, to: finalSize.width, height: finalSize.height, swells: !midChange)
        }

        var motion = ChangeMotion()
        if reduces {
            motion.crossFades = true
            crossFadeContent(out: shown.map(\.view), in: arriving + [words].compactMap { $0 })
        } else {
            let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
            let peak = Self.flowBlurRadius * scale
            // Out first (0.18 s); in just after (0.3 s from 0.1 s) — at once,
            // a touch quicker, mid-change.
            let inDelay: TimeInterval = midChange ? 0 : 0.1
            let inDuration: TimeInterval = midChange ? 0.24 : 0.3
            var markStands: (old: UIView?, new: UIView?) = (nil, nil)
            for piece in shown where blurAway(piece, peak: peak) {
                motion.blurredOut.insert(piece.role)
                if piece.role == .mark { markStands.old = flowStands.last }
            }
            if words?.blur(appearing: true, peak: peak, delay: inDelay, duration: inDuration) == true {
                motion.blurredIn.insert(.text)
            } else {
                words?.alpha = 1
            }
            for view in arriving {
                let arrivingRole = Self.role(of: view)
                if let stand = blurPiece(
                    view, role: arrivingRole, appearing: true, peak: peak, delay: inDelay, duration: inDuration
                ) {
                    motion.blurredIn.insert(arrivingRole)
                    if view === mark { markStands.new = stand }
                } else {
                    view.alpha = 1
                }
            }
            // The mark slides from where the old one stood to the leading
            // end, the old one's picture with it as it blurs away.
            if abs(markShift) > 0.5, let mark {
                motion.markSlide = markShift
                let oldMarkView = shown.first { $0.role == .mark }?.view
                let arrivingMovers = [mark, markStands.new].compactMap { $0 }
                let leavingMovers = [oldMarkView, markStands.old].compactMap { $0 }
                arrivingMovers.forEach { $0.transform = CGAffineTransform(translationX: markShift, y: 0) }
                UIView.animate(
                    springDuration: Self.flowDuration, bounce: 0.1,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    arrivingMovers.forEach { $0.transform = .identity }
                    leavingMovers.forEach { $0.transform = CGAffineTransform(translationX: -markShift, y: 0) }
                }
            }
        }
        lastChangeMotion = motion
        let generation = flowGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flowSettle) { [weak self, weak words] in
            guard let self, flowGeneration == generation else { return }
            words?.settle()
        }
    }

    /// Blurs a leaving piece away from what still showed of it (0.18 s),
    /// and takes it out once it has gone. False when it could not be
    /// drawn: it fades instead.
    private func blurAway(_ piece: Leaving, peak: CGFloat) -> Bool {
        let view = piece.view
        let gone: @MainActor () -> Void = { [weak self, weak view] in
            view?.removeFromSuperview()
            self?.flowLeaving.removeAll { $0 === view }
        }
        let blurred: Bool
        if let words = view as? ToastWords {
            blurred = words.blur(
                appearing: false, peak: peak, delay: 0, duration: 0.18, from: piece.opacity, completion: gone
            )
        } else {
            blurred = blurPiece(
                view, role: piece.role, appearing: false, peak: peak, delay: 0, duration: 0.18,
                from: piece.opacity, completion: gone
            ) != nil
        }
        if !blurred {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
                view.alpha = 0
            } completion: { _ in gone() }
        }
        return blurred
    }

    /// Blurs `view` — a mark or a control, in the row or leaving — in or
    /// away, from a picture of it in its own ink (`ToastPictured`) standing
    /// over it in the glass's content, pinned to its end of the capsule as
    /// the piece is (`pinning`); the piece hidden under it. Arriving, the
    /// piece takes its place back as it clears; leaving, `completion` runs
    /// once it has gone. Nil when it could not be drawn.
    @discardableResult
    private func blurPiece(
        _ view: UIView, role: Leaving.Role, appearing: Bool, peak: CGFloat, delay: TimeInterval,
        duration: TimeInterval, from opacity: Float = 1, completion: (@MainActor () -> Void)? = nil
    ) -> UIImageView? {
        let glassContent = backdrop.contentView
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        let pad = peak / scale * 3
        guard let image = ToastBlur.picture(of: view, scale: scale, pad: pad) else { return nil }
        let standFrame = view.convert(view.bounds, to: glassContent).insetBy(dx: -pad, dy: -pad)
        let standIn = ToastBlur.stand(
            image, scale: scale, frame: standFrame, in: glassContent, appearing: appearing,
            peak: peak, delay: delay, duration: duration, opacity: opacity
        ) { [weak self, weak view] finished in
            // Dropped meanwhile (a newer change): nothing more to do.
            guard let self, finished.superview != nil else { return }
            flowStands.removeAll { $0 === finished }
            if appearing, let view {
                ToastBlur.handOver(from: finished, to: view)
            } else {
                finished.removeFromSuperview()
            }
            completion?()
        }
        standIn.autoresizingMask = Self.pinning(role)
        flowStands.append(standIn)
        view.alpha = 0
        return standIn
    }

    /// Reduce Motion's change: the old content fades where it stands, the
    /// new one fades in.
    private func crossFadeContent(out leaving: [UIView], in arriving: [UIView]) {
        arriving.forEach { $0.alpha = 0 }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            leaving.forEach { $0.alpha = 0 }
        } completion: { [weak self] _ in
            leaving.forEach { $0.removeFromSuperview() }
            self?.flowLeaving.removeAll { view in leaving.contains { $0 === view } }
        }
        UIView.animate(withDuration: 0.24, delay: 0.08, options: [.curveEaseOut, .allowUserInteraction]) {
            arriving.forEach { $0.alpha = 1 }
        }
    }

    /// The pictures of a change go at once, and what they stood over shows.
    private func dropStands() {
        flowStands.forEach { $0.removeFromSuperview() }
        flowStands = []
    }

    /// The leading mark in the row: the disc, or the loader.
    private var leadingMark: UIView? {
        row.arrangedSubviews.first { $0 is ToastBadge || $0 is AppLoaderView }
    }

    /// The blur's peak, in points, as the system's bubbles.
    static let flowBlurRadius: CGFloat = 5
    /// When a change has settled: its spring, its swell, its blur.
    static let flowSettle: TimeInterval = 0.55
    /// How far the capsule swells as it changes: the least for a change in
    /// place, the most for one of `swellReach` points or more — gentler
    /// than a bar item's (`AppButton.MorphMetrics.morphSwell`), for a wider
    /// capsule.
    static let swellBase: CGFloat = 0.03
    static let swellMost: CGFloat = 0.08
    static let swellReach: CGFloat = 100

    /// The swell under way: when it began, the width it springs between,
    /// the height it swells from, how deep, and the constraints it drives.
    private struct Swell {
        let start: CFTimeInterval
        let from: CGFloat
        let to: CGFloat
        let height: CGFloat
        let depth: CGFloat
        let width: NSLayoutConstraint
        let tall: NSLayoutConstraint
    }

    private var swell: Swell?
    private var swellLink: CADisplayLink?
    /// How far a swell hangs the capsule up now: half its growth.
    private var swellLift: CGFloat {
        guard let swell else { return 0 }
        return (swell.tall.constant - swell.height) / 2
    }
    /// When the content last changed: a change within `flowSettle` of it
    /// is a change mid-change.
    fileprivate(set) var lastChange: CFTimeInterval = 0

    /// THE CAPSULE MORPHS AS THE SYSTEM'S GLASS BUBBLES DO (the owner,
    /// 2026-11-06): its width springs from `from` to `to` while the whole
    /// capsule swells — up to its crest at an eighth of a second, back by a
    /// quarter, a touch under, settled by half (`AppButton`'s measured
    /// curve) — about its centre, frame by frame through its constraints.
    private func startSwell(from: CGFloat, to: CGFloat, height: CGFloat, swells: Bool = true) {
        // Just under required: a capsule at its widest keeps its cap
        // (`maximumWidth`) and swells in height alone.
        let width = widthAnchor.constraint(equalToConstant: from)
        let tall = heightAnchor.constraint(equalToConstant: height)
        width.priority = .required - 1
        tall.priority = .required - 1
        NSLayoutConstraint.activate([width, tall])
        let reach = min(1, abs(to - from) / Self.swellReach)
        swell = Swell(
            start: CACurrentMediaTime(), from: from, to: to, height: height,
            depth: swells ? Self.swellBase + (Self.swellMost - Self.swellBase) * reach : 0, width: width, tall: tall
        )
        let link = CADisplayLink(target: SwellTick(self), selector: #selector(SwellTick.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        swellLink = link
        swellTick()
    }

    fileprivate func swellTick() {
        guard let swell else { return }
        let time = CACurrentMediaTime() - swell.start
        guard time < Self.flowSettle else {
            stopSwell()
            return
        }
        let progress = AppButtonBlur.springProgress(at: time, duration: Self.flowDuration, bounce: 0.1)
        let grown = 1 + swell.depth * Self.swellShare(at: time)
        swell.width.constant = (swell.from + (swell.to - swell.from) * progress) * grown
        swell.tall.constant = swell.height * grown
        // About its centre: the top hangs up by half the growth.
        slide?.constant = restConstant - (swell.height * grown - swell.height) / 2
        superview?.layoutIfNeeded()
    }

    /// The swell's share of its depth at `time` (`AppButton`'s curve).
    static func swellShare(at time: TimeInterval) -> CGFloat {
        let curve = AppButton.MorphMetrics.morphSwellCurve
        guard let next = curve.firstIndex(where: { $0.time >= time }), next > 0 else { return 0 }
        let (a, b) = (curve[next - 1], curve[next])
        let share = CGFloat((time - a.time) / (b.time - a.time))
        return a.share + (b.share - a.share) * share
    }

    private func stopSwell() {
        swellLink?.invalidate()
        swellLink = nil
        guard let swell else { return }
        NSLayoutConstraint.deactivate([swell.width, swell.tall])
        self.swell = nil
        if !isLeaving { slide?.constant = restConstant }
        superview?.layoutIfNeeded()
    }

    /// The display link's target: it holds the toast weakly (a link retains
    /// its target).
    @MainActor
    private final class SwellTick: NSObject {
        weak var toast: ToastView?
        init(_ toast: ToastView) { self.toast = toast }
        @objc func tick() { toast?.swellTick() }
    }

    /// A change's last pieces leave at once (the toast itself is leaving).
    private func endFlow() {
        flowLeaving.forEach { $0.removeFromSuperview() }
        flowLeaving = []
        dropStands()
        textSlot?.settle()
        textSlot?.alpha = 1
        row.arrangedSubviews.forEach { view in
            view.alpha = 1
            view.transform = .identity
        }
    }

    /// The capsule's width as it shows — mid-spring, where the spring is.
    private var widthOnScreen: CGFloat { layer.presentation()?.bounds.width ?? bounds.width }

    /// It arrived in the capsule of the toast it replaced (tests)…
    private(set) var tookOver = false
    /// …at that one's width on screen (tests).
    private(set) var takeOverWidth: CGFloat?

    /// Replaces this toast's content in place: a loading toast becomes its
    /// outcome, a repeat restarts its time.
    func update(to content: Content) {
        guard !isLeaving else { return }
        // A change away from an unsettled undo commits it first: the action
        // it stood for must not be lost with its toast.
        if undoable != nil, resolution == nil { resolve(.committed) }
        resolution = nil
        if Self.pendingUndo === self, content.undoable == nil { Self.pendingUndo = nil }
        if content.undoable != nil { Self.pendingUndo = self }
        superview?.bringSubviewToFront(self)
        // The same flow as a replacement: one capsule changing its mind.
        // Mid-unfold, from where the unfold has it.
        let width = widthOnScreen
        if hasArrived, width > 0 {
            let old = takeContentOut()
            settleUnfold()
            apply(content)
            flowContent(fromWidth: width, leaving: old)
        } else {
            apply(content)
        }
        if let container = superview {
            Self.restack(in: container, animated: true)
        }
        countdown?.start()
        Self.announce(content.message, style: content.style)
    }

    // MARK: - The lines

    /// The gap between a condition and the result under it.
    static let stackGap: CGFloat = Spacing.sm

    /// The toasts up in `container`, top line first: the conditions (and a
    /// condition updated into its outcome), oldest first, then the result
    /// toast — never more than one (#2143).
    static func stack(in container: UIView) -> [ToastView] {
        let up = container.subviews.compactMap { $0 as? ToastView }.filter { !$0.isLeaving }
        return up.filter(\.holdsOwnLine) + up.filter { !$0.holdsOwnLine }
    }

    /// Lays the lines out: each toast under the one above it. Never a
    /// transform: constraints, as for the slide.
    static func restack(in container: UIView, animated: Bool) {
        let toasts = stack(in: container)
        guard !toasts.isEmpty else { return }
        container.layoutIfNeeded()
        var offset: CGFloat = 0
        for toast in toasts {
            toast.restConstant = toast.baseConstant + offset
            offset += toast.bounds.height + stackGap
            // A swelling toast keeps the half of its growth it hangs up by
            // (`swellTick` goes on from its new `restConstant`).
            if toast.hasArrived { toast.slide?.constant = toast.restConstant - toast.swellLift }
        }
        let settle = { container.layoutIfNeeded() }
        if animated, !MotionPreference.reducesMotion {
            UIView.animate(
                withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: settle
            )
        } else {
            settle()
        }
    }

    /// Carries `toasts` to where `container`'s layout now puts them through a
    /// quick cross-fade (#2143) — far from where they were, a slide would
    /// cross the screen. The glass dissolves and comes back, as it arrives
    /// and leaves; never faded through an ancestor's alpha (see the type doc).
    static func crossFade(_ toasts: [ToastView], in container: UIView) {
        let moving = toasts.filter { $0.hasArrived && !$0.isLeaving }
        guard !moving.isEmpty else {
            container.layoutIfNeeded()
            return
        }
        moving.forEach { $0.isCrossFading = true }
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            moving.forEach { $0.showGlass(false) }
        } completion: { _ in
            container.layoutIfNeeded()
            let back = moving.filter { !$0.isLeaving }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                back.forEach { $0.showGlass(true) }
            } completion: { _ in
                moving.forEach { $0.isCrossFading = false }
            }
        }
    }

    /// Between the two halves of a cross-fade.
    private var isCrossFading = false

    /// The capsule shown or dissolved: its glass, its content and its shadow.
    private func showGlass(_ shown: Bool) {
        glassRamp = nil
        backdrop.effect = shown ? Self.makeGlass() : nil
        row.alpha = shown ? 1 : 0
        layer.shadowOpacity = shown ? Metrics.shadowOpacity : 0
    }

    // MARK: - Time

    /// How long a toast stays up, in seconds; nil: until it is closed, acted
    /// on or replaced (see the type doc).
    public static func duration(
        for style: Style, message: String, hasAction: Bool,
        isUndoable: Bool = false, assistiveTechnologyRunning: Bool
    ) -> TimeInterval? {
        // A loading toast waits for its outcome (an update by `id`). A
        // failure leaves on the common timer (#1448).
        if style == .loading { return nil }
        if hasAction, assistiveTechnologyRunning { return nil }
        if isUndoable { return undoDuration }
        let words = message.split(whereSeparator: \.isWhitespace).count
        return max(4, 2 + 0.3 * Double(words))
    }

    /// How long an undoable toast waits before it commits.
    public static let undoDuration: TimeInterval = 8

    /// How long a toast stays (#1459): the common rule, or longer.
    public enum Length: Sendable {
        case standard
        /// At least `longDuration`: the only trace of something lost.
        case long
    }

    /// The least a `.long` toast stays: past the undo window, the longest
    /// timed toast in the app.
    public static let longDuration: TimeInterval = 10

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
            postAnnouncement(announcement(message, style: style))
        }
    }

    /// Hands VoiceOver an announcement, without moving its focus.
    /// Swappable: tests read what was announced.
    static var postAnnouncement: @MainActor (NSAttributedString) -> Void = { announcement in
        UIAccessibility.post(notification: .announcement, argument: announcement)
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

    private init(content: Content) {
        self.content = content
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
        let leading = row.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: Spacing.lg)
        rowLeading = leading
        // Thin: the height is the toast's own (44/48 pt, #1034), and the
        // trailing control must not push it — the TEXT keeps its own inset
        // (`textInset`), which matters at large text sizes. Below required;
        // the unfold lets the trailing edge go and holds the row at its own
        // width from the leading end (`fold(_:)`).
        let edges = [
            row.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: Spacing.xs / 2),
            row.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor, constant: -Spacing.xs / 2),
            leading,
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
        NSLayoutConstraint.activate([
            minimumHeightConstraint,
            widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumWidth),
            idealWidth,
        ])
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

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(swiped(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        apply(content)
        // Announced rather than read on focus: the user's attention is on what
        // they just did.
        Self.announce(content.message, style: content.style)
    }

    /// Builds the row, the trailing control, VoiceOver's element and the
    /// countdown for `content` — at birth, and again for an update by `id`
    /// (a new mark every time: a change blurs the old one out, #2285).
    private func apply(_ content: Content) {
        self.content = content
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = UILabel()
        title.text = content.message
        // A title's weight, centred between the disc and the action — the
        // system pills' text (the owner, 2026-11-06).
        title.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
        title.textAlignment = .center
        title.adjustsFontForContentSizeCategory = true
        // Adaptive colors over an adaptive material: `UIGlassEffect` resolves
        // its own luminance against whatever it sits over, so the label tracks
        // it in both appearances without a hand-picked color.
        title.textColor = .label
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        // The message takes the room the control leaves and is the one thing
        // that gives way, once the capsule meets the margins.
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The words' slot takes the room between the mark and the control;
        // the words hold their own width at its middle, in a clip a change
        // opens from there (`flowContent`).
        let texts = ToastWords(label: title)
        textSlot = texts

        var arranged: [UIView] = []
        var leadsWithDisc = false
        if content.style == .loading {
            let spinner = AppLoaderView(size: .medium)
            spinner.startAnimating()
            arranged.append(spinner)
        } else if let symbol = content.symbol, let image = UIImage.symbol(named: symbol) {
            let colours = Self.badgeColours(symbol: symbol, style: content.style)
            arranged.append(ToastBadge(image: image, fill: colours.fill, ink: colours.ink))
            leadsWithDisc = true
        }
        arranged.append(texts)

        undoButton = content.undoable != nil ? ToastUndoButton() : nil
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
        textInset = heightAnchor.constraint(greaterThanOrEqualTo: title.heightAnchor, constant: 2 * Spacing.md)
        textInset?.priority = .required - 1
        textInset?.isActive = true
        let hasControl = actionButton != nil || closeButton != nil || undoButton != nil
        // The disc and the control sit `inset` from the capsule's ends, as
        // from its top and foot; text alone keeps a wider margin.
        let leading = leadsWithDisc ? Metrics.inset : Spacing.lg
        let trailing = hasControl ? Metrics.inset : Spacing.lg
        restLeading = leading
        rowLeading?.constant = leading
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
            self.countdown = countdown
            // Updated in place under its open sheet: the new time waits too.
            if fullMessageSheet != nil { countdown.hold(.sheet) }
        }
    }

    private static func makeActionButton(title: String) -> UIButton {
        ToastActionButton(title: title)
    }

    private static func makeCloseButton() -> UIButton {
        ToastCloseButton()
    }

    /// The width it asks for: its row with the text on its one line — the
    /// action, if any, flush after it (#2143).
    private func measureIdealWidth() {
        let width = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        idealWidth.constant = ceil(width + rowInsets)
    }


    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Built before it had a window: the text size it was measured at may
        // not be the window's.
        if window != nil { measureIdealWidth() }
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

    /// A tap: on a toast whose message is cut, it opens the whole message
    /// (#1449); on a toast with an action, it runs it.
    @objc private func tapped() {
        guard !isLeaving else { return }
        if isMessageTruncated {
            showFullMessage()
        } else if action != nil {
            runAction()
        }
    }

    #if DEBUG
    /// A tap on the toast's action — its Undo — through the same path, for
    /// tests outside this package (#1420).
    public func debugTapAction() { runAction() }
    /// The toast leaving now, as its time running out does (an undo
    /// commits), for tests outside this package (#1447).
    public func debugDismiss() { dismiss(animated: false) }
    /// A tap on the toast's body. Tests.
    func debugTap() { tapped() }
    /// Whether a change of content is under way: the words opening from
    /// their middle (`flowContent`). Tests.
    var debugIsFlowing: Bool { textSlot?.isOpening == true }
    /// The pieces still leaving a change. Tests.
    var debugLeaving: [UIView] { flowLeaving }
    /// The leading mark in the row now. Tests.
    var debugMark: UIView? { row.arrangedSubviews.first { $0 is ToastBadge || $0 is AppLoaderView } }
    /// Lays the toast out where it rests now. Tests.
    func debugSettle() { superview?.layoutIfNeeded() }
    /// Whether it is crossing to its anchor's new place. Tests.
    var debugIsCrossFading: Bool { isCrossFading }
    /// The content row: never scaled, never moved by a transform (#2285).
    /// Tests.
    var debugRow: UIStackView { row }
    #endif

    // MARK: - The whole message (#1449)

    /// Whether the message is cut at the label's width now: it would need
    /// more lines than the label draws. A label not laid out yet is not cut.
    ///
    /// ⚠️ MEASURED FROM THE TEXT, NOT FROM `UILabel.textRect` — which on iOS
    /// 26 never reported the cut (CI, #1449) — and against the width the
    /// label SHOWS inside the toast, which a label laid out wider than its
    /// capsule and clipped by it would overstate.
    var isMessageTruncated: Bool {
        guard let title = textLabels.first, !title.isHidden, let text = title.text, !text.isEmpty,
              let font = title.font else { return false }
        let width = messageWidth(of: title)
        guard width > 0 else { return false }
        let needed = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil
        )
        let lines = title.numberOfLines == 0 ? Int.max : title.numberOfLines
        let lineCount = Int((ceil(needed.height) / font.lineHeight).rounded())
        return lineCount > lines
    }

    /// The width the message has: the label's, as far as the toast shows it.
    private func messageWidth(of title: UILabel) -> CGFloat {
        let shown = title.convert(title.bounds, to: self).intersection(bounds)
        return shown.isNull ? 0 : min(title.bounds.width, shown.width)
    }

    #if DEBUG
    /// The message's measured width. Tests (#1449: what CI saw).
    var debugMessageWidth: CGFloat { textLabels.first.map(messageWidth(of:)) ?? -1 }
    #endif

    /// The sheet showing this toast's whole message, while it is up.
    private(set) weak var fullMessageSheet: ToastMessageSheet?

    /// Presents the sheet. Swappable: a package test host never completes
    /// a modal presentation (`test-host-modal-never-completes`).
    static var presentFullMessage: @MainActor (_ sheet: UIViewController, _ presenter: UIViewController) -> Void = {
        sheet, presenter in presenter.present(sheet, animated: true)
    }

    /// Opens the whole message in a bottom sheet: the toast waits while it
    /// is up; its action, chosen there, runs once it has gone.
    private func showFullMessage() {
        guard fullMessageSheet == nil, let presenter = fullMessagePresenter() else { return }
        let glyph = content.symbol.flatMap { UIImage.symbol(named: $0) }
        let sheet = ToastMessageSheet(
            message: content.message,
            glyph: content.style == .loading ? nil : glyph,
            glyphTint: content.symbol.map { Self.glyphTint(symbol: $0, style: content.style) } ?? content.style.glyphTint,
            actionTitle: isLeaving ? nil : action?.title
        )
        sheet.onAction = { [weak self] in self?.runAction() }
        sheet.onGone = { [weak self] in self?.countdown?.release(.sheet) }
        countdown?.hold(.sheet)
        fullMessageSheet = sheet
        Self.presentFullMessage(sheet.wrappedInSheet(), presenter)
    }

    /// Where the sheet is presented from: the topmost screen of the app's
    /// window — the scene's key one, never the toasts' own overlay.
    private func fullMessagePresenter() -> UIViewController? {
        let appWindow = window?.windowScene?.windows.first(where: \.isKeyWindow) ?? window
        var top = appWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// "Show Full Message" while the text is cut, ahead of the toast's own.
    public override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard isMessageTruncated else { return ownAccessibilityActions }
            let show = UIAccessibilityCustomAction(name: "Show Full Message") { [weak self] _ in
                self?.showFullMessage()
                return true
            }
            return [show] + ownAccessibilityActions
        }
        set { ownAccessibilityActions = newValue ?? [] }
    }

    private var ownAccessibilityActions: [UIAccessibilityCustomAction] = []

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

    /// How far the toast follows a pull of `distance` along an axis whose
    /// dismissing direction is `direction` (±1; 0: no dismissal that way):
    /// all the way toward it, a stretching fraction the other way.
    static func followed(_ distance: CGFloat, direction: CGFloat) -> CGFloat {
        if direction != 0, distance * direction > 0 { return distance }
        let limit = Metrics.rubberBandLimit
        let stretched = (1 - 1 / (abs(distance) / limit * 0.55 + 1)) * limit
        return distance < 0 ? -stretched : stretched
    }

    /// Whether a swipe that ended at `translation` with `velocity` dismisses:
    /// up, far or fast enough.
    static func dismisses(translation: CGPoint, velocity: CGPoint) -> Bool {
        -translation.y > Metrics.dismissDistance || -velocity.y > Metrics.dismissVelocity
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        guard !isLeaving, let container = superview else { return }
        let translation = pan.translation(in: container)
        switch pan.state {
        case .began:
            isSwiping = true
            countdown?.hold(.touch)
            NSLayoutConstraint.deactivate(marginConstraints)
        case .changed:
            slide?.constant = restConstant + Self.followed(translation.y, direction: -1)
            along?.constant = Self.followed(translation.x, direction: 0)
        case .ended, .cancelled, .failed:
            isSwiping = false
            let velocity = pan.velocity(in: container)
            if pan.state == .ended, Self.dismisses(translation: translation, velocity: velocity) {
                leaveBySwipe()
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

    /// Carries the toast off upward, dissolving the glass.
    private func leaveBySwipe() {
        slide?.constant = restConstant - (bounds.height + Metrics.topGap)
        leave(animated: true, moving: false)
    }

    // MARK: - Arrival and departure

    /// Where an unfold started, or a fold ends (tests): the capsule's frame
    /// and its mark's, in the capsule.
    struct Fold: Equatable {
        let capsule: CGRect
        let mark: CGRect?
    }

    /// The circle the last unfold started from (tests); nil for Reduce
    /// Motion's fade, which has none.
    private(set) var unfoldedFrom: Fold?

    /// THE UNFOLD (#2285, the map's bubble, `MapFeaturedHalo`, #2203): the
    /// capsule starts as a circle round its mark, as tall as it will be,
    /// centred where it will stand, and widens both ways to its width on a
    /// spring — its width constraint, never a transform on glass. The mark
    /// goes with the leading end; the words and the action fade in on its
    /// right at their own size, held from the leading end and revealed as
    /// it widens; the glass materialises (`effect` set in the animation),
    /// the shadow with it. No slide, no scale.
    ///
    /// Under Reduce Motion: no unfold — the glass materialises and the row
    /// fades in, in place.
    private func animateIn() {
        // Land the resting layout first: what the unfold opens to, and what
        // the circle is measured from.
        superview?.layoutIfNeeded()
        hasArrived = true
        motionGeneration += 1
        // Off a window, the glass waits for one (`didMoveToWindow`): built
        // off-screen it stalls a headless simulator.
        let glass = window == nil ? nil : Self.makeGlass()
        if glass != nil { backdrop.effect = nil }
        layer.shadowOpacity = 0
        let now = CACurrentMediaTime()
        if MotionPreference.reducesMotion {
            unfoldedFrom = nil
            row.alpha = 0
            glassRamp = GlassRamp(from: 0, to: 1, start: now, duration: Metrics.transitionDuration, bounce: 0)
            UIView.animate(
                withDuration: Metrics.transitionDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]
            ) {
                if let glass { self.backdrop.effect = glass }
                self.row.alpha = 1
                // A CALayer property set inside a UIView animation block
                // adopts that block's timing: the shadow arrives with the glass.
                self.layer.shadowOpacity = Metrics.shadowOpacity
            }
            countdown?.start()
            return
        }
        let mark = leadingMark
        let others = row.arrangedSubviews.filter { $0 !== mark }
        row.alpha = 1
        fold(true)
        superview?.layoutIfNeeded()
        unfoldedFrom = Fold(capsule: frame, mark: mark.map { $0.convert($0.bounds, to: self) })
        mark?.alpha = 0
        others.forEach { $0.alpha = 0 }
        glassRamp = GlassRamp(from: 0, to: 1, start: now, duration: Metrics.unfoldDuration, bounce: Metrics.unfoldBounce)
        unfoldEnds = now + Metrics.unfoldDuration
        let options: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
        UIView.animate(springDuration: Metrics.unfoldDuration, bounce: Metrics.unfoldBounce, options: options) {
            // The row is let go at once: it lands at the very width it was
            // held at, so it keeps that width all the way — only the hold's
            // first layout, the circle, needed it.
            self.fold(false)
            self.releaseRow()
            self.superview?.layoutIfNeeded()
            if let glass { self.backdrop.effect = glass }
            self.layer.shadowOpacity = Metrics.shadowOpacity
        }
        UIView.animate(withDuration: Metrics.markInDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            mark?.alpha = 1
        }
        UIView.animate(
            withDuration: Metrics.contentInDuration, delay: Metrics.contentInDelay,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            others.forEach { $0.alpha = 1 }
        }
        countdown?.start()
    }

    /// Folds the capsule to the circle round its mark (`true`), or lets it
    /// go back to its width (`false`) — through its width constraint, never
    /// a transform on glass. Folded, the row is held at its own width from
    /// the leading end (`holdRow`), the mark centred in the circle: the
    /// disc sits `inset` from the end as at rest, the smaller loader moves
    /// in to the middle. The side is the capsule's resting height: a circle
    /// as tall as the toast, from the first frame (#2285).
    private func fold(_ folded: Bool) {
        foldWidth?.isActive = false
        foldWidth = nil
        guard folded else {
            rowLeading?.constant = restLeading
            return
        }
        holdRow()
        let side = max(bounds.height, Metrics.minimumHeight)
        let width = widthAnchor.constraint(equalToConstant: side)
        width.isActive = true
        foldWidth = width
        if let mark = leadingMark, mark.bounds.width > 0 {
            rowLeading?.constant = (side - mark.bounds.width) / 2
        }
    }

    /// Holds the row at its laid-out width from the capsule's leading end,
    /// its trailing edge let go: the capsule clips what it does not reach.
    private func holdRow() {
        guard rowHeld == nil, row.bounds.width > 0 else { return }
        let held = row.widthAnchor.constraint(equalToConstant: row.bounds.width)
        rowTrailing?.isActive = false
        held.isActive = true
        rowHeld = held
    }

    /// The row back between the capsule's ends, at rest.
    private func releaseRow() {
        rowHeld?.isActive = false
        rowHeld = nil
        rowTrailing?.isActive = true
    }

    /// When the unfold under way settles.
    private var unfoldEnds: CFTimeInterval = 0

    /// An unfold under way ends where it stands — for a change, which takes
    /// the capsule on from its width on screen (`update`).
    private func settleUnfold() {
        guard CACurrentMediaTime() < unfoldEnds else { return }
        unfoldEnds = 0
        motionGeneration += 1
        for view in [self, backdrop, backdrop.contentView, row] {
            view.layer.removeAllAnimations()
        }
        fold(false)
        releaseRow()
        layer.shadowOpacity = Metrics.shadowOpacity
    }

    // MARK: - The glass

    /// How the glass is coming or going: from one level to another, on a
    /// spring of `duration` and `bounce` from `start` — UIKit's model for
    /// its own animation, so the level can be told mid-way.
    private struct GlassRamp {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: TimeInterval
        let bounce: CGFloat
    }

    /// How much of the glass shows now, 0 → 1 — mid-unfold or mid-fold,
    /// as far as its animation has gone.
    var glassLevel: CGFloat {
        guard let ramp = glassRamp else { return backdrop.effect == nil ? 0 : 1 }
        let elapsed = CACurrentMediaTime() - ramp.start
        let progress = AppButtonBlur.springProgress(at: elapsed, duration: ramp.duration, bounce: ramp.bounce)
        let level = ramp.from + (ramp.to - ramp.from) * progress
        return min(1, max(0, level))
    }

    /// The glass back, from `level` — what the capsule this toast took over
    /// still showed of its own (#2285: a fold turned around, an unfold taken
    /// over) — never dipping to nothing first: an animator set to that point
    /// of the materialisation, then let go on the unfold's spring.
    private func materialiseGlass(from level: CGFloat) {
        // Off a window, the glass waits for one (`didMoveToWindow`).
        guard window != nil else {
            layer.shadowOpacity = Metrics.shadowOpacity
            return
        }
        let reduces = MotionPreference.reducesMotion
        let rampTime = reduces ? Metrics.transitionDuration : Metrics.unfoldDuration
        let glass = Self.makeGlass()
        guard level < 0.98 else {
            glassRamp = nil
            backdrop.effect = glass
            layer.shadowOpacity = Metrics.shadowOpacity
            return
        }
        let start = max(0, level)
        glassRamp = GlassRamp(
            from: start, to: 1, start: CACurrentMediaTime(), duration: rampTime * Double(1 - start), bounce: 0
        )
        backdrop.effect = nil
        layer.shadowOpacity = Metrics.shadowOpacity * Float(start)
        let animator = reduces
            ? UIViewPropertyAnimator(duration: rampTime, curve: .easeOut)
            : UIViewPropertyAnimator(duration: rampTime, dampingRatio: 1)
        animator.addAnimations { [weak self] in self?.backdrop.effect = glass }
        animator.pauseAnimation()
        animator.fractionComplete = start
        animator.continueAnimation(withTimingParameters: nil, durationFactor: 1 - start)
        glassAnimator = animator
        let shadowTime = rampTime * Double(1 - start)
        UIView.animate(withDuration: shadowTime, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.layer.shadowOpacity = Metrics.shadowOpacity
        }
    }

    /// A glass still coming back lands now, so what follows starts from it.
    private func landGlass() {
        guard let animator = glassAnimator else { return }
        glassAnimator = nil
        guard animator.state == .active else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    // MARK: - Leaving

    /// Takes the toast away — animated: it folds back into the circle
    /// round its mark (it fades in place under Reduce Motion) while the
    /// glass dissolves.
    func dismiss(animated: Bool) {
        leave(animated: animated, moving: true)
    }

    /// Where the last fold ends (tests): the circle round its mark.
    var foldedTo: Fold? {
        guard foldWidth != nil else { return nil }
        return Fold(capsule: frame, mark: leadingMark.map { $0.convert($0.bounds, to: self) })
    }

    /// - Parameter moving: false for a swipe, which carries the toast off
    ///   itself (`leaveBySwipe`): the glass dissolves on the way.
    private func leave(animated: Bool, moving: Bool) {
        guard !isLeaving else { return }
        // A change under way gives way to the real content, which leaves.
        stopSwell()
        endFlow()
        landGlass()
        let glassNow = glassLevel
        isLeaving = true
        leavesByFolding = animated && moving
        // Any way out but Undo commits: time, close, swipe, a replacement,
        // a second undoable toast, the background.
        resolve(.committed)
        countdown?.cancel()
        stopObservingScene()
        isUserInteractionEnabled = false
        // The one under it moves up as it leaves (it is out of the lines
        // already: `isLeaving`).
        if let container = superview {
            Self.restack(in: container, animated: animated)
        }
        // Never laid out, it never showed: nothing to fold.
        guard animated, bounds.width > 0 else {
            finish()
            return
        }
        // Settle whatever the container has pending BEFORE the exit animates —
        // the same line `animateIn` has, for the same reason: this can fire
        // from a timer, on whatever the container holds by then, and a view
        // installed in the meantime that has not had its first pass would take
        // it inside the block below, growing out of the top-left corner.
        if moving { superview?.layoutIfNeeded() }
        motionGeneration += 1
        let generation = motionGeneration
        let gone: (Bool) -> Void = { [weak self] _ in
            // Turned around into the next toast meanwhile: that one has it.
            guard let self, motionGeneration == generation, !isTakenOver else { return }
            finish()
        }
        let now = CACurrentMediaTime()
        guard moving, !MotionPreference.reducesMotion else {
            // A swipe's throw, or Reduce Motion's fade in place.
            let exitTime = moving ? Metrics.transitionDuration : Metrics.exitDuration
            glassRamp = GlassRamp(from: glassNow, to: 0, start: now, duration: exitTime, bounce: 0)
            let away = {
                self.superview?.layoutIfNeeded()
                self.dissolve()
                self.row.alpha = 0
            }
            UIView.animate(
                withDuration: exitTime, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                animations: away, completion: gone
            )
            return
        }
        // THE FOLD (#2285): the words and the action go, the capsule narrows
        // back to the circle round its mark — the mark sliding back to its
        // middle — as the glass dissolves; the mark goes last; then it is
        // removed. From where it stands: a fold can begin mid-unfold.
        let mark = leadingMark
        let others = row.arrangedSubviews.filter { $0 !== mark }
        glassRamp = GlassRamp(from: glassNow, to: 0, start: now, duration: Metrics.foldDuration, bounce: 0)
        UIView.animate(
            withDuration: Metrics.contentOutDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            others.forEach { $0.alpha = 0 }
        }
        UIView.animate(
            withDuration: Metrics.markOutDuration, delay: Metrics.markOutDelay,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            mark?.alpha = 0
        }
        let folds = {
            self.fold(true)
            self.superview?.layoutIfNeeded()
            self.dissolve()
        }
        UIView.animate(
            springDuration: Metrics.foldDuration, bounce: 0, options: [.beginFromCurrentState],
            animations: folds, completion: gone
        )
    }

    /// The glass dissolving — how glass leaves; fading the view would put
    /// group opacity on the effect view (see the type doc) — and its shadow
    /// with it, or the shadow stays behind as a grey smear.
    private func dissolve() {
        backdrop.effect = nil
        layer.shadowOpacity = 0
    }

    private func finish() {
        landGlass()
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
