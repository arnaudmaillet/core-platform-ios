import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import UIKit

/// The comments composer — and, since the conversation became the text post's
/// screen, the MESSAGES composer too — in the app's native Liquid Glass
/// grammar: a floating glass capsule field that grows with its text, and a
/// round prominent-glass send button sharing its bottom baseline. (It began as
/// a replica of the chat's own input bar, which is gone: this is the one
/// composer now.) It owns no keyboard logic — the host pins its bottom to
/// `view.keyboardLayoutGuide.topAnchor`.
///
/// AN INPUT ROW AND A TRAILING COLUMN, one view:
///
///     ——————————————————————[stake]
///     ——————————————————————[mic/send]
///     [avatar][field      ]  ↑ columnLift
///
/// The INPUT ROW — avatar and field — is the bar's bottom edge: a host rests
/// the bar `SnapActionColumn.inputRestingGap` above its footer line, which is
/// `SnapActionColumn.glassGap` above the toolbar's glass (asked 2026-10-01: the field sat too far
/// above the toolbar). The trailing COLUMN — the mic/send slot and the stake
/// (boost) bubble over it — keeps the place it had before the row moved down:
/// it stands `columnLift` off the bar's bottom, so it is a little higher than
/// the field (accepted). The stake is the post's headline action, at UIKit's
/// default glass-button size; it rides the field's top when a growing field
/// outgrows the slot. Everything is INSIDE the bar's bounds, so the bar's
/// height (and `restingHeight(for:)`) include it and every host's clearance
/// follows; the empty run left of the column is NOT part of the bar for
/// touches (`point(inside:with:)`), so the stream behind it keeps its taps.
///
/// `showsStake = false` (a conversation: there is nothing to like) leaves the
/// column the slot alone.
///
/// **`-snap-layout-v2` (experimental, `usesActionColumn`):** the stake and
/// the slot are the trailing ACTION COLUMN's two bubbles (`SnapActionColumn`)
/// — both the comment band's height, one md apart — standing on the media
/// layout's like and repost bubbles exactly. The stake holds its station over
/// the slot, and a growing field rises BESIDE it. With a `railFace` the slot
/// is ONE glass button wearing the host's action — REPOST on a post, PIN in a
/// conversation — that turns into the SEND arrow while there is text (a symbol
/// replace), and the voice note moves INTO the field as a waveform beside the
/// emote button.
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
    /// engagement (so the idle slot wears the microphone); hosts that leave
    /// it nil (the pushed comments screen) have no page-swipe and keep a
    /// permanent send.
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

    /// What the rail slot wears at rest under `-snap-layout-v2` — see
    /// `railFace`.
    enum RailFace: Equatable {
        /// The voice note in the slot (the classic mic, the column's waveform).
        case voice
        /// The post's repost — drawn without an action today, like the
        /// toolbar's (`onRailAction` is the host's to wire).
        case repost
        /// This conversation pinned to the top of the inbox, or not.
        case pin(isPinned: Bool)
    }

    /// `-snap-layout-v2`: the slot's resting face. Anything but `.voice` makes
    /// the slot one glass button that wears this face over an empty field and
    /// the send arrow over a draft, and puts the waveform inside the field.
    /// Ignored without the action column.
    var railFace: RailFace = .voice {
        didSet {
            guard railFace != oldValue else { return }
            applyRailMode()
        }
    }

    /// Whether the rail face can act — a conversation that does not exist
    /// yet has nothing to pin. Send is never held back by it.
    var isRailFaceEnabled = true {
        didSet { updateTrailingButtons(animated: false) }
    }

    /// The rail face was tapped over an empty field (repost, pin). A tap over
    /// a draft sends instead.
    var onRailAction: (() -> Void)?

    /// Whether the column carries the stake bubble. A conversation's does not:
    /// there is nothing there to like. The slot stays where it was.
    var showsStake = true {
        didSet {
            guard showsStake != oldValue else { return }
            applyStakeStation()
        }
    }

    /// The bar's height at rest in `category`: the trailing column (the slot,
    /// the stake over it, both lifted `columnLift` off the bottom), or one
    /// empty line never less than the field's floor when a large text size
    /// makes the field the taller. For a host that places something against
    /// the resting bar before it is laid out.
    ///
    /// ⚠️ NOT A CONSTANT. The field grows with the text size — 38pt up to the
    /// large sizes, about 80pt at the largest accessibility size — so this
    /// asks a text view set up like the bar's own (`updateFieldHeight`), and
    /// gets the answer the bar will reach. Cached per size.
    ///
    /// With `actionColumn` (`-snap-layout-v2`) the column is two bubbles and
    /// their gap, and the field grows beside the stake rather than under it.
    static func restingHeight(
        for category: UIContentSizeCategory, actionColumn: Bool = false, showsStake: Bool = true
    ) -> CGFloat {
        let field: CGFloat
        if let cached = restingFieldHeights[category] {
            field = cached
        } else {
            let probe = UITextView()
            probe.font = .preferredFont(
                forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
            )
            probe.textContainerInset = UIEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
            let fitting = probe.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
            field = max(ceil(fitting), Metrics.controlSize)
            restingFieldHeights[category] = field
        }
        let lift = SnapActionColumn.columnLift(actionColumn: actionColumn)
        guard actionColumn else {
            let stake = showsStake ? stakeRowHeight : 0
            // The stake rides whichever is higher: the slot, or the field.
            return max(lift + Metrics.controlSize, field) + stake
        }
        let bubble = SnapActionColumn.bubbleSize
        let column = lift + bubble + (showsStake ? bubble + SnapActionColumn.gap : 0)
        return max(column, field)
    }

    private static var restingFieldHeights: [UIContentSizeCategory: CGFloat] = [:]

    /// What the stake row adds above the input row: the bubble and the gap
    /// under it. A constant — the bubble does not scale with the text size,
    /// like every other round control on the bar.
    static let stakeRowHeight: CGFloat = Metrics.stakeButtonSize + Metrics.stakeRowGap

    private enum Metrics {
        static let maxLines: CGFloat = 4
        static let controlSize: CGFloat = 38
        /// The emote toggle inside the field: a 30pt target on the 38pt line.
        static let emoteToggleWidth: CGFloat = 30
        /// The face FILLS its 38pt bubble, edge to edge — the bubble's own
        /// capsule clip is the disc's circle. It used to sit inset at 30pt so
        /// the glass read as a rim around it; that ring of glass read as a
        /// margin instead, and the face is the thing worth the room.
        static let avatarDiameter: CGFloat = controlSize
        /// The stake bubble: UIKit's default glass-button size, a notch above
        /// the input row's 38pt controls — the bar's one action on the post,
        /// sized as a system button rather than as a peer of the field.
        static let stakeButtonSize: CGFloat = 44
        /// Between the stake bubble and the input row below it.
        static let stakeRowGap: CGFloat = Spacing.sm
    }

    /// The viewer's face, leading the bar — the composer's answer to the
    /// question every comment row already answers. Same contract as those
    /// rows: the monogram is the RENDERED identity, drawn immediately; the
    /// picture layers over it and never replaces it, so there is no empty
    /// disc and no third loading state.
    private let avatarView = MonogramAvatarView(diameter: Metrics.avatarDiameter)
    private let avatarImageView = AvatarImageView()
    /// The glass bubble the avatar sits in, and the button that owns its
    /// touches. The bubble matches the mic/send button at the row's other end — the composer
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
    /// The emote panel and the inline `:query` strip for this field; its
    /// smiley sits at the field's trailing end, where iMessage keeps its own.
    private lazy var emotes = EmoteKeyboard(textView: textView)
    private let boostButton = UIButton(configuration: .glass())
    /// The boost's slot, on a post that does not exist yet: who will see it.
    /// See `visibilityMenu`.
    private let visibilityButton = UIButton(configuration: .glass())
    private let sendButton = UIButton(configuration: .prominentGlass())
    /// The trailing slot's idle face (send's overlay partner): the
    /// MICROPHONE (voice note), keyboard up or down. Send takes the slot
    /// while there is text to send (or a submission in flight).
    ///
    /// It used to morph into a dismiss-keyboard chevron while the keyboard
    /// was up over an empty field. A tap on the stream retires the keyboard
    /// (the hosts' stream tap), so the chevron only duplicated it — at the
    /// cost of the slot changing meaning under the thumb.
    private let utilityButton = UIButton(configuration: .glass())
    /// `-snap-layout-v2` with a `railFace`: the slot as ONE button — the
    /// host's action (repost, pin) over an empty field, send over a draft —
    /// swapping its glyph with a symbol replace instead of crossfading two
    /// buttons. Send and the mic stand down while it shows.
    private let railButton = UIButton(configuration: .glass())
    /// The voice note's door when the rail slot wears the host's action: a
    /// waveform INSIDE the field, beside the emote button.
    private let fieldVoiceButton = UIButton(configuration: .plain())
    /// Whether the keyboard is up, driven by the keyboardWillShow/Hide
    /// notifications (the engaged bar is the screen's only text input, so
    /// the global signal is unambiguous). It gates the page-swipe drive and
    /// the idle-dismiss seam — no longer the trailing face. Internal setter
    /// for tests: both are unit-tested without driving a real keyboard.
    private(set) var isKeyboardOpen = false
    /// Removes the keyboard observers on release — a nonisolated deinit
    /// cannot touch main-actor state, so the tokens live in a bag whose
    /// own deinit does the unregistering (the VC-side pattern).
    private let keyboardObservers = NotificationObserverTokenBag()
    private var fieldHeight: NSLayoutConstraint!
    /// The two geometries' own constraints (everything else is shared):
    /// exactly one set is active — see `applyActionColumn`.
    private var classicConstraints: [NSLayoutConstraint] = []
    private var actionColumnConstraints: [NSLayoutConstraint] = []
    /// The slot's bottom: `columnLift` above the bar's (the input row's).
    private var slotBottom: NSLayoutConstraint!
    /// The stake's claim on the bar's top — off while `showsStake` is false.
    private var stakeStationConstraints: [NSLayoutConstraint] = []
    /// The emote toggle's trailing edge: the field's end, or the waveform's
    /// leading edge while the waveform is in the field.
    private var emoteAtFieldEnd: NSLayoutConstraint!
    private var fieldVoiceConstraints: [NSLayoutConstraint] = []

    /// `-snap-layout-v2`: the stake and mic/send become the action column's
    /// two bubbles (`SnapActionColumn`), the mic a waveform. Off by default —
    /// the HOST decides, because the host is the one that rests the bar on
    /// the column's line.
    var usesActionColumn = false {
        didSet {
            guard usesActionColumn != oldValue else { return }
            applyActionColumn()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
        textView.delegate = self
        // The field's trailing end holds the emote toggle; the text stops
        // short of it, and the toggle holds the last line's station as the
        // field grows (bottom-anchored, like the round controls around it).
        let emoteToggle = emotes.toggleButton
        // The `:query` strip floats above the WHOLE bar, not the field: over
        // the field it would lie across the stake bubble.
        emotes.suggestionAnchor = self
        emoteToggle.tintColor = .secondaryLabel
        textView.translatesAutoresizingMaskIntoConstraints = false
        emoteToggle.translatesAutoresizingMaskIntoConstraints = false
        field.contentView.addSubview(textView)
        field.contentView.addSubview(emoteToggle)
        emoteAtFieldEnd = emoteToggle.trailingAnchor.constraint(
            equalTo: field.contentView.trailingAnchor, constant: -Spacing.xs
        )
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: field.contentView.leadingAnchor),
            textView.topAnchor.constraint(equalTo: field.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            textView.trailingAnchor.constraint(equalTo: emoteToggle.leadingAnchor),
            emoteAtFieldEnd,
            emoteToggle.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            emoteToggle.widthAnchor.constraint(equalToConstant: Metrics.emoteToggleWidth),
            emoteToggle.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])
        // The waveform, when the rail slot wears the host's action: after the
        // emote button, at the field's end — the voice note's place in
        // iMessage's own field. Joins the field only then (`applyRailMode`).
        fieldVoiceButton.configuration?.image = UIImage(
            systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        fieldVoiceButton.configuration?.contentInsets = .zero
        fieldVoiceButton.tintColor = .secondaryLabel
        fieldVoiceButton.accessibilityLabel = "Record voice comment"
        fieldVoiceButton.addAction(UIAction { [weak self] _ in self?.utilityTapped() }, for: .primaryActionTriggered)
        fieldVoiceButton.translatesAutoresizingMaskIntoConstraints = false
        fieldVoiceButton.isHidden = true
        field.contentView.addSubview(fieldVoiceButton)
        fieldVoiceConstraints = [
            emoteToggle.trailingAnchor.constraint(equalTo: fieldVoiceButton.leadingAnchor),
            fieldVoiceButton.trailingAnchor.constraint(equalTo: field.contentView.trailingAnchor, constant: -Spacing.xs),
            fieldVoiceButton.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            fieldVoiceButton.widthAnchor.constraint(equalToConstant: Metrics.emoteToggleWidth),
            fieldVoiceButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ]

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
            // Short of the emote toggle: "Comment as …" runs under it otherwise.
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: emotes.toggleButton.leadingAnchor)
        }

        // The native bubble-glass token (the chat bar's exact contract):
        // the corner configuration drives the glass shape itself, so the
        // caps stay circular at one line, hold that radius as the field
        // grows, and keep the effect's own crisp boundary refraction.
        field.clipsToBounds = true
        field.cornerConfiguration = .capsule(maximumRadius: Metrics.controlSize / 2)

        // The boost (stake) control, on its own row above mic/send: tap
        // spends the default denomination, long-press opens the amount menu
        // (the rail anchor's exact contract — one post, two surfaces, one
        // behavior).
        boostButton.configuration?.image = PointsSymbol.glyphImage(
            UIImage.SymbolConfiguration(weight: .semibold)
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
            title: StakeMenu.title,
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.currentBoostMenuActions() ?? [])
                },
            ]
        )

        visibilityButton.configuration?.image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        visibilityButton.configuration?.cornerStyle = .capsule
        visibilityButton.accessibilityLabel = "Post visibility"
        visibilityButton.showsMenuAsPrimaryAction = true
        visibilityButton.isHidden = true

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

        // ONE glyph, swapped in place: repost/pin ↔ send is a symbol REPLACE on
        // the button's own image, so the bubble never blinks or moves.
        railButton.configuration?.cornerStyle = .capsule
        railButton.configuration?.symbolContentTransition = UISymbolContentTransition(.replace)
        railButton.addAction(UIAction { [weak self] _ in self?.railTapped() }, for: .primaryActionTriggered)
        railButton.isHidden = true

        // The keyboard axis: the page-swipe gate and the idle-dismiss seam.
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
        // The button is LAST and full-bleed over the disc, so the whole 38pt
        // bubble is the tap target and owns the menu.
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
        addSubview(railButton)
        addSubview(boostButton)
        addSubview(visibilityButton)
        avatarBubble.translatesAutoresizingMaskIntoConstraints = false
        boostButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        utilityButton.translatesAutoresizingMaskIntoConstraints = false
        railButton.translatesAutoresizingMaskIntoConstraints = false
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        // The INPUT row, leading to trailing: the viewer's AVATAR, then the
        // field, which owns all the flexible width and ends `sm` short of the
        // trailing COLUMN. The row is the bar's bottom edge — the host rests
        // that edge on the toolbar — and the field grows upward from it.
        //
        // The column: the slot (mic and send OVERLAY it and crossfade; or the
        // rail button wears it alone) stands `columnLift` off the bar's
        // bottom, where it stood before the row moved down; the stake bubble
        // stands over it. The avatar opens the row (a composer says who is
        // speaking before it offers anything else); it is silent and never
        // moves.
        slotBottom = sendButton.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -SnapActionColumn.columnLift(actionColumn: false)
        )
        NSLayoutConstraint.activate([
            fieldHeight,
            avatarBubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatarBubble.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            avatarBubble.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            avatarBubble.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            field.leadingAnchor.constraint(equalTo: avatarBubble.trailingAnchor, constant: Spacing.sm),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Spacing.sm),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            slotBottom,
            sendButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            utilityButton.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            utilityButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            utilityButton.widthAnchor.constraint(equalTo: sendButton.widthAnchor),
            utilityButton.heightAnchor.constraint(equalTo: sendButton.heightAnchor),
            railButton.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            railButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            railButton.widthAnchor.constraint(equalTo: sendButton.widthAnchor),
            railButton.heightAnchor.constraint(equalTo: sendButton.heightAnchor),
            boostButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The boost's own station: the two never show at once.
            visibilityButton.centerXAnchor.constraint(equalTo: boostButton.centerXAnchor),
            visibilityButton.centerYAnchor.constraint(equalTo: boostButton.centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalTo: boostButton.widthAnchor),
            visibilityButton.heightAnchor.constraint(equalTo: boostButton.heightAnchor),
        ])
        // The bar's TOP is the highest of what it holds: required floors
        // above, and hugs at DISTINCT priorities (equal ones would leave the
        // solver a choice it could make differently pass to pass) — the
        // stake's first (`stakeStationConstraints`), then the field's, then
        // the slot's.
        let fieldHug = field.topAnchor.constraint(equalTo: topAnchor)
        fieldHug.priority = UILayoutPriority(250)
        let slotHug = sendButton.topAnchor.constraint(equalTo: topAnchor)
        slotHug.priority = UILayoutPriority(249)
        NSLayoutConstraint.activate([fieldHug, slotHug])
        let stakeHug = boostButton.topAnchor.constraint(equalTo: topAnchor)
        stakeHug.priority = UILayoutPriority(251)
        stakeStationConstraints = [
            boostButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stakeHug,
        ]
        NSLayoutConstraint.activate(stakeStationConstraints)
        // The classic stake: over the slot, and over the field too once a
        // growing field rises past the slot — it rides the higher of the two.
        let stakeOnSlot = boostButton.bottomAnchor.constraint(
            equalTo: sendButton.topAnchor, constant: -Metrics.stakeRowGap
        )
        stakeOnSlot.priority = UILayoutPriority(500)
        classicConstraints = [
            sendButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            boostButton.bottomAnchor.constraint(lessThanOrEqualTo: sendButton.topAnchor, constant: -Metrics.stakeRowGap),
            boostButton.bottomAnchor.constraint(lessThanOrEqualTo: field.topAnchor, constant: -Metrics.stakeRowGap),
            stakeOnSlot,
            boostButton.widthAnchor.constraint(equalToConstant: Metrics.stakeButtonSize),
            boostButton.heightAnchor.constraint(equalToConstant: Metrics.stakeButtonSize),
        ]
        NSLayoutConstraint.activate(classicConstraints)

        // The action column's set, built now and activated by the host's
        // switch (`usesActionColumn`).
        buildActionColumnConstraints()

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

    /// The bar owns its input row and its column's bubbles — not the empty
    /// run to the column's left. That run is inside the bar's bounds only
    /// because the column is; the stream glides behind it, and a tap or a drag
    /// there belongs to the rows it shows.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if point.y >= field.frame.minY { return true }
        if sendButton.frame.contains(point) { return true }
        guard showsStake else { return false }
        let station = visibilityMenu == nil ? boostButton : visibilityButton
        return station.frame.contains(point)
    }

    /// The action column's geometry (`-snap-layout-v2`). Bubble size is the
    /// comment band's height — read once, here, like the band reads its own
    /// at init. The stake holds its station over the slot: a growing field
    /// rises beside it, not under it.
    private func buildActionColumnConstraints() {
        let bubble = SnapActionColumn.bubbleSize
        actionColumnConstraints = [
            sendButton.widthAnchor.constraint(equalToConstant: bubble),
            sendButton.heightAnchor.constraint(equalToConstant: bubble),
            boostButton.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -SnapActionColumn.gap),
            boostButton.widthAnchor.constraint(equalToConstant: bubble),
            boostButton.heightAnchor.constraint(equalToConstant: bubble),
        ]
    }

    /// The stake's station on or off the column (`showsStake`): its claim on
    /// the bar's top, and both of its faces.
    private func applyStakeStation() {
        if showsStake {
            NSLayoutConstraint.activate(stakeStationConstraints)
        } else {
            NSLayoutConstraint.deactivate(stakeStationConstraints)
        }
        boostButton.isHidden = !showsStake || visibilityMenu != nil
        visibilityButton.isHidden = !showsStake || visibilityMenu == nil
        setNeedsLayout()
    }

    /// Whether the slot is the one rail button (`railFace`), which needs the
    /// action column.
    private var usesRailButton: Bool { usesActionColumn && railFace != .voice }

    /// Puts the voice note where the slot's mode wants it — in the slot, or in
    /// the field beside the emote button — and refreshes the slot.
    private func applyRailMode() {
        let inField = usesRailButton
        if inField {
            emoteAtFieldEnd.isActive = false
            NSLayoutConstraint.activate(fieldVoiceConstraints)
        } else {
            NSLayoutConstraint.deactivate(fieldVoiceConstraints)
            emoteAtFieldEnd.isActive = true
        }
        fieldVoiceButton.isHidden = !inField
        updateTrailingButtons(animated: false)
        setNeedsLayout()
    }

    /// The column's glyphs: the like anchor's size, so the crossfade between
    /// the two layouts reads as ONE bubble. The classic bar keeps the system's.
    private var glyphConfiguration: UIImage.SymbolConfiguration {
        usesActionColumn
            ? UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            : UIImage.SymbolConfiguration(weight: .semibold)
    }

    /// Swaps the geometry and the faces: the column's lift and sizes, the
    /// waveform for the mic, the like anchor's glyph size on the column's
    /// bubbles, and the rail button when the host gave the slot a face.
    private func applyActionColumn() {
        if usesActionColumn {
            NSLayoutConstraint.deactivate(classicConstraints)
            NSLayoutConstraint.activate(actionColumnConstraints)
        } else {
            NSLayoutConstraint.deactivate(actionColumnConstraints)
            NSLayoutConstraint.activate(classicConstraints)
        }
        slotBottom.constant = -SnapActionColumn.columnLift(actionColumn: usesActionColumn)
        applyRailMode()
        utilityButton.configuration?.image = UIImage(
            systemName: usesActionColumn ? "waveform" : "mic", withConfiguration: glyphConfiguration
        )
        // The number face (a spend on the post) carries no image to resize.
        if boostSpentTotal == 0 {
            boostButton.configuration?.image = PointsSymbol.glyphImage(glyphConfiguration)
        }
        visibilityButton.configuration?.image = UIImage(systemName: "globe", withConfiguration: glyphConfiguration)
        setNeedsLayout()
    }

    /// The input row's top — the field's top edge, which rises as it grows.
    /// For a host whose chrome belongs to the input row rather than to the
    /// whole bar (the footer band, whose ramp the stake bubble floats in).
    var inputRowTopAnchor: NSLayoutYAxisAnchor { field.topAnchor }

    /// Whether the field holds the keyboard. A row tap on the stream then
    /// retires it instead of doing the row's own work — see the hosts'
    /// reply taps.
    var isEditingDraft: Bool { textView.isFirstResponder }

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
        #if DEBUG
        runEmoteKeyboardQAIfAsked()
        runComposerDraftQAIfAsked()
        #endif
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

    /// The idle face — the mic over an empty field — outside a feed
    /// engagement too. The conversation screen is the text page's bar without
    /// a pager behind it; everywhere else this stays false and the rule is
    /// exactly the page-swipe marker it always was.
    var showsIdleUtilityFaces = false {
        didSet { updateTrailingButtons(animated: false) }
    }

    /// The prompt when nobody is being replied to, overriding the comment
    /// wording ("Comment as …") — a conversation's field says "Message…".
    var defaultPlaceholder: String? {
        didSet { applyPlaceholder() }
    }

    /// The send button's spoken name. Nil is "Send comment"; the Text Post
    /// page's first send publishes the post, and says so.
    var sendAccessibilityLabel: String? {
        didSet {
            sendButton.accessibilityLabel = sendAccessibilityLabel ?? "Send comment"
            updateTrailingButtons(animated: false)
        }
    }

    /// The stake row's other face. A boost needs a post to land on; a post
    /// that does not exist yet has a different question for that station —
    /// who will see it. Non-nil swaps the heart for a globe that opens this
    /// menu; nil puts the heart back.
    var visibilityMenu: UIMenu? {
        didSet {
            visibilityButton.menu = visibilityMenu
            applyStakeStation()
        }
    }

    /// Every change to the draft, typed or set — for a host that keeps it (the
    /// Text Post page's drafts, and its guard against a swipe throwing it away).
    var onTextChange: ((String) -> Void)?

    #if DEBUG
    /// Types `text` and sends it, exactly as a tap on send would — for the
    /// simulator hooks, which cannot type into a field.
    func debugSend(_ text: String) {
        draftText = text
        sendTapped()
    }
    #endif

    /// Puts `text` into the draft — at the caret while the field is being
    /// edited, at the end otherwise — without sending. The emote strip's tap.
    func insertIntoComposer(_ text: String) {
        if textView.isFirstResponder {
            textView.insertText(text)
        } else {
            textView.text = (textView.text ?? "") + text
        }
        textViewDidChange(textView)
    }

    /// The mic's tap: the voice-note seam, keyboard up or down.
    private func utilityTapped() {
        onVoiceNote?()
    }

    /// The rail button's tap: send over a draft (or nothing while one is in
    /// flight), the host's action over an empty field.
    private func railTapped() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText || isSending {
            sendTapped()
        } else {
            onRailAction?()
        }
    }

    /// The keyboard seam behind the notification observers. Internal (not
    /// private) so what hangs on it is unit-testable without driving a real
    /// keyboard.
    func setKeyboardOpen(_ open: Bool) {
        guard open != isKeyboardOpen else { return }
        isKeyboardOpen = open
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
        } else if let defaultPlaceholder {
            placeholderLabel.text = defaultPlaceholder
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

    #if DEBUG
    private var ranComposerDraftQA = false

    /// `-composer-draft <text>` (DEBUG): puts `<text>` in the draft ~2 s after
    /// the bar is SHOWN (on screen, every ancestor opaque — an engagement's
    /// bar waits offstage at alpha 0), then empties it ~6 s later: the slot's
    /// two faces (send over a draft, the rest face over an empty field)
    /// without a keyboard, which the simulator does not show. Prints
    /// `[composer-draft] <epoch s> <step>` with the slot's face at each step.
    private func runComposerDraftQAIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !ranComposerDraftQA, let index = arguments.firstIndex(of: "-composer-draft"),
              index + 1 < arguments.count else { return }
        ranComposerDraftQA = true
        let text = arguments[index + 1]
        let report: @MainActor (String) -> Void = { [weak self] step in
            guard let self else { return }
            let face = self.usesRailButton
                ? "rail=\(self.railFaceSymbol ?? "-") label=\(self.railButton.accessibilityLabel ?? "-")"
                : "send.alpha=\(self.sendButton.alpha) mic.alpha=\(self.utilityButton.alpha)"
            let frame = self.window.map { self.convert(self.bounds, to: $0) } ?? .zero
            // stderr: unbuffered, so a detached `--stderr=` sink is live.
            FileHandle.standardError.write(Data(
                "[composer-draft] \(Int(Date().timeIntervalSince1970)) \(step) draft=\"\(self.draftText)\" \(face) frame=\(frame)\n".utf8
            ))
        }
        // SHOWN means on screen: every ancestor visible and opaque (a panel
        // is mounted on pages that are not the one showing), and the bar
        // inside the window's bounds.
        QAWait.until("-composer-draft", timeout: 30, { [weak self] in
            guard let self, let window = self.window, self.bounds.height > 0 else { return false }
            let ancestorsShown = sequence(first: self as UIView, next: \.superview)
                .allSatisfy { !$0.isHidden && $0.alpha > 0.99 }
            return ancestorsShown && window.bounds.contains(self.convert(self.bounds, to: window))
        }) {
            report("shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.draftText = text
                report("typed")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                self?.draftText = ""
                report("cleared")
            }
        }
    }

    private var ranEmoteKeyboardQA = false

    /// `-emote-keyboard-qa` (DEBUG): focuses the composer ~1 s after the bar
    /// reaches a window, then swaps keyboard → emote panel → keyboard →
    /// panel every 2.5 s, printing the bar's window y and the keyboard's
    /// frame at each settled stage (`[emote-kbd] …`). Taps cannot be
    /// scripted on the simulator, and "does the bar jump" is a question
    /// about two numbers; this prints them.
    private func runEmoteKeyboardQAIfAsked() {
        guard !ranEmoteKeyboardQA, ProcessInfo.processInfo.arguments.contains("-emote-keyboard-qa") else { return }
        ranEmoteKeyboardQA = true
        let report: @MainActor (String) -> Void = { [weak self] stage in
            guard let self, let window = self.window else { return }
            let bar = self.convert(self.bounds, to: window)
            let input = self.textView.inputView.map { String(describing: type(of: $0)) } ?? "system keyboard"
            print(String(format: "[emote-kbd] %.3f %@ input=%@ bar.minY=%.1f bar.maxY=%.1f panel.h=%.1f",
                         CACurrentMediaTime(), stage, input, bar.minY, bar.maxY,
                         self.textView.inputView?.bounds.height ?? -1))
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main
        ) { note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated {
                print(String(format: "[emote-kbd] %.3f keyboard end=(%.1f %.1f %.1f %.1f)",
                             CACurrentMediaTime(), end.minX, end.minY, end.width, end.height))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.focusComposer()
        }
        for stage in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + 2.5 * Double(stage + 1)) { [weak self] in
                report("stage\(stage)")
                if stage < 4 { self?.emotes.toggle() }
            }
        }
    }
    #endif

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
            title.foregroundColor = PointsSymbol.tint
            boostButton.configuration?.attributedTitle = title
            boostButton.configuration?.image = nil
            // `.glass()`'s default content insets leave a 38pt circle ~10pt
            // of text width, so "100" WRAPPED into a vertical digit stack
            // (measured in-sim). The number face zeroes them — the rail
            // anchor's recipe, whose circle never wrapped.
            boostButton.configuration?.contentInsets = .zero
        } else {
            boostButton.configuration?.attributedTitle = nil
            boostButton.configuration?.image = PointsSymbol.glyphImage(glyphConfiguration)
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
    ///
    /// `StakeMenu`'s — the rail's and every card's like chip's, one menu for
    /// one spend.
    func currentBoostMenuActions() -> [UIMenuElement] {
        StakeMenu.elements(
            for: StakeMenu.State(
                balance: boostBalance,
                stakedOnTarget: boostSpentTotal,
                undoable: boostUndoableAmount,
                perTargetCap: WalletStore.Policy.perTargetBoostCap,
                denominations: WalletStore.Policy.boostDenominations,
                tapAmount: WalletStore.Policy.tapBoostAmount
            ),
            stake: { [weak self] amount in self?.onBoost?(amount) },
            undo: { [weak self] in self?.onBoostUndo?() }
        )
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
        label.textColor = PointsSymbol.tint
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

    /// The trailing slot's two faces:
    ///   has text (or a send in flight) → send
    ///   empty                          → 🎙 microphone (voice note)
    /// The keyboard plays no part. The mic stays up while nothing is typed,
    /// and a draft is sendable with the keyboard down: a shared link or an
    /// emote lands in the field precisely to be sent, and a mic over a draft
    /// turned the one action there into a "not available" notice.
    /// The mic belongs to a FEED ENGAGEMENT, or to a bar that asks for it
    /// (`showsIdleUtilityFaces` — the conversation, the draft post); the
    /// pushed comments screen does neither and keeps a permanent send.
    /// Swapped as a short alpha crossfade, never a pop.
    ///
    /// With a rail face (`-snap-layout-v2`) the slot is the ONE rail button
    /// instead: the host's face over an empty field, the send arrow over a
    /// draft — a symbol replace on its glyph, no crossfade.
    private func updateTrailingButtons(animated: Bool) {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !isSending
        railButton.isHidden = !usesRailButton
        sendButton.isHidden = usesRailButton
        utilityButton.isHidden = usesRailButton
        if usesRailButton {
            applyRailFace(sends: hasText || isSending, canSend: hasText && !isSending)
            return
        }
        // The page-swipe drive is the engagement's marker — BOTH media and
        // text posts wire it. The conversation asks for the face explicitly;
        // the pushed comments SCREEN does neither and keeps its permanent
        // send.
        let isFeedEngagement = onPageSwipe != nil || showsIdleUtilityFaces
        let showsSend = isSending || !isFeedEngagement || hasText
        let apply = {
            self.sendButton.alpha = showsSend ? 1 : 0
            self.utilityButton.alpha = showsSend ? 0 : 1
        }
        sendButton.isUserInteractionEnabled = showsSend
        utilityButton.isUserInteractionEnabled = !showsSend

        if animated {
            UIView.animate(withDuration: 0.15, animations: apply)
        } else {
            apply()
        }
    }

    /// The rail button's face. Every write goes through the button's
    /// configuration, whose `symbolContentTransition` replaces the old glyph
    /// with the new one.
    private func applyRailFace(sends: Bool, canSend: Bool) {
        let symbol: String
        let label: String
        if sends {
            symbol = "arrow.up"
            label = sendAccessibilityLabel ?? "Send comment"
        } else {
            switch railFace {
            case .voice, .repost:
                symbol = PostActionSymbol.repost
                label = "Repost"
            case .pin(let isPinned):
                symbol = isPinned ? "pin.fill" : "pin"
                label = isPinned ? "Unpin conversation" : "Pin conversation"
            }
        }
        if railFaceSymbol != symbol {
            railFaceSymbol = symbol
            railButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: glyphConfiguration)
        }
        if railButton.configuration?.showsActivityIndicator != isSending {
            railButton.configuration?.showsActivityIndicator = isSending
        }
        railButton.accessibilityLabel = label
        railButton.isEnabled = sends ? canSend : isRailFaceEnabled
    }

    /// The symbol the rail button wears, so an unchanged face is not
    /// re-applied (a re-applied image would replay the replace).
    private var railFaceSymbol: String?

    #if DEBUG
    /// The rail button, for the specs that read its face and tap it.
    var debugRailButton: UIButton { railButton }
    /// The waveform inside the field.
    var debugFieldVoiceButton: UIButton { fieldVoiceButton }
    /// The symbol the rail button wears.
    var debugRailSymbol: String? { railButton.isHidden ? nil : railFaceSymbol }
    #endif

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
        onTextChange?(textView.text ?? "")
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
