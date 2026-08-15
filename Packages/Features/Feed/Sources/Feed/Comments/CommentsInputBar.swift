import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// The comments composer, in the app's native Liquid Glass grammar —
/// deliberately the SAME recipe as Private Messages' `ChatInputBar`
/// (features don't import each other, so the recipe is replicated, not the
/// class): a floating glass capsule field that grows with its text, and a
/// round prominent-glass send button sharing its bottom baseline. It owns
/// no keyboard logic — the host pins its bottom to
/// `view.keyboardLayoutGuide.topAnchor`.
final class CommentsInputBar: UIView {
    /// Fired with trimmed, non-empty text; the field clears itself first.
    var onSend: ((String) -> Void)?
    /// Fired by the boost (star) button with the point amount to spend —
    /// the tap default, or a denomination from the long-press menu. The spend
    /// itself is the host's affair (it owns the post identity and the
    /// wallet); the refusal comes back through `playBoostDenied`.
    var onBoost: ((Int) -> Void)?
    /// Fired by the boost menu's Undo entry — the host refunds the session
    /// spend (it owns the tally and the wallet; the bar only shows the door).
    var onBoostUndo: (() -> Void)?
    /// Fired by the MICROPHONE face (the idle trailing slot): the voice-note
    /// seam. Unwired for now — an honest affordance whose capture flow does
    /// not exist yet.
    ///
    /// The slot used to hold a ✕ that collapsed the engagement. The exit
    /// moved to the toolbar, which is where the layout's other mode controls
    /// live, and the bar got the affordance a message composer actually
    /// wants in that position.
    var onVoiceNote: (() -> Void)?
    /// One phase of an interactive vertical page-swipe born on the bar.
    enum PageSwipePhase { case began, changed, ended }
    /// A vertical drag anywhere on the bar (field, buttons, gaps) drives the
    /// feed pager INTERACTIVELY — the bar forwards the raw translation and
    /// velocity, and the host offsets the parent scroll view in real time
    /// (the finger-linked page drag), settling on release. The bar OWNS the
    /// pan because the feed pager cannot wrest a drag from the text-input
    /// stack (empirically: neither cancellation opt-in nor arbitration
    /// passthrough starts the pager's own pan here) — so the bar detects it
    /// and the host drives `contentOffset` directly. `translation`/
    /// `velocity` are the pan's vertical components; up (negative) pages to
    /// the next post. Wiring this ENABLES the drive AND marks a feed
    /// engagement (so a text post — which has no ✕ — still shows the
    /// keyboard-dismiss face); hosts that leave it nil (the pushed comments
    /// screen) have no page-swipe and keep a permanent send.
    var onPageSwipe: ((PageSwipePhase, _ translation: CGFloat, _ velocity: CGFloat) -> Void)? {
        didSet { updateTrailingButtons(animated: false) }
    }

    /// Disables sending while a comment is in flight (spinner in the button).
    var isSending = false {
        didSet {
            sendButton.configuration?.showsActivityIndicator = isSending
            updateTrailingButtons(animated: false)
        }
    }

    private enum Metrics {
        static let maxLines: CGFloat = 4
        static let controlSize: CGFloat = 38
        /// The face inside the 38pt bubble. Inset so the glass reads as a
        /// container around it rather than a rim the disc has covered —
        /// the same relationship the mic and boost glyphs have with theirs.
        static let avatarDiameter: CGFloat = 30
    }

