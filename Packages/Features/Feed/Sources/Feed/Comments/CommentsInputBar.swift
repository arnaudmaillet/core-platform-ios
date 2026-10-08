import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import UIKit
import CoreModels
import CoreNavigation

/// The comments composer — and, since the conversation became the text post's
/// screen, the MESSAGES composer too — in the app's native Liquid Glass
/// grammar: a floating glass capsule field that grows with its text, with the
/// voice note and the send arrow INSIDE it. (It began as a replica of the
/// chat's own input bar, which is gone: this is the one composer now.)
///
/// AN INPUT ROW AND A TRAILING COLUMN, one view:
///
///     ——————————————————————╭stake╮
///     ——————————————————————╰─────╯
///     [avatar][field   ☺ 〰/↑][sound/pin]
///
/// The INPUT ROW — avatar and field — is the bar's bottom edge at rest: a host
/// rests the bar `SnapActionColumn.inputRestingGap` above its footer line,
/// which is `SnapActionColumn.glassGap` above the toolbar's glass (asked
/// 2026-10-01: the field sat too far above the toolbar). The trailing COLUMN —
/// the rail slot and the stake (boost) bubble over it — is the ACTION COLUMN's
/// two bubbles (`SnapActionColumn`): both the comment band's height, one md
/// apart, standing exactly on the media layout's like pill and sound bubble.
/// The slot rests on the field's line (#669), and the avatar, the field and
/// the slot are one row of `SnapActionColumn.bubbleSize` (#680). The stake (a
/// pill, #669) holds its station over the slot, and a growing
/// field rises BESIDE it. Everything is INSIDE the bar's bounds at rest, so
/// the bar's height (and `restingHeight(for:)`) include it and every host's
/// clearance follows; the empty run left of the column is NOT part of the bar
/// for touches (`point(inside:with:)`), so the stream behind it keeps its taps.
///
/// **THE KEYBOARD MOVES THE INPUT ROW, NEVER THE COLUMN** (asked 2026-10-02).
/// The host pins the BAR at its resting place for good and hands it the
/// keyboard's guide (`riseWithKeyboard(of:)`): only the avatar and the field
/// ride the keyboard's top, above the bar's own bounds, and the column's
/// bubbles stay on the media layout's coordinates (the keyboard covers them).
/// As the row rises clear of the column it WIDENS into the column's width —
/// a function of how far it has risen (`riseProgress(lift:clearance:)`), read
/// off the solved layout on every pass, so it follows the keyboard's own
/// animation and an interactive dismissal frame by frame.
///
/// The slot wears the host's action — REPOST on a post, PIN in a conversation,
/// nothing on a post that does not exist yet (`railFace`) — and nothing else:
/// typing never changes it. The field's trailing button is the voice note's
/// WAVEFORM over an empty field and the SEND arrow over a draft (a symbol
/// replace), beside the emote button.
///
/// `showsStake = false` (a conversation: there is nothing to like) leaves the
/// column the slot alone.
final class CommentsInputBar: UIView {
    /// Fired with trimmed, non-empty text; the field clears itself first.
    var onSend: ((String) -> Void)?
    /// Fired by the boost (star) button with what to spend — the tap's
    /// default amount, or a pick from the long-press menu (the default, or
    /// one ×100 shot). The spend itself is the host's affair (it owns the post
    /// identity and the wallet); the refusal comes back through
    /// `playBoostDenied`.
    var onBoost: ((WalletStakeSpend) -> Void)?
    /// Fired by the boost menu's Undo entry — the host refunds the session
    /// spend (it owns the tally and the wallet; the bar only shows the door).
    var onBoostUndo: (() -> Void)?
    /// Fired by the WAVEFORM inside the field, beside the emote button: the
    /// voice-note seam. Unwired for now — an honest affordance whose capture
    /// flow does not exist yet.
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
    /// the next post. Hosts that leave it nil (the pushed comments screen,
    /// the conversation) have no page-swipe.
    var onPageSwipe: ((PageSwipePhase, _ translation: CGFloat, _ velocity: CGFloat) -> Void)?

    /// Disables sending while a comment is in flight (spinner in the field's
    /// send arrow).
    var isSending = false {
        didSet { updateFieldAction() }
    }

    /// What the rail slot wears — see `railFace`.
    enum RailFace: Equatable {
        /// No bubble in the slot: a draft post, which has nothing to repost
        /// yet. The slot keeps its station (the stake's stands on it).
        case empty
        /// The post's repost — drawn without an action today, like the
        /// toolbar's (`onRailAction` is the host's to wire).
        case repost
        /// This conversation pinned to the top of the inbox, or not.
        case pin(isPinned: Bool)
        /// The post's sound (#671): the snap feed's sound bubble's cover, on
        /// that bubble's frame.
        case sound(SnapSoundFace)
    }

    /// The slot's face: ONE glass button wearing the host's action. It is the
    /// action and only the action — a draft never turns it into send (asked
    /// 2026-10-02: the send arrow lives in the field, and the column's bubbles
    /// never change meaning under the thumb).
    var railFace: RailFace = .empty {
        didSet {
            guard railFace != oldValue else { return }
            applyRailFace()
        }
    }

    /// Whether the rail face can act — a conversation that does not exist
    /// yet has nothing to pin. Send is never held back by it.
    var isRailFaceEnabled = true {
        didSet { applyRailFace() }
    }

    /// The rail face was tapped (repost, pin, the sound's mute), whatever the
    /// field holds.
    var onRailAction: (() -> Void)?
    /// The SOUND face was held: the host toggles the sound (#683). Other
    /// faces, and a post with no sound, ignore a hold.
    var onRailLongPress: (() -> Void)?

    @objc private func railHeld(_ recogniser: UILongPressGestureRecognizer) {
        guard recogniser.state == .began else { return }
        holdRail()
    }

    private func holdRail() {
        guard case .sound(let face) = railFace, face.isAvailable else { return }
        onRailLongPress?()
    }

    /// A recognised hold on the slot, for tests (`railHeld`'s `.began`).
    func debugHoldRail() { holdRail() }

    /// Whether the bar DRAWS its trailing column (the stake and the rail
    /// slot), or only RESERVES its room for a column drawn above it — the
    /// snap feed's page, whose like pill and sound bubble stay on screen
    /// when the comments take the page (#695). Reserved, the two buttons
    /// keep their stations — the resting height, the field's trailing inset
    /// and the keyboard's rise read the same frames — but draw nothing and
    /// take no touch.
    var hostsActionColumn = true {
        didSet {
            guard hostsActionColumn != oldValue else { return }
            railButton.isUserInteractionEnabled = hostsActionColumn
            boostButton.isUserInteractionEnabled = hostsActionColumn
            if hostsActionColumn {
                boostButton.alpha = 1
                redrawRailFace()
            } else {
                applyReservedColumn()
            }
        }
    }

    private func applyReservedColumn() {
        guard !hostsActionColumn else { return }
        railButton.alpha = 0
        boostButton.alpha = 0
        railCoverView.layer.setRecordSpinning(false)
    }

    /// Whether the column carries the stake bubble. A conversation's does not:
    /// there is nothing there to like. The slot stays where it was.
    var showsStake = true {
        didSet {
            guard showsStake != oldValue else { return }
            applyStakeStation()
        }
    }