    /// The viewer's face, leading the bar — the composer's answer to the
    /// question every comment row already answers. Same contract as those
    /// rows: the monogram is the RENDERED identity, drawn immediately; the
    /// picture layers over it and never replaces it, so there is no empty
    /// disc and no third loading state.
    private let avatarView = MonogramAvatarView(diameter: Metrics.avatarDiameter)
    private let avatarImageView = AvatarImageView()
    /// The glass bubble the avatar sits in, and the button that owns its
    /// touches. The bubble matches the mic and boost button beside it — the composer
    /// reads as one row of glass controls with a face at its head — and the
    /// button carries the profile switcher menu.
    ///
    /// Effect deferred to window attach, like every other glass surface
    /// here: materializing one in `init` contacts the render server and
    /// stalls headless CI simulators.
    private let avatarBubble = UIVisualEffectView(effect: nil)
    private let avatarButton = UIButton(type: .system)
    private var avatarTask: Task<Void, Never>?
    /// The identity the in-flight fetch belongs to. The bar is not a
    /// recycled cell, but it IS re-identified per engagement, and a slow
    /// fetch from the previous one must not land on the next viewer.
    private var representedAvatarURL: URL?

    // Effect set on window attach: materializing one in init contacts the
    // render server and stalls headless CI simulators (see ci memory).
    private let field = UIVisualEffectView(effect: nil)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let boostButton = UIButton(configuration: .glass())
    private let sendButton = UIButton(configuration: .prominentGlass())
    /// The trailing slot's UTILITY face (send's overlay partner): a
    /// keyboard-state morphing control. Keyboard closed → the MICROPHONE
    /// (voice note); keyboard open with an empty field → the
    /// dismiss-keyboard chevron (retires the keyboard, engagement
    /// untouched). Send takes the slot only while there is text to send
    /// (or a submission in flight).
    private let utilityButton = UIButton(configuration: .glass())
    /// Whether the keyboard is up — the third axis of the trailing
    /// toggle, driven by the keyboardWillShow/Hide notifications (the
    /// engaged bar is the screen's only text input, so the global signal
    /// is unambiguous). Internal setter for tests: the state machine is
    /// unit-tested without driving a real keyboard.
    private(set) var isKeyboardOpen = false
    /// Which glyph the utility button currently wears (avoids re-running
    /// the crossfade transition on every unrelated update).
    private var utilityShowsKeyboardDismiss = false
    /// Removes the keyboard observers on release — a nonisolated deinit
    /// cannot touch main-actor state, so the tokens live in a bag whose
    /// own deinit does the unregistering (the VC-side pattern).
    private let keyboardObservers = NotificationObserverTokenBag()
    private var fieldHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
        textView.delegate = self
        textView.pin(to: field.contentView)