    /// The bar's height at rest in `category`: the trailing column (the slot
    /// on the bottom line, the stake over it), or one
    /// empty line never less than the field's floor when a large text size
    /// makes the field the taller. For a host that places something against
    /// the resting bar before it is laid out.
    ///
    /// ⚠️ NOT A CONSTANT. The field grows with the text size — 38pt up to the
    /// large sizes, about 80pt at the largest accessibility size — so this
    /// asks a text view set up like the bar's own (`updateFieldHeight`), and
    /// gets the answer the bar will reach. Cached per size.
    ///
    /// The column is the slot, the stake and their gap (the slot alone
    /// without the stake) — the stake the like pill with the like face, a
    /// bubble without — and the field grows beside the stake rather than
    /// under it.
    static func restingHeight(
        for category: UIContentSizeCategory, showsStake: Bool = true, likeFace: Bool = true
    ) -> CGFloat {
        let bubble = SnapActionColumn.bubbleSize
        let column = bubble + (showsStake ? stakeSide(likeFace: likeFace) + SnapActionColumn.gap : 0)
        return max(column, restingInputRowHeight(for: category))
    }

    /// The INPUT ROW's height at rest in `category`: one empty line of the
    /// field, never less than its floor. What a host clears above a keyboard,
    /// where the row rides alone — the column stays at rest, under it.
    static func restingInputRowHeight(for category: UIContentSizeCategory) -> CGFloat {
        if let cached = restingFieldHeights[category] { return cached }
        let probe = UITextView()
        probe.font = .preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
        probe.textContainerInset = fieldInsets(for: probe.font)
        let fitting = probe.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        let field = max(ceil(fitting), Metrics.controlSize)
        restingFieldHeights[category] = field
        return field
    }

    /// How far the input row has risen with the keyboard, 0…1: its LIFT over
    /// the distance it takes to clear the column (`clearance`, from the row's
    /// resting bottom to the column's top). The field's width follows it —
    /// rest width at 0, the column's width taken at 1 — so the row widens
    /// exactly as it leaves the bubbles beside it behind, whatever the
    /// keyboard's height, and an interactive dismissal walks it back. Pure,
    /// for tests.
    static func riseProgress(lift: CGFloat, clearance: CGFloat) -> CGFloat {
        guard lift > 0 else { return 0 }
        guard clearance > 0 else { return 1 }
        return min(1, lift / clearance)
    }

    /// The field's trailing edge from the bar's at `progress`: the column's
    /// width and the gap before it at rest (0), nothing at 1. Pure, for tests.
    @MainActor static func fieldTrailingInset(progress: CGFloat) -> CGFloat {
        let rest = SnapActionColumn.bubbleSize + Spacing.sm
        return rest * (1 - min(max(progress, 0), 1))
    }

    private static var restingFieldHeights: [UIContentSizeCategory: CGFloat] = [:]

    /// The text's insets in the field: `sm` at the sides, and above and below
    /// whatever centres ONE line in the field's resting height (#683) — with
    /// `sm` the line sat high in the bubble-tall field, under a placeholder
    /// centred on it. Never less than `sm`, so a large text size still grows
    /// the field as before.
    ///
    /// The line is MEASURED, not read off the font: a text view lays one line
    /// out a little taller than `lineHeight`, and a field centred on the
    /// font's figure came out two points taller than the bubbles.
    @MainActor static func fieldInsets(for font: UIFont?) -> UIEdgeInsets {
        let font = font ?? .appFont(forTextStyle: .body)
        let line: CGFloat
        if let cached = measuredLines[font.pointSize] {
            line = cached
        } else {
            let probe = UITextView()
            probe.font = font
            probe.isScrollEnabled = false
            probe.textContainerInset = .zero
            line = probe.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
            measuredLines[font.pointSize] = line
        }
        let vertical = max(Spacing.sm, floor((Metrics.controlSize - line) / 2 * 2) / 2)
        return UIEdgeInsets(top: vertical, left: Spacing.sm, bottom: vertical, right: Spacing.sm)
    }

    private static var measuredLines: [CGFloat: CGFloat] = [:]

    enum Metrics {
        static let maxLines: CGFloat = 4
        /// The field's resting line, the avatar's side and the field's
        /// trailing cap: the column's bubble (#680) — the avatar, the field
        /// and the rail slot are ONE row, the comment band's height, so the
        /// row reads as the media layout's sound bubble's line.
        @MainActor static var controlSize: CGFloat { SnapActionColumn.bubbleSize }
        /// The emote toggle inside the field: 32pt wide on the 38pt line —
        /// room for its widest face, the keyboard glyph (26pt), with a margin
        /// either side.
        static let emoteToggleWidth: CGFloat = 32
        /// The field's trailing button is the field's trailing CAP: a 38pt
        /// square flush with the field's end, so its glyph is concentric
        /// with the capsule's round end. The send disc (29pt) used to stand
        /// in a 30pt column 4pt in from the edge — no margin at all, and its
        /// sides came out shaved (asked 2026-10-02).
        @MainActor static var fieldActionSide: CGFloat { controlSize }
        /// The smallest touch target the field's two buttons answer to —
        /// UIKit's 44pt, reached by `hitTest` around their drawn frames,
        /// which the 38pt line cannot hold.
        static let minimumHitSide: CGFloat = 44
        /// The face sits INSET in its glass bubble, a ring of glass around it
        /// — the sound bubble's cover, at the cover's size, so the row's two
        /// ends read as one family of controls (the owner, 2026-10-08, #692).
        @MainActor static var avatarDiameter: CGFloat { controlSize - 10 }
    }

    /// The viewer's face, leading the bar — the composer's answer to the
    /// question every comment row already answers. Same contract as those
    /// rows: the monogram is the RENDERED identity, drawn immediately; the
    /// picture layers over it and never replaces it, so there is no empty
    /// disc and no third loading state.
    private let avatarView = MonogramAvatarView(diameter: Metrics.avatarDiameter)
    private let avatarImageView = AvatarImageView()
    /// The glass bubble the avatar sits in, and the button that owns its
    /// touches. The bubble matches the input row's other glass controls — the composer
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
    /// The slot: ONE glass button wearing the host's action (`railFace`) —
    /// repost, pin, or hidden on a draft. It is the column's lower bubble and
    /// the station the stake stands on, so it is laid out even while hidden.
    private let railButton = UIButton(configuration: .glass())
    /// The SOUND face's cover, over the slot's glass rather than as its
    /// image: a record that turns while the song plays (#692) — and the mute
    /// badge beside it, which does not.
    private let railCoverView = UIImageView()
    private let railMutedBadge = UIImageView()
    /// The field's trailing button, after the emote button: the voice note's
    /// WAVEFORM over an empty field, the SEND arrow over a draft (or while one
    /// is in flight) — one button, its glyph swapped with a symbol replace,
    /// keyboard up or down. A draft is sendable with the keyboard down: a
    /// shared link or an emote lands in the field precisely to be sent.
    ///
    /// Send used to take the RAIL slot (repost/pin → send while typing), and
    /// before that a glass button of its own beside the field. Both are gone
    /// (asked 2026-10-02): the column never changes meaning under the thumb,
    /// and the send arrow sits where the eye already is, in the field.
    private let fieldActionButton = UIButton(configuration: .plain())
    /// A guest's whole input row: one glass button over the avatar's and the
    /// field's span, in their place — a guest has no one to post as and
    /// nothing to type until they sign up (`applyGuestFace`). Built only for
    /// a guest, so a member's bar holds exactly what it always did.
    private var signUpButton: UIButton?
    /// Whether the keyboard is up, driven by the keyboardWillShow/Hide
    /// notifications (the engaged bar is the screen's only text input, so
    /// the global signal is unambiguous). It gates the page-swipe drive, the
    /// hosts' pull-to-close and the idle-dismiss seam — never a face. Internal
    /// setter for tests: all of them are unit-tested without a real keyboard.
    private(set) var isKeyboardOpen = false
    /// Removes the keyboard observers on release — a nonisolated deinit
    /// cannot touch main-actor state, so the tokens live in a bag whose
    /// own deinit does the unregistering (the VC-side pattern).
    private let keyboardObservers = NotificationObserverTokenBag()
    private var fieldHeight: NSLayoutConstraint!
    /// The stake's claim on the bar's top — off while `showsStake` is false.
    private var stakeStationConstraints: [NSLayoutConstraint] = []
    /// Where the input row RESTS: the bar's bottom, the field's height. The
    /// bar's height is measured from it, never from the field itself, so a
    /// field lifted by the keyboard leaves the bar — and the column — exactly
    /// where they were.
    private let restingInputRow = UILayoutGuide()
    /// The field's edge inside the column's width: `fieldTrailingInset`, set
    /// from the rise on every layout pass.
    private var fieldTrailing: NSLayoutConstraint!
    /// The field's bottom held `Spacing.sm` over the keyboard's top — the
    /// host's guide (`riseWithKeyboard(of:)`), active while `tracksKeyboard`.
    private var keyboardCeiling: NSLayoutConstraint?

    /// The column's glyphs: the like anchor's size, so the crossfade between
    /// the two layouts reads as ONE bubble.
    private static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    /// The field button's two faces. Send is the filled arrow in a disc —
    /// iMessage's own, at home inside a field — in `sendTint`; the waveform
    /// is the field's quiet ink, like the emote button beside it.
    static let waveformSymbol = "waveform"
    static let sendSymbol = "arrow.up.circle.fill"
    /// Every glyph in the field has a POINT SIZE of its own — see the
    /// trailing buttons' constraints in `init`.
    static let waveformConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
    static let sendConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    static let emoteToggleConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    /// The send arrow's colour, on every host: system blue, NAMED rather than
    /// inherited. It was `.tintColor`, which resolves against the button's
    /// ancestors — and came out grey in a conversation while the post's was
    /// blue (asked 2026-10-02: one blue for every composer).
    static let sendTint: UIColor = .systemBlue
    /// The waveform's ink: the field's quiet one, the emote button's.
    static let waveformTint: UIColor = .secondaryLabel

    /// The waveform ↔ send swap, both ways: the old glyph shrinks away and
    /// the new one grows into its place, at 2.5× the system's speed — about
    /// 0.13 s end to end, filmed at 60 fps (asked 2026-10-02: at the default
    /// speed, about 0.3 s, it trailed the typing). `.offUp` was filmed too
    /// and rejected: the old glyph vanished at once but the new one took
    /// 4–7 frames to show, an EMPTY field blinking between the two faces.
    static let fieldActionTransition = UISymbolContentTransition(
        .replace.downUp, options: .speed(fieldActionTransitionSpeed)
    )
    static let fieldActionTransitionSpeed: Double = 2.5