        placeholderLabel.text = "Add a comment…"
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.constrain(in: field.contentView) { parent in
            placeholderLabel.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor,
                constant: Spacing.sm + textView.textContainer.lineFragmentPadding
            )
            placeholderLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // The native bubble-glass token (the chat bar's exact contract):
        // the corner configuration drives the glass shape itself, so the
        // caps stay circular at one line, hold that radius as the field
        // grows, and keep the effect's own crisp boundary refraction.
        field.clipsToBounds = true
        field.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)

        // The boost control, in the slot the media "+" held: tap spends the
        // default denomination, long-press opens the amount menu (the rail
        // anchor's exact contract — one post, two surfaces, one behavior).
        boostButton.configuration?.image = UIImage(
            systemName: "star.fill",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        boostButton.configuration?.cornerStyle = .capsule
        boostButton.accessibilityLabel = "Boost post"
        boostButton.addAction(
            UIAction { [weak self] _ in self?.onBoost?(WalletStore.Policy.tapBoostAmount) },
            for: .primaryActionTriggered
        )
        // DEFERRED and uncached, like the rail anchor's: built at present
        // time from the pushed wallet context, so unaffordable denominations
        // arrive disabled and the Undo entry exists exactly while a session
        // spend is takeable.
        boostButton.menu = UIMenu(
            title: "Boost this post",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.currentBoostMenuActions() ?? [])
                },
            ]
        )

        sendButton.configuration?.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.accessibilityLabel = "Send comment"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .primaryActionTriggered)

        utilityButton.configuration?.image = UIImage(
            systemName: "mic",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        utilityButton.configuration?.cornerStyle = .capsule
        utilityButton.accessibilityLabel = "Record voice comment"
        utilityButton.addAction(UIAction { [weak self] _ in self?.utilityTapped() }, for: .primaryActionTriggered)

        // The keyboard axis of the trailing toggle: the utility face
        // morphs mic ↔ dismiss-keyboard as the keyboard comes and goes.
        keyboardObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardOpen(true) }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardOpen(false) }
            },
        ]

        // The avatar stack, outside in: glass bubble → face (monogram with
        // the picture layered over it) → a transparent button spanning the
        // whole bubble, which owns the touches and carries the menu.
        //
        // The button is LAST and full-bleed rather than wrapping the disc,
        // so the whole 38pt bubble is the tap target — a 30pt disc alone is
        // under the 44pt guidance already, and the glass rim would be dead.
        avatarImageView.pin(to: avatarView)
        avatarBubble.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)
        avatarBubble.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarBubble.contentView.addSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: avatarBubble.contentView.centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: avatarBubble.contentView.centerYAnchor),
        ])
        // Into the CONTENT VIEW, never the effect view itself — UIKit raises
        // on a direct subview. Added after the face, so it lies over it.
        avatarButton.pin(to: avatarBubble.contentView)
        avatarButton.accessibilityLabel = "Switch profile"
        // A menu, not an action: tap opens it (`showsMenuAsPrimaryAction`),
        // and long press opens the same one — the idiom the toolbar's ⋯
        // already uses on this screen.
        avatarButton.showsMenuAsPrimaryAction = true
        // Nothing to show until a switcher hands one over; without this the
        // button would swallow taps and present an empty menu.
        avatarButton.isEnabled = false

        addSubview(avatarBubble)
        addSubview(field)
        addSubview(sendButton)
        addSubview(utilityButton)
        addSubview(boostButton)
        avatarBubble.translatesAutoresizingMaskIntoConstraints = false
        boostButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        utilityButton.translatesAutoresizingMaskIntoConstraints = false
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        // Four slots, leading to trailing: the viewer's AVATAR, the field,
        // the mic/send toggle, and the boost button. Bottom-baseline anchoring — the
        // field grows upward while the round controls hold their stations,
        // and the field owns all the flexible width.
        //
        // This slot moved from the leading edge to the trailing one so the
        // avatar could open the bar (a composer says who is speaking before
        // it offers what to attach), which also puts both action controls in
        // one thumb-reachable cluster. Mic and send OVERLAY a single slot
        // and crossfade; the avatar is silent and never moves.
        NSLayoutConstraint.activate([
            fieldHeight,
            avatarBubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatarBubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatarBubble.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            avatarBubble.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            field.leadingAnchor.constraint(equalTo: avatarBubble.trailingAnchor, constant: Spacing.sm),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Spacing.sm),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            utilityButton.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            utilityButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            utilityButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            utilityButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            boostButton.leadingAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: Spacing.sm),
            boostButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            boostButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            boostButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            boostButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])

        // The disc is NEVER empty. Before an identity resolves the bar shows
        // the unknown-viewer placeholder, not a blank circle — the same
        // "monogram is the rendered state" rule the comment rows follow,
        // applied to the frame before anyone has told us who you are.
        avatarView.setMonogram(Self.monogram(nil))
        updateTrailingButtons(animated: false)
        updateFieldHeight()

        // Vertical-intent pan for the swipe exit (the rail's begin rule:
        // vertical wins, horizontal/taps pass through untouched).
        swipeRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        addGestureRecognizer(swipeRecognizer!)
    }

    private var swipeRecognizer: UIPanGestureRecognizer?

    /// Vertical-intent gate for the swipe-exit pan only; every other
    /// recognizer keeps UIKit's default answer.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The nudge's damped, saturating displacement: near-1:1 for the first
    /// few points, asymptotic to ±40 — the bar feels physically attached
    /// to the finger without ever leaving its band. Pure, for tests.
    static func nudgeOffset(for translation: CGFloat) -> CGFloat {
        40 * CGFloat(tanh(Double(translation) / 80))
    }

    @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
        // No drive on the pushed screen (no page-swipe), and NOT while the
        // keyboard is up — a downward drag there is a keyboard dismissal,
        // not a page change (the list's interactive dismiss handles that).
        guard onPageSwipe != nil, !isKeyboardOpen else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        switch pan.state {
        case .began:
            // The whole engaged layer (media card, comments, THIS bar — all
            // in the leaving cell) rides the pager's contentOffset from
            // here on; the bar no longer self-nudges (that would double the
            // motion).
            onPageSwipe?(.began, 0, 0)
        case .changed:
            onPageSwipe?(.changed, dy, vy)
        case .ended:
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-gesture-log") {
                print("GESTURELOG: bar page-swipe ended dy=\(dy) vy=\(vy)")
            }
            #endif
            onPageSwipe?(.ended, dy, vy)
        case .cancelled, .failed:
            onPageSwipe?(.ended, dy, vy) // release: the host settles back
        default:
            break
        }
    }

    #if DEBUG
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if ProcessInfo.processInfo.arguments.contains("-gesture-log"), let touch = touches.first {
            print("GESTURELOG: bar touchesBegan at \(touch.location(in: self))")
        }
        super.touchesBegan(touches, with: event)
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if field.effect == nil {
            field.effect = UIGlassEffect()
        }
        if avatarBubble.effect == nil {
            let glass = UIGlassEffect(style: .regular)
            // INTERACTIVE, unlike the caption card's glass: this one is a
            // control, and the system's press response (the lensing dip
            // under a finger) is the affordance that says so.
            glass.isInteractive = true
            avatarBubble.effect = glass
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFieldHeight()
    }

    private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        textView.text = ""
        textViewDidChange(textView)
        onSend?(text)
    }

    /// The field's current draft. Internal for tests (the trailing state
    /// machine is exercised without a real keyboard) and any future draft
    /// restoration; routes through the delegate path so the toggle and
    /// the field height stay honest.
    var draftText: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            textViewDidChange(textView)
        }
    }

    /// The utility face's tap: with the keyboard up it retires the keyboard
    /// (the engagement stays); with it down it opens the voice-note seam.
    /// One slot, one thumb position, state-appropriate intent.
    private func utilityTapped() {
        if isKeyboardOpen {
            textView.resignFirstResponder()
        } else {
            onVoiceNote?()
        }
    }

    /// The keyboard seam behind the notification observers. Internal (not
    /// private) so the three-state trailing machine is unit-testable
    /// without driving a real keyboard.
    func setKeyboardOpen(_ open: Bool) {
        guard open != isKeyboardOpen else { return }
        isKeyboardOpen = open
        updateTrailingButtons(animated: true)
        // An idle dismissal (keyboard retired over an empty field) resets
        // any armed reply state — the host clears its target so a later
        // composition starts top-level, not silently bound to a thread.
        if !open, textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onIdleDismiss?()
        }
    }

    /// Fired when the keyboard retires over an EMPTY field — the reply
    /// state's natural exit (a draft in progress keeps its target).
    var onIdleDismiss: (() -> Void)?

    /// Renders the viewer into the leading avatar: the monogram lands on
    /// this frame, the picture arrives behind it whenever the fetch
    /// resolves. A nil identity (nobody signed in, no profile) leaves the
    /// neutral placeholder disc — never someone else's face.
    func setViewerIdentity(_ identity: ViewerIdentity?, imagePipeline: ImagePipeline?) {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImageView.image = nil
        representedAvatarURL = identity?.avatarURL
        avatarView.setMonogram(Self.monogram(identity?.name))
        // The placeholder names the viewer, so a profile switch rewrites it
        // on the same beat as the face — one setter, both surfaces.
        viewerName = identity?.name
        applyPlaceholder()
        guard let url = identity?.avatarURL, let imagePipeline else { return }
        avatarTask = Task { [weak self] in
            let image = try? await imagePipeline.image(for: url)
            guard let self, let image, !Task.isCancelled,
                  self.representedAvatarURL == url else { return }
            self.avatarImageView.image = image
        }
    }

    /// Installs the profile switcher on the avatar bubble. Nil disables it —
    /// an account with nothing to switch to must not offer a menu, and a
    /// host that wires no switcher at all (the pushed comments screen) gets
    /// a plain, inert face.
    func setProfileMenu(_ menu: UIMenu?) {
        avatarButton.menu = menu
        avatarButton.isEnabled = menu != nil
    }

    /// The composer's initials, by the comment stream's rule (first letters
    /// of the first two words). The placeholder for an unknown viewer is
    /// the same "?" a nameless comment author gets.
    static func monogram(_ name: String?) -> String {
        let initials = (name ?? "").split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// The reply state's face: a non-nil name switches the placeholder to
    /// "Reply to NAME…"; nil restores the default prompt. Pure placeholder
    /// — the reply payload (the thread parent's id) is the HOST's state.
    func setReplyPlaceholder(name: String?) {
        replyName = name
        applyPlaceholder()
    }

    /// The armed reply target's name, and the viewer's — the two inputs the
    /// placeholder is a function of.
    private var replyName: String?
    private var viewerName: String?

    /// The placeholder, resolved from BOTH axes in one place.
    ///
    ///   replying          → "Reply to Kenji…"
    ///   viewer known      → "Comment as Ava Moreau"
    ///   viewer unknown    → "Add a comment…"
    ///
    /// Naming the viewer matters most exactly where this bar lives: the
    /// avatar beside it can switch WHICH of your profiles is speaking, and
    /// a picture alone is a weak answer to "who am I posting as". Replying
    /// still wins the slot — the target of a reply is the more urgent fact,
    /// and the avatar keeps answering the other question.
    private func applyPlaceholder() {
        if let replyName {
            placeholderLabel.text = "Reply to \(replyName)…"
        } else if let viewerName, !viewerName.isEmpty {
            placeholderLabel.text = "Comment as \(viewerName)"
        } else {
            placeholderLabel.text = "Add a comment…"
        }
    }

    /// Raises the keyboard into the composer — the row-tap reply trigger.
    func focusComposer() {
        textView.becomeFirstResponder()
    }

    // MARK: - Boost feedback

    /// The viewer's cumulative spend on the represented post — flips the
    /// boost button between its star-glyph face (0, an invitation) and
    /// the gold number itself (a receipt): the rail anchor's exact contract
    /// (`SnapRailBoostButton.setSpentTotal`), on this surface. Owned by the
    /// host, which owns the post identity and the wallet.
    func setBoostTotal(_ total: Int) {
        guard total != boostSpentTotal else { return }
        boostSpentTotal = total
        if total > 0 {
            var title = AttributedString(total.formattedCompact())
            title.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            title.foregroundColor = .systemYellow
            boostButton.configuration?.attributedTitle = title
            boostButton.configuration?.image = nil
            // `.glass()`'s default content insets leave a 38pt circle ~10pt
            // of text width, so "100" WRAPPED into a vertical digit stack
            // (measured in-sim). The number face zeroes them — the rail
            // anchor's recipe, whose circle never wrapped.
            boostButton.configuration?.contentInsets = .zero
        } else {
            boostButton.configuration?.attributedTitle = nil
            boostButton.configuration?.image = UIImage(
                systemName: "star.fill",
                withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
            )
        }
        boostButton.accessibilityValue = total > 0 ? "\(total) points spent" : nil
        // The receipt moves the cap's remainder, and the remainder moves
        // the enable state (a full post refuses even the tap).
        refreshBoostEnabled()
    }

    /// The number face's current value, so `setBoostTotal` is cheap to call
    /// from every refresh path without re-rendering an unchanged button.
    private var boostSpentTotal = 0
    /// The wallet context the host pushes (`setBoostContext`): what the
    /// balance can still afford, and how much of this post's spend is
    /// session-undoable. `Int.max` at rest so an unwired host keeps the
    /// historical always-enabled affordance.
    private var boostBalance = Int.max
    private var boostUndoableAmount = 0

    /// The affordability + undo state, pushed on configure and on every
    /// wallet change. Disables the button only when it has NOTHING to
    /// offer — tap unaffordable AND nothing to undo — because a disabled
    /// `UIButton` delivers no long-press either, and the menu is the
    /// undo's only door.
    func setBoostContext(balance: Int, undoableAmount: Int) {
        boostBalance = balance
        boostUndoableAmount = undoableAmount
        refreshBoostEnabled()
    }

    private func refreshBoostEnabled() {
        let remaining = max(0, WalletStore.Policy.perTargetBoostCap - boostSpentTotal)
        // A tap near the cap costs only the remainder (the store clamps),
        // so affordability is judged against that, not the flat tap price.
        let tapCost = min(WalletStore.Policy.tapBoostAmount, remaining)
        boostButton.isEnabled = boostUndoableAmount > 0 || (remaining > 0 && boostBalance >= tapCost)
    }

    /// Internal, not private: the deferred menu resolves only at present
    /// time, which a unit test can't trigger — the builder is the seam.
    func currentBoostMenuActions() -> [UIMenuElement] {
        // The rail anchor's exact menu: Max (the cap's remainder bounded by
        // the balance), the fixed denomination(s), Undo while the session
        // holds something.
        let remaining = max(0, WalletStore.Policy.perTargetBoostCap - boostSpentTotal)
        let maxAmount = min(remaining, boostBalance)
        var actions: [UIMenuElement] = []

        let shownMax = maxAmount > 0
            ? maxAmount
            : (remaining > 0 ? remaining : WalletStore.Policy.perTargetBoostCap)
        let maxAction = UIAction(
            title: "Max (\(shownMax) points)",
            image: UIImage(systemName: "star.fill")
        ) { [weak self] _ in self?.onBoost?(maxAmount) }
        if maxAmount <= 0 { maxAction.attributes = .disabled }
        actions.append(maxAction)

        for amount in WalletStore.Policy.boostDenominations.reversed() {
            let action = UIAction(
                title: "\(amount) points",
                image: UIImage(systemName: "star.fill")
            ) { [weak self] _ in self?.onBoost?(amount) }
            if amount > boostBalance || amount > remaining { action.attributes = .disabled }
            actions.append(action)
        }
        if boostUndoableAmount > 0 {
            actions.append(UIAction(
                title: "Undo boosts (\(boostUndoableAmount))",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: .destructive
            ) { [weak self] _ in self?.onBoostUndo?() })
        }
        return actions
    }

    /// The refund's receipt: the confirmation float mirrored — a cool "−N"
    /// sinking off the button. White, not gold: an undo is not a payout.
    func playBoostRefund(amount: Int) {
        guard boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "−\(amount)"
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: boostButton.center.x, y: boostButton.frame.minY - Spacing.sm)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        addSubview(label)
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y += 14
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y += 20
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    /// The spend's visible receipt: a gold "+N" born on the boost button that
    /// rises and dissolves, plus a press-bounce on the button — the rail
    /// anchor's theatre (`SnapChromeView.playBoostConfirmation`), replayed on
    /// this surface so one spend looks the same wherever it was made. The bar
    /// doesn't clip, so the label may rise past its top edge by design.
    func playBoostConfirmation(amount: Int) {
        guard boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "+\(amount)"
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
        label.textColor = .systemYellow
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        label.center = CGPoint(x: boostButton.center.x, y: boostButton.frame.minY - Spacing.sm)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        addSubview(label)
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                label.center.y -= 18
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                label.center.y -= 26
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            label.removeFromSuperview()
        }
        boostButton.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(
            withDuration: 0.5, delay: 0,
            usingSpringWithDamping: 0.45, initialSpringVelocity: 4,
            options: [.allowUserInteraction]
        ) {
            self.boostButton.transform = .identity
        }
    }

    /// The refusal: a head-shake on the boost button — the wallet couldn't
    /// cover the spend, nothing changed, and no label flies (a "-0" would
    /// read as a payout). The host pairs it with the error haptic.
    func playBoostDenied() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 6, -4, 3, -1, 0]
        shake.duration = 0.4
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        boostButton.layer.add(shake, forKey: "boost.denied")
    }

    /// The trailing slot's three-state toggle:
    ///   keyboard OPEN, field empty → dismiss-keyboard chevron
    ///   keyboard OPEN, has text    → send (also while a send is in flight)
    ///   keyboard CLOSED, empty     → 🎙 microphone (voice note)
    /// Both idle faces belong to a FEED ENGAGEMENT; the pushed comments
    /// screen wires no page-swipe and keeps a permanent send. Swapped as
    /// short crossfades — the slot swap animates alpha, the utility glyph
    /// its own cross-dissolve — never a pop.
    private func updateTrailingButtons(animated: Bool) {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isSending
        // The page-swipe drive is the engagement's marker — BOTH media and
        // text posts wire it (the ✕ that used to distinguish them is gone
        // from this bar entirely). The pushed comments SCREEN wires nothing
        // and keeps its permanent send.
        let isFeedEngagement = onPageSwipe != nil
        let showsKeyboardDismiss = isFeedEngagement && isKeyboardOpen && !hasText
        // The mic owns the slot whenever an engaged bar is idle — keyboard
        // down, draft parked or not (send needs the keyboard up).
        let showsMic = isFeedEngagement && !isKeyboardOpen
        let showsSend = isSending || !(showsKeyboardDismiss || showsMic)
        let apply = {
            self.sendButton.alpha = showsSend ? 1 : 0
            self.utilityButton.alpha = showsSend ? 0 : 1
        }
        sendButton.isUserInteractionEnabled = showsSend
        utilityButton.isUserInteractionEnabled = !showsSend

        let wantsKeyboardDismiss = showsKeyboardDismiss
        if wantsKeyboardDismiss != utilityShowsKeyboardDismiss {
            utilityShowsKeyboardDismiss = wantsKeyboardDismiss
            let swapGlyph = {
                self.utilityButton.configuration?.image = UIImage(
                    systemName: wantsKeyboardDismiss ? "keyboard.chevron.compact.down" : "mic",
                    withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
                )
                self.utilityButton.accessibilityLabel =
                    wantsKeyboardDismiss ? "Dismiss keyboard" : "Record voice comment"
            }
            if animated {
                UIView.transition(
                    with: utilityButton, duration: 0.15,
                    options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: swapGlyph
                )
            } else {
                swapGlyph()
            }
        }

        if animated {
            UIView.animate(withDuration: 0.15, animations: apply)
        } else {
            apply()
        }
    }

    /// Grows the field with its content up to `maxLines`, then hands the
    /// overflow to the text view's own scrolling.
    private func updateFieldHeight() {
        guard textView.bounds.width > 0 else { return }
        let insets = textView.textContainerInset
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let maxHeight = ceil(lineHeight * Metrics.maxLines) + insets.top + insets.bottom
        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let target = min(max(ceil(fitting), Metrics.controlSize), maxHeight)

        let scrolls = fitting > maxHeight
        if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
        if fieldHeight.constant != target { fieldHeight.constant = target }
    }
}

extension CommentsInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = textView.hasText
        updateTrailingButtons(animated: true)
        updateFieldHeight()
    }
}

/// Holds notification tokens and unregisters them on its own deallocation
/// (when the owning object is released). `@unchecked Sendable` so its
/// `deinit` may run off the main actor; `removeObserver` is itself
/// thread-safe, and the tokens are only mutated on the main actor at setup
/// time.
///
/// Internal rather than file-private: the comments view controller needs the
/// same escape hatch for its active-profile observer, and a nonisolated
/// `deinit` cannot touch main-actor state to unregister by hand.
final class NotificationObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