    /// The field button's face, COLOUR BAKED IN. Each glyph carries its own
    /// ink (`.alwaysOriginal`), so the button's tint plays no part in what
    /// is drawn: the replace swaps a grey waveform for a blue arrow as one
    /// image change. With the glyphs templated, the colour rode the image
    /// view's tint — a channel of its own, applied apart from the replace —
    /// and the leaving waveform flashed blue (or the arriving arrow grey) in
    /// the frames between the two.
    static func fieldActionImage(sends: Bool) -> UIImage? {
        UIImage(
            systemName: sends ? sendSymbol : waveformSymbol,
            withConfiguration: sends ? sendConfiguration : waveformConfiguration
        )?.withTintColor(sends ? sendTint : waveformTint, renderingMode: .alwaysOriginal)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        textView.font = .appFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = Self.fieldInsets(for: textView.font)
        textView.delegate = self
        // The field's trailing end holds the emote toggle; the text stops
        // short of it, and the toggle holds the last line's station as the
        // field grows (bottom-anchored, like the round controls around it).
        let emoteToggle = emotes.toggleButton
        // The `:query` strip floats above the WHOLE bar at rest, not the
        // field: over the field it would lie across the stake bubble. Over a
        // risen field it follows the field (`applyRise`).
        emotes.suggestionAnchor = self
        emoteToggle.tintColor = .secondaryLabel
        textView.translatesAutoresizingMaskIntoConstraints = false
        emoteToggle.translatesAutoresizingMaskIntoConstraints = false
        field.contentView.addSubview(textView)
        field.contentView.addSubview(emoteToggle)
        // The field's own button: after the emote button, at the field's end
        // — the voice note's place in iMessage's own field, and its send's.
        var action = UIButton.Configuration.plain()
        action.contentInsets = .zero
        action.symbolContentTransition = Self.fieldActionTransition
        fieldActionButton.configuration = action
        fieldActionButton.addAction(UIAction { [weak self] _ in self?.fieldActionTapped() }, for: .primaryActionTriggered)
        fieldActionButton.translatesAutoresizingMaskIntoConstraints = false
        field.contentView.addSubview(fieldActionButton)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: field.contentView.leadingAnchor),
            textView.topAnchor.constraint(equalTo: field.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            textView.trailingAnchor.constraint(equalTo: emoteToggle.leadingAnchor),
            emoteToggle.trailingAnchor.constraint(equalTo: fieldActionButton.leadingAnchor),
            emoteToggle.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            emoteToggle.widthAnchor.constraint(equalToConstant: Metrics.emoteToggleWidth),
            emoteToggle.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            fieldActionButton.trailingAnchor.constraint(equalTo: field.contentView.trailingAnchor),
            fieldActionButton.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            fieldActionButton.widthAnchor.constraint(equalToConstant: Metrics.fieldActionSide),
            fieldActionButton.heightAnchor.constraint(equalToConstant: Metrics.fieldActionSide),
        ])
        // The trailing glyphs hold one size at every text size, as a bar's
        // do: the field grows with the text, but its buttons stay the 38pt
        // line's, and a glyph that scaled with the text overflowed them (the
        // emote face and the waveform had no size of their own). The large
        // content viewer is the accessibility answer instead — a long press
        // at the accessibility sizes shows the glyph big.
        //
        // ⚠️ AND THE SPINNER. The send's in-flight face is the
        // configuration's activity indicator, sized by the button's text size
        // — 33×41pt at accessibility M and 63×71pt at XXXL on iOS 26.2 (CI),
        // spilling out of the 38pt cap. Capping the buttons' size category
        // holds every face, glyph or spinner, at its default size.
        emoteToggle.setPreferredSymbolConfiguration(Self.emoteToggleConfiguration, forImageIn: .normal)
        for button in [emoteToggle, fieldActionButton] {
            button.maximumContentSizeCategory = .large
            button.showsLargeContentViewer = true
            button.scalesLargeContentImage = true
        }
        addInteraction(UILargeContentViewerInteraction())

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

        // The boost (stake) control, the column's upper bubble: tap
        // spends the default denomination, long-press opens the amount menu
        // (the rail anchor's exact contract — one post, two surfaces, one
        // behavior).
        boostButton.configuration?.image = PointsSymbol.glyphImage(Self.glyphConfiguration)
        boostButton.configuration?.cornerStyle = .capsule
        boostButton.accessibilityLabel = "Boost post"
        boostButton.addAction(
            UIAction { [weak self] _ in self?.onBoost?(.points(WalletStore.Policy.defaultStakeAmount)) },
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
            systemName: "globe", withConfiguration: Self.glyphConfiguration
        )
        visibilityButton.configuration?.cornerStyle = .capsule
        visibilityButton.accessibilityLabel = "Post visibility"
        visibilityButton.showsMenuAsPrimaryAction = true
        visibilityButton.isHidden = true

        // ONE glyph, swapped in place: pin ↔ pinned is a symbol REPLACE on the
        // button's own image, so the bubble never blinks or moves.
        railButton.configuration?.cornerStyle = .capsule
        railButton.configuration?.symbolContentTransition = UISymbolContentTransition(.replace)
        railButton.addAction(UIAction { [weak self] _ in self?.onRailAction?() }, for: .primaryActionTriggered)
        railButton.isHidden = true
        // A hold on the SOUND face opens the sound sheet (#680); a recognised
        // hold cancels the button's touch, so it never also counts as the tap.
        let railHold = UILongPressGestureRecognizer(target: self, action: #selector(railHeld(_:)))
        railHold.minimumPressDuration = 0.4
        railButton.addGestureRecognizer(railHold)
        installRailCover()

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
        // The button is LAST and full-bleed over the bubble, so the whole
        // bubble — the glass ring included — is the tap target and owns the
        // menu.
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
        addSubview(railButton)
        addSubview(boostButton)
        addSubview(visibilityButton)
        // The like face's count, under its heart in the stake pill (#669).
        addLayoutGuide(restingInputRow)
        avatarBubble.translatesAutoresizingMaskIntoConstraints = false
        boostButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        railButton.translatesAutoresizingMaskIntoConstraints = false
        fieldHeight = field.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        stakeHeight = boostButton.heightAnchor.constraint(equalToConstant: Self.stakeSide(likeFace: usesLikeFace))
        // The INPUT row, leading to trailing: the viewer's AVATAR, then the
        // field, which owns all the flexible width and, at rest, ends `sm`
        // short of the trailing COLUMN (`fieldTrailing`, which the rise
        // widens). The row RESTS on the bar's bottom edge — the host rests
        // that edge on the toolbar — and the field grows upward from it; the
        // keyboard's ceiling (`riseWithKeyboard(of:)`) outranks the rest and
        // lifts the row clear of the bar.
        //
        // The column: the slot (the rail button) rests on the bar's bottom —
        // the field's line — on the media layout's sound bubble; the stake
        // pill stands one `gap` over it, on the like pill. Both are the comment
        // band's height (`SnapActionColumn.bubbleSize`) — read once, here,
        // like the band reads its own at init. The stake holds its station
        // over the slot: a growing field rises beside it, not under it. The
        // avatar opens the row (a composer says who is speaking before it
        // offers anything else); it is silent and rides with the field.
        let bubble = SnapActionColumn.bubbleSize
        fieldTrailing = field.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.fieldTrailingInset(progress: 0)
        )
        let fieldAtRest = field.bottomAnchor.constraint(equalTo: restingInputRow.bottomAnchor)
        fieldAtRest.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fieldHeight,
            restingInputRow.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            restingInputRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            restingInputRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            restingInputRow.heightAnchor.constraint(equalTo: field.heightAnchor),
            restingInputRow.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            avatarBubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatarBubble.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            avatarBubble.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            avatarBubble.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
            field.leadingAnchor.constraint(equalTo: avatarBubble.trailingAnchor, constant: Spacing.sm),
            fieldAtRest,
            fieldTrailing,
            railButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            railButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            railButton.widthAnchor.constraint(equalToConstant: bubble),
            railButton.heightAnchor.constraint(equalToConstant: bubble),
            railButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            boostButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            boostButton.bottomAnchor.constraint(equalTo: railButton.topAnchor, constant: -SnapActionColumn.gap),
            boostButton.widthAnchor.constraint(equalToConstant: bubble),
            stakeHeight,
            // The boost's own station: the two never show at once.
            visibilityButton.centerXAnchor.constraint(equalTo: boostButton.centerXAnchor),
            visibilityButton.centerYAnchor.constraint(equalTo: boostButton.centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalTo: boostButton.widthAnchor),
            visibilityButton.heightAnchor.constraint(equalTo: boostButton.heightAnchor),
        ])
        // The bar's TOP is the highest of what it holds AT REST: required
        // floors above, and hugs at DISTINCT priorities (equal ones would
        // leave the solver a choice it could make differently pass to pass) —
        // the stake's first (`stakeStationConstraints`), then the resting
        // input row's, then the slot's. The row's, not the field's: a field
        // the keyboard lifts must not drag the bar's top — or the column on
        // it — along.
        let rowHug = restingInputRow.topAnchor.constraint(equalTo: topAnchor)
        rowHug.priority = UILayoutPriority(250)
        let slotHug = railButton.topAnchor.constraint(equalTo: topAnchor)
        slotHug.priority = UILayoutPriority(249)
        NSLayoutConstraint.activate([rowHug, slotHug])
        let stakeHug = boostButton.topAnchor.constraint(equalTo: topAnchor)
        stakeHug.priority = UILayoutPriority(251)
        stakeStationConstraints = [
            boostButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stakeHug,
        ]
        NSLayoutConstraint.activate(stakeStationConstraints)
        // The disc is NEVER empty. Before an identity resolves the bar shows
        // the unknown-viewer placeholder, not a blank circle — the same
        // "monogram is the rendered state" rule the comment rows follow,
        // applied to the frame before anyone has told us who you are.
        avatarView.setMonogram(Self.monogram(nil))
        applyRailFace()
        updateFieldAction()
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
    ///
    /// The input row is the bar's WHEREVER it is: risen with the keyboard it
    /// stands above the bar's own bounds, and its touches are still the bar's.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if point.y >= field.frame.minY, point.y <= field.frame.maxY,
           point.x >= bounds.minX, point.x <= bounds.maxX {
            return true
        }
        guard super.point(inside: point, with: event) else { return false }
        // A reserved column is the page's, drawn above: not the bar's touch.
        guard hostsActionColumn else { return false }
        if !railButton.isHidden, railButton.frame.contains(point) { return true }
        guard showsStake else { return false }
        let station = visibilityMenu == nil ? boostButton : visibilityButton
        return station.frame.contains(point)
    }

    /// The field's two buttons answer to a 44pt target around their drawn
    /// frames (`Metrics.minimumHitSide`): the 38pt line cannot hold one, and
    /// the emote toggle and the send arrow are the field's most hit spots.
    /// Where the two targets overlap, the nearer button's centre wins.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let button = fieldButton(near: point) { return button }
        return super.hitTest(point, with: event)
    }

    /// The field button whose 44pt target holds `point` (bar coordinates),
    /// the nearer one when both do. Internal for tests.
    func fieldButton(near point: CGPoint) -> UIButton? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        var best: (button: UIButton, distance: CGFloat)?
        for button in [emotes.toggleButton, fieldActionButton] {
            guard !button.isHidden, button.isEnabled, button.isUserInteractionEnabled,
                  button.bounds.width > 0 else { continue }
            let frame = button.convert(button.bounds, to: self)
            let target = frame.insetBy(
                dx: -max(0, Metrics.minimumHitSide - frame.width) / 2,
                dy: -max(0, Metrics.minimumHitSide - frame.height) / 2
            )
            guard target.contains(point) else { continue }
            let distance = hypot(point.x - frame.midX, point.y - frame.midY)
            if let current = best, current.distance <= distance { continue }
            best = (button, distance)
        }
        return best?.button
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
        applyLikeBadge(animated: false)
        applyReservedColumn()
        setNeedsLayout()
    }

    // MARK: - The keyboard

    /// Hands the bar the keyboard its INPUT ROW rises with: the host's
    /// `keyboardLayoutGuide` — its root view's, measured from the screen's
    /// edge (`usesBottomSafeArea = false` on the engaged surfaces), so its top
    /// is the screen's bottom while no keyboard is up. The field's bottom is
    /// held `sm` over the guide's top (required) and rests on the bar's
    /// bottom otherwise; the BAR stays where the host put it, and so does the
    /// column on it.
    ///
    /// The guide's owner must be an ancestor of the bar.
    func riseWithKeyboard(of guide: UILayoutGuide) {
        keyboardCeiling?.isActive = false
        let ceiling = field.bottomAnchor.constraint(lessThanOrEqualTo: guide.topAnchor, constant: -Spacing.sm)
        keyboardCeiling = ceiling
        ceiling.isActive = tracksKeyboard
        setNeedsLayout()
    }

    /// Whether the input row may rise with the keyboard at all.
    ///
    /// ⚠️ THE GUIDE IS ANCHORED TO THE SCREEN. With no keyboard up its top is
    /// the screen's bottom, and the ceiling is required — so a bar whose page
    /// is only partly on screen (a page scrolling in) would have its field
    /// pinned at the screen's edge instead of travelling with the page. The
    /// host grants it to the page a viewer can type on (see
    /// `PostDetailViewController.setComposerTracksKeyboard`).
    var tracksKeyboard = true {
        didSet {
            guard tracksKeyboard != oldValue else { return }
            keyboardCeiling?.isActive = tracksKeyboard
            setNeedsLayout()
        }
    }

    /// How far the input row has risen clear of the column, 0…1 — see
    /// `riseProgress(lift:clearance:)`. Read off the last layout pass.
    private(set) var riseProgress: CGFloat = 0

    /// The top of what the bar shows, in its superview's coordinates: the
    /// bar's own top at rest, the risen field's while the keyboard holds the
    /// row above the bar. For a host clearing its stream above the composer.
    /// Lays the bar out first: the field is the bar's subview, laid out after
    /// a host's `viewDidLayoutSubviews` asks.
    var occupiedMinY: CGFloat {
        layoutIfNeeded()
        return frame.minY + min(0, field.frame.minY)
    }

    /// Reads the input row's lift off the solved layout — the keyboard's
    /// ceiling has already placed the field — and widens the field by it.
    /// Returns whether the width moved, so the caller lays out again in the
    /// SAME pass: a keyboard animating in lays out once, inside its own
    /// animation, and the width has to land in that block to ride the
    /// keyboard's curve rather than snap after it.
    private func applyRise() -> Bool {
        let rest = restingInputRow.layoutFrame.maxY
        let lift = max(0, rest - field.frame.maxY)
        let columnTop = showsStake ? boostButton.frame.minY : railButton.frame.minY
        let progress = Self.riseProgress(lift: lift, clearance: rest - columnTop)
        #if DEBUG
        if Self.logsRise, abs(progress - riseProgress) > 0.0001 {
            FileHandle.standardError.write(Data(String(
                format: "[composer-rise] %.3f lift=%.1f progress=%.3f\n", CACurrentMediaTime(), lift, progress
            ).utf8))
        }
        #endif
        riseProgress = progress
        // The `:query` strip over the field once nothing stands beside it.
        emotes.suggestionAnchor = progress > 0 ? field : self
        let inset = Self.fieldTrailingInset(progress: progress)
        guard abs(fieldTrailing.constant + inset) > 0.01 else { return false }
        fieldTrailing.constant = -inset
        return true
    }

    /// The input row's top — the field's top edge, which rises as it grows
    /// and with the keyboard. For a host whose chrome belongs to the input
    /// row rather than to the whole bar (the footer band, whose ramp the
    /// stake bubble floats in, and which rides the keyboard with the row).
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
        applyPlaceholder()
        applyGuestFace()
        #if DEBUG
        runEmoteKeyboardQAIfAsked()
        runComposerDraftQAIfAsked()
        runComposerKeyboardQAIfAsked()
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
        // The keyboard has placed the field by now; its width follows, in
        // this same pass (see `applyRise`).
        if applyRise() { super.layoutSubviews() }
        // The field is placed: its height for the draft lands in this same
        // pass too (see `updateFieldHeight`).
        if updateFieldHeight() { super.layoutSubviews() }
    }

    private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        textView.text = ""
        textViewDidChange(textView)
        #if DEBUG
        if Self.logsRise { debugLogKeyboardStep("sent \"\(text)\"") }
        #endif
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

    /// The prompt when nobody is being replied to, overriding the comment
    /// wording ("Comment as …") — a conversation's field says "Message…".
    var defaultPlaceholder: String? {
        didSet { applyPlaceholder() }
    }

    /// The send arrow's spoken name. Nil is "Send comment"; the Text Post
    /// page's first send publishes the post, and says so.
    var sendAccessibilityLabel: String? {
        didSet { updateFieldAction() }
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

    /// Whether the field holds something to send.
    private var hasDraft: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The field button's tap: send over a draft (nothing while one is in
    /// flight), the voice-note seam over an empty field — keyboard up or down.
    private func fieldActionTapped() {
        if hasDraft {
            sendTapped()
        } else if !isSending {
            onVoiceNote?()
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
        // A guest cannot write here: the field says so before they tap it (the
        // tap opens the sign-up sheet). The gate is only reachable once the bar
        // is in a window, so this is re-run on the way in.
        if defaultPlaceholder == nil, let gate = MemberGates.gate(from: self), !gate.isMember {
            placeholderLabel.text = "Sign up to comment"
        } else if let replyName {
            placeholderLabel.text = "Reply to \(replyName)…"
        } else if let defaultPlaceholder {
            placeholderLabel.text = defaultPlaceholder
        } else if let viewerName, !viewerName.isEmpty {
            placeholderLabel.text = "Comment as \(viewerName)"
        } else {
            placeholderLabel.text = "Add a comment…"
        }
    }

    // MARK: - Guest

    /// The guest's button, built the first time a guest is seen: from the
    /// avatar's leading edge to the field's trailing one, on the field's
    /// resting row.
    private func makeSignUpButton() -> UIButton {
        let button = UIButton(configuration: .glass())
        button.configuration?.cornerStyle = .capsule
        var title = AttributedString("Sign up to comment")
        title.font = .appFont(forTextStyle: .headline)
        button.configuration?.attributedTitle = title
        button.configuration?.baseForegroundColor = .label
        button.accessibilityIdentifier = "comments.sign-up"
        button.addAction(UIAction { [weak self] _ in self?.signUpTapped() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: avatarBubble.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: restingInputRow.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])
        return button
    }

    /// A guest sees the sign-up button where the avatar and the field stand;
    /// a member, the composer. Decided from the member gate, which is only
    /// reachable in a window — so this runs on the way in, and again once a
    /// guest has signed up from the button.
    private func applyGuestFace() {
        let isGuest = MemberGates.gate(from: self)?.isMember == false
        if isGuest, signUpButton == nil { signUpButton = makeSignUpButton() }
        signUpButton?.isHidden = !isGuest
        avatarBubble.isHidden = isGuest
        field.isHidden = isGuest
    }

    /// The sheet titled for commenting; once signed up, the composer takes
    /// the button's place with the keyboard up — the comment they came for.
    private func signUpTapped() {
        guard let gate = MemberGates.gate(from: self), !gate.isMember else {
            applyGuestFace()
            return
        }
        Task { @MainActor [weak self] in
            guard await gate.requireMember(for: .comment), let self else { return }
            applyGuestFace()
            applyPlaceholder()
            textView.becomeFirstResponder()
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
    /// bar waits offstage at alpha 0), then empties it ~6 s later: the field
    /// button's two faces (send over a draft, the waveform over an empty
    /// field) and the rail's one, without a keyboard, which the simulator does
    /// not show. Prints `[composer-draft] <epoch s> <step>` with the faces at
    /// each step.
    private func runComposerDraftQAIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !ranComposerDraftQA, let index = arguments.firstIndex(of: "-composer-draft"),
              index + 1 < arguments.count else { return }
        ranComposerDraftQA = true
        let text = arguments[index + 1]
        let report: @MainActor (String) -> Void = { [weak self] step in
            guard let self else { return }
            let ink = self.fieldActionButton.imageView?.tintColor.resolvedColor(with: self.traitCollection)
            let face = "rail=\(self.debugRailSymbol ?? "-") field=\(self.fieldActionSymbol ?? "-")"
                + " label=\(self.fieldActionButton.accessibilityLabel ?? "-")"
                + " ink=\(ink.map { String(describing: $0) } ?? "-")"
                + " dimmed=\(self.fieldActionButton.tintAdjustmentMode == .dimmed)"
            let frame = self.window.map { self.convert(self.bounds, to: $0) } ?? .zero
            // stderr: unbuffered, so a detached `--stderr=` sink is live.
            FileHandle.standardError.write(Data(
                "[composer-draft] \(Int(Date().timeIntervalSince1970)) \(step) draft=\"\(self.draftText)\" \(face) frame=\(frame)\n".utf8
            ))
        }
        QAWait.until("-composer-draft", timeout: 30, { [weak self] in self?.debugIsShown == true }) {
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

    /// SHOWN means on screen: every ancestor visible and opaque (a panel is
    /// mounted on pages that are not the one showing), and the bar inside the
    /// window's bounds.
    private var debugIsShown: Bool {
        guard let window, bounds.height > 0 else { return false }
        let ancestorsShown = sequence(first: self as UIView, next: \.superview)
            .allSatisfy { !$0.isHidden && $0.alpha > 0.99 }
        return ancestorsShown && window.bounds.contains(convert(bounds, to: window))
    }

    private var ranComposerKeyboardQA = false
    /// Read once: `applyRise` runs on every layout pass.
    private static let logsRise = ProcessInfo.processInfo.arguments.contains("-composer-keyboard-qa")

    /// One `[composer-kbd]` line: the rise, and the field's and the column's
    /// window frames. stderr: unbuffered, so a detached `--stderr=` sink is
    /// live.
    private func debugLogKeyboardStep(_ step: String) {
        guard let window else { return }
        func rect(_ view: UIView) -> String {
            let r = view.convert(view.bounds, to: window)
            return String(format: "(%.1f %.1f %.1f %.1f)", r.minX, r.minY, r.width, r.height)
        }
        let line = String(
            format: "[composer-kbd] %.3f %@ rise=%.3f field=%@ rail=%@ stake=%@ bar=%@ face=%@ rail.face=%@\n",
            CACurrentMediaTime(), step, riseProgress, rect(field), rect(railButton),
            rect(boostButton), rect(self), fieldActionSymbol ?? "-", debugRailSymbol ?? "-"
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// `-composer-keyboard-qa` (DEBUG): focuses the field ~1.5 s after the bar
    /// is SHOWN, types a draft 3 s later, breaks it onto a second, third and
    /// fourth line one a second, takes them back one a second, and empties
    /// it 8 s after the first (time for a real tap on send, which logs
    /// `sent`), the keyboard up throughout, and leaves the keyboard up for a manual
    /// (interactive) dismissal. Logs `[composer-kbd]` at each step and on
    /// every keyboard notification, and `[composer-rise]` whenever a layout
    /// pass moves the rise — so a keyboard animating in or a finger dragging
    /// it down prints the walk, frame by frame.
    private func runComposerKeyboardQAIfAsked() {
        guard !ranComposerKeyboardQA, Self.logsRise else { return }
        ranComposerKeyboardQA = true
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let step = "\(note.name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "")) end.minY=\(end.minY)"
                MainActor.assumeIsolated { self?.debugLogKeyboardStep(step) }
            }
        }
        QAWait.until("-composer-keyboard-qa", timeout: 30, { [weak self] in self?.debugIsShown == true }) { [weak self] in
            self?.debugLogKeyboardStep("shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.focusComposer()
                self?.debugLogKeyboardStep("focused")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.draftText = "Typed with the keyboard up"
                self?.debugLogKeyboardStep("typed")
            }
            // Line breaks, one a second, then taken back one a second: the
            // field's growth and shrink on camera (`grow` lines).
            let lines = ["Typed with the keyboard up", "a second line", "a third", "and a fourth"]
            for count in 2...lines.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5 + Double(count - 1)) { [weak self] in
                    self?.insertIntoComposer("\n" + lines[count - 1])
                    self?.debugLogKeyboardStep("line \(count)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11.5 - Double(count - 1)) { [weak self] in
                    self?.draftText = lines.prefix(count - 1).joined(separator: "\n")
                    self?.debugLogKeyboardStep("back to \(count - 1) line(s)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) { [weak self] in
                self?.draftText = ""
                self?.debugLogKeyboardStep("cleared")
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

    /// The snap feed's LIKE face on the stake bubble (#668), off by default:
    /// a heart white at rest and red once the viewer has staked, the post's
    /// like count on its corner, and the viewer's stake in the long-press
    /// menu — the rail button's exact face, so switching between the media
    /// and comments layouts stays a crossfade between two identical bubbles.
    /// The snap feed's comments panel turns it on; elsewhere the bubble keeps
    /// its receipt face (the spend as a number).
    var usesLikeFace = false {
        didSet {
            guard usesLikeFace != oldValue else { return }
            stakeHeight?.constant = Self.stakeSide(likeFace: usesLikeFace)
            applyBoostFace()
            applyLikeBadge(animated: false)
        }
    }

    /// The post's like count, the viewer's stake NOT included — the bar adds
    /// it, as the rail's chrome does. Nil when the author hides it (#397).
    /// Read only by the like face.
    func setLikeCount(_ count: Int64?) {
        guard count != boostPostLikeCount else { return }
        boostPostLikeCount = count
        applyBoostFace()
        applyLikeBadge(animated: false)
    }


    /// The stake's height: the like PILL with the like face (#669), the
    /// square bubble with the receipt face.
    private var stakeHeight: NSLayoutConstraint!

    private static func stakeSide(likeFace: Bool) -> CGFloat {
        likeFace ? SnapActionColumn.likePillHeight : SnapActionColumn.bubbleSize
    }
    private var boostPostLikeCount: Int64?

    /// The like face's count is the pill's own title (#692): redrawn with it.
    private func applyLikeBadge(animated: Bool) {
        applyBoostFace()
    }

    #if DEBUG
    /// The count under the like face's heart — nil while it is not showing.
    var debugLikeBadgeText: String? {
        usesLikeFace && !boostButton.isHidden ? boostButton.configuration?.title : nil
    }
    #endif

    /// The viewer's cumulative spend on the represented post. With the like
    /// face it only turns the heart red and moves the badge (`animated` for
    /// the viewer's own stake or undo); otherwise it flips the bubble between
    /// its glyph face (0, an invitation) and the number itself (a receipt),
    /// the rail's former contract. Owned by the host, which owns the post
    /// identity and the wallet.
    func setBoostTotal(_ total: Int, animated: Bool = false) {
        guard total != boostSpentTotal else { return }
        boostSpentTotal = total
        applyBoostFace()
        applyLikeBadge(animated: animated)
        // The receipt moves the cap's remainder, and the remainder moves
        // the enable state (a full post refuses even the tap).
        refreshBoostEnabled()
    }

    private func applyBoostFace() {
        let total = boostSpentTotal
        if usesLikeFace {
            // An outline in the page's ink at rest — the text's colour, black
            // on the light panel, white over dimmed media — and the points'
            // red fill once staked (#680), over the count, one even gap apart
            // (#692: the count is the pill's own title).
            let count = SnapChromeView.displayedLikeCount(postLikes: boostPostLikeCount, viewerStake: total)
            let shows = showsStake && visibilityMenu == nil
            if let base = boostButton.configuration {
                boostButton.configuration = SnapActionColumn.likeConfiguration(
                    base, staked: total > 0, count: shows ? count : nil, ink: .label
                )
            }
            boostButton.accessibilityLabel = "Like"
            boostButton.accessibilityValue = SnapRailBoostButton.accessibilityValue(
                likeCount: SnapChromeView.displayedLikeCount(postLikes: boostPostLikeCount, viewerStake: total),
                staked: total
            )
            return
        }
        boostButton.accessibilityLabel = "Boost post"
        if total > 0 {
            var title = AttributedString(total.formattedCompact())
            // Fixed size (#482): the count replaces the glyph inside the
            // 36 pt circle, which holds one or the other at any text size.
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
            boostButton.configuration?.image = PointsSymbol.glyphImage(Self.glyphConfiguration)
        }
        boostButton.accessibilityValue = total > 0 ? "\(total) points spent" : nil
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
    /// Shots left in the viewer's ×100 cartridge pack — the menu's loaded face.
    private var boostStakeShots = 0

    /// The affordability + undo state, pushed on configure and on every
    /// wallet change. Disables the button only when it has NOTHING to
    /// offer — tap unaffordable AND nothing to undo — because a disabled
    /// `UIButton` delivers no long-press either, and the menu is the
    /// undo's only door.
    func setBoostContext(balance: Int, undoableAmount: Int, stakeShots: Int = 0) {
        boostBalance = balance
        boostUndoableAmount = undoableAmount
        boostStakeShots = stakeShots
        refreshBoostEnabled()
    }

    private func refreshBoostEnabled() {
        let remaining = max(0, WalletStore.Policy.perTargetBoostCap - boostSpentTotal)
        // A tap near the cap costs only the remainder (the store clamps),
        // so affordability is judged against that, not the flat tap price.
        let tapCost = min(WalletStore.Policy.defaultStakeAmount, remaining)
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
                tapAmount: WalletStore.Policy.defaultStakeAmount,
                shotsLeft: boostStakeShots,
                shotAmount: WalletStore.Policy.StakePack.pointsPerShot
            ),
            stake: { [weak self] amount in self?.onBoost?(.points(amount)) },
            shoot: { [weak self] in self?.onBoost?(.shot) },
            undo: { [weak self] in self?.onBoostUndo?() },
            // The empty pack's row opens the Shop, found up the bar's
            // responder chain (`StakeShopOpening`).
            openShop: StakeShop.openAction(from: self),
            // The like face shows no spend, so the menu says it (#668).
            showsStake: usesLikeFace
        )
    }

    /// The refund's receipt: the confirmation float mirrored — a cool "−N"
    /// sinking off the button. White, not gold: an undo is not a payout.
    func playBoostRefund(amount: Int) {
        guard boostButton.bounds.width > 0 else { return }
        let label = UILabel()
        label.text = "−\(amount)"
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
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
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .heavy, relativeTo: .headline, maximumPointSize: 24
        )
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

    /// The field button's two faces:
    ///   has text (or a send in flight) → ↑ send
    ///   empty                          → 〰 waveform (voice note)
    /// The keyboard plays no part. The waveform stays up while nothing is
    /// typed, and a draft is sendable with the keyboard down: a shared link or
    /// an emote lands in the field precisely to be sent, and a voice note over
    /// a draft turned the one action there into a "not available" notice.
    /// Every write goes through the button's configuration, whose
    /// `symbolContentTransition` (`fieldActionTransition`) replaces the old
    /// glyph with the new one.
    ///
    /// ONE configuration write per change, applied on the spot. Each
    /// `configuration?.x = …` is a write of its own, and the image and the
    /// colour used to land as two; the face also waited for the next layout
    /// pass, which a line break runs INSIDE the field's growth spring
    /// (`updateFieldHeight`), stretching the swap to the spring's length.
    private func updateFieldAction() {
        let sends = hasDraft || isSending
        let symbol = sends ? Self.sendSymbol : Self.waveformSymbol
        guard var face = fieldActionButton.configuration else { return }
        if fieldActionSymbol != symbol {
            fieldActionSymbol = symbol
            face.image = Self.fieldActionImage(sends: sends)
            // The spinner's ink (the glyphs carry their own).
            face.baseForegroundColor = sends ? Self.sendTint : Self.waveformTint
        }
        face.showsActivityIndicator = isSending
        if face != fieldActionButton.configuration {
            fieldActionButton.configuration = face
            fieldActionButton.layoutIfNeeded()
        }
        fieldActionButton.accessibilityLabel = sends
            ? sendAccessibilityLabel ?? "Send comment"
            : "Record voice comment"
        fieldActionButton.isEnabled = !isSending
    }

    /// The symbol the field button wears, so an unchanged face is not
    /// re-applied (a re-applied image would replay the replace).
    private var fieldActionSymbol: String?

    /// The rail button's face: the host's action, never anything the draft
    /// says. Hidden on a draft post (`.empty`), whose slot holds no bubble.
    private func applyRailFace() {
        let symbol: String?
        switch railFace {
        case .empty:
            symbol = nil
            railButton.accessibilityLabel = nil
        case .repost:
            symbol = PostActionSymbol.repost
            railButton.accessibilityLabel = "Repost"
        case .pin(let isPinned):
            symbol = isPinned ? "pin.fill" : "pin"
            railButton.accessibilityLabel = isPinned ? "Unpin conversation" : "Pin conversation"
        case .sound(let face):
            // The cover as a disc, the bubble's size less the sound bubble's
            // inset, so the two read as one (#671). Not a symbol: no replace.
            railButton.isHidden = false
            railButton.configuration?.image = nil
            railButton.configuration?.contentInsets = .zero
            if railCoverView.isHidden || railFaceSymbol != Self.soundRailSymbol || railCoverView.image == nil {
                railCoverView.image = face.cachedCover
            }
            railCoverView.isHidden = false
            railMutedBadge.isHidden = !(face.isMuted && face.isAvailable)
            railButton.accessibilityLabel = "Sound"
            railButton.alpha = face.isAvailable ? 1 : 0.45
            railFaceSymbol = Self.soundRailSymbol
            railButton.isEnabled = isRailFaceEnabled && face.isAvailable
            applyReservedColumn()
            return
        }
        railButton.alpha = 1
        railButton.isHidden = symbol == nil
        railCoverView.isHidden = true
        railMutedBadge.isHidden = true
        railCoverView.layer.setRecordSpinning(false)
        if let symbol, railFaceSymbol != symbol {
            railButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: Self.glyphConfiguration)
        }
        railFaceSymbol = symbol
        railButton.isEnabled = isRailFaceEnabled
        applyReservedColumn()
    }

    /// Redraws the rail face as it stands — the sound's cover, once a cover
    /// that was still being fetched has landed (#680).
    func redrawRailFace() {
        railFaceSymbol = nil
        railCoverView.image = nil
        applyRailFace()
    }

    /// Turns the sound face's cover like a record while the post plays aloud
    /// (#692) — the page's sound bubble's rule: play, pause and mute, and
    /// Reduce Motion, never the idle calm. Other faces never turn.
    func setRailSpinning(_ spinning: Bool) {
        guard hostsActionColumn, case .sound(let face) = railFace, face.isAvailable else {
            railCoverView.layer.setRecordSpinning(false)
            return
        }
        railCoverView.layer.setRecordSpinning(spinning, reducesMotion: MotionPreference.reducesMotion)
    }

    private func installRailCover() {
        railCoverView.contentMode = .scaleAspectFill
        railCoverView.clipsToBounds = true
        railCoverView.isUserInteractionEnabled = false
        railCoverView.isHidden = true
        railCoverView.layer.cornerRadius = (SnapActionColumn.bubbleSize - 10) / 2
        railMutedBadge.image = UIImage(
            systemName: "speaker.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        )
        railMutedBadge.tintColor = .white
        railMutedBadge.contentMode = .center
        railMutedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        railMutedBadge.layer.cornerRadius = 8
        railMutedBadge.isUserInteractionEnabled = false
        railMutedBadge.isHidden = true
        for view in [railCoverView, railMutedBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            railButton.addSubview(view)
        }
        NSLayoutConstraint.activate([
            railCoverView.centerXAnchor.constraint(equalTo: railButton.centerXAnchor),
            railCoverView.centerYAnchor.constraint(equalTo: railButton.centerYAnchor),
            railCoverView.widthAnchor.constraint(equalToConstant: SnapActionColumn.bubbleSize - 10),
            railCoverView.heightAnchor.constraint(equalToConstant: SnapActionColumn.bubbleSize - 10),
            railMutedBadge.trailingAnchor.constraint(equalTo: railButton.trailingAnchor),
            railMutedBadge.bottomAnchor.constraint(equalTo: railButton.bottomAnchor),
            railMutedBadge.widthAnchor.constraint(equalToConstant: 16),
            railMutedBadge.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    /// What `debugRailSymbol` reads while the slot wears the sound's cover.
    static let soundRailSymbol = "sound.cover"

    /// The symbol the rail button wears, so an unchanged face is not
    /// re-applied (a re-applied image would replay the replace).
    private var railFaceSymbol: String?

    #if DEBUG
    /// The rail button, for the specs that read its face and tap it.
    var debugRailButton: UIButton { railButton }
    /// The sound face's cover and whether it is turning now (#692).
    var debugRailCover: UIImageView { railCoverView }
    var debugRailIsSpinning: Bool {
        railCoverView.layer.animation(forKey: CALayer.recordSpinKey) != nil && railCoverView.layer.speed != 0
    }
    var debugRailMutedBadgeShown: Bool { !railMutedBadge.isHidden }
    /// The waveform / send button inside the field.
    var debugFieldActionButton: UIButton { fieldActionButton }
    /// The symbol the rail button wears.
    var debugRailSymbol: String? { railButton.isHidden ? nil : railFaceSymbol }
    /// The symbol the field button wears.
    var debugFieldActionSymbol: String? { fieldActionSymbol }
    /// The field, for the specs that measure it.
    var debugField: UIView { field }
    /// The avatar's bubble, in the bar's space.
    var debugAvatarFrame: CGRect { avatarBubble.frame }
    #endif

    /// Grows the field with its content up to `maxLines`, then hands the
    /// overflow to the text view's own scrolling.
    ///
    /// `animated` (a line typed, pasted, sent or deleted): the new height
    /// lands in ONE spring with the host's whole layout — the field, the bar
    /// (and the column standing on it), the footer band riding the input row,
    /// and the stream's clearance and offset — so nothing jumps a line ahead
    /// of the rest, growing or shrinking (asked 2026-10-02: a line break grew
    /// the field abruptly). A layout pass (`layoutSubviews`: a width change
    /// rewrapping the draft, the keyboard's rise) passes false: it already
    /// runs inside whatever animation moved the width.
    ///
    /// ⚠️ MEASURED AT THE FIELD'S WIDTH, not the text view's. The text view
    /// sits in the field's content view, which lays out AFTER the bar's own
    /// pass: on the bar's first pass the text view has no width yet (and a
    /// widening rise leaves it a pass behind). Measuring its bounds skipped
    /// that first pass, and nothing asked again — a draft set before the bar
    /// was laid out (a shared link's prefill) stayed one line tall until some
    /// unrelated layout came along (iOS 26 test host: for good). The text's
    /// width is the field's less the two trailing buttons, known as soon as
    /// the field is placed. Returns whether the height moved without an
    /// animation, for `layoutSubviews` to apply it in the same pass.
    @discardableResult
    private func updateFieldHeight(animated: Bool = false) -> Bool {
        let textWidth = field.bounds.width - Metrics.emoteToggleWidth - Metrics.fieldActionSide
        guard textWidth > 0 else { return false }
        // The text size may have moved the line's height.
        let centred = Self.fieldInsets(for: textView.font)
        if textView.textContainerInset != centred { textView.textContainerInset = centred }
        let insets = textView.textContainerInset
        let lineHeight = textView.font?.lineHeight ?? UIFont.appFont(forTextStyle: .body).lineHeight
        let maxHeight = ceil(lineHeight * Metrics.maxLines) + insets.top + insets.bottom
        let fitting = textView.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        ).height
        let target = min(max(ceil(fitting), Metrics.controlSize), maxHeight)

        let scrolls = fitting > maxHeight
        if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
        guard fieldHeight.constant != target else { return false }
        guard animated, window != nil, UIView.areAnimationsEnabled, let root = layoutRoot else {
            fieldHeight.constant = target
            return true
        }
        #if DEBUG
        if Self.logsRise {
            debugLogKeyboardStep(String(format: "grow %.1f->%.1f", fieldHeight.constant, target))
        }
        #endif
        UIView.animate(
            springDuration: Self.growthSpringDuration, bounce: 0, initialSpringVelocity: 0,
            delay: 0, options: [.allowUserInteraction]
        ) {
            self.fieldHeight.constant = target
            root.layoutIfNeeded()
        }
        return false
    }

    /// The line-growth spring: critically damped, as UIKit's own layout
    /// springs are, and about as long as the keyboard's curve — the 0.5 s
    /// default of `UIView.animate(springDuration:)` trails a typed line.
    static let growthSpringDuration: TimeInterval = 0.35

    /// The view whose layout the field's growth runs in: the host
    /// controller's root view — the nearest ancestor a view controller owns —
    /// so the host's `viewDidLayoutSubviews` (its stream's clearance and
    /// offset) runs inside the same animation. The bar's superview at worst.
    private var layoutRoot: UIView? {
        var candidate = superview
        while let view = candidate {
            if view.next is UIViewController { return view }
            candidate = view.superview
        }
        return superview
    }
}

extension CommentsInputBar: UITextViewDelegate {
    /// A guest cannot write: the field opens the sign-up sheet instead of the
    /// keyboard, and takes focus after they sign up — the comment they were
    /// about to write. Every entry into editing passes here (a tap, a reply
    /// row, the emote panel), so this one check covers them all.
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        guard let gate = MemberGates.gate(from: self), !gate.isMember else { return true }
        Task { @MainActor [weak self] in
            guard await gate.requireMember(for: .comment) else { return }
            self?.textView.becomeFirstResponder()
        }
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = textView.hasText
        updateFieldAction()
        updateFieldHeight(animated: true)
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
