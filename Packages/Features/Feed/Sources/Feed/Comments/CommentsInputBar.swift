import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import UIKit
import CoreModels
import CoreNavigation

/// THE ONE COMPOSER (#2308): a post's comments and a conversation's
/// messages — and the text post's first message — in the app's native Liquid
/// Glass grammar, built from ONE contract (`configuration`,
/// `ComposerConfiguration`) where each host declares only what differs: its
/// voice, its attachments, its emote panel and its column. One layout, one
/// behaviour, every host: tap to type, hold to talk where the host's voice
/// records, the own bubble at the row's end.
///
/// AN INPUT ROW AND A TRAILING COLUMN, one view:
///
///     ——————————————————————————————╭stake╮
///     ——————————————————————————————╰─────╯
///     [avatar][field  ☺][📎…][☺/↑][sound/pin]
///
/// The INPUT ROW — avatar, field, the host's attachments and the own bubble
/// — is the bar's bottom edge at rest: a host rests the bar
/// `SnapActionColumn.inputRestingGap` above its footer line, which is
/// `SnapActionColumn.glassGap` above the toolbar's glass (asked 2026-10-01:
/// the field sat too far above the toolbar). The trailing COLUMN (a post's,
/// `ComposerConfiguration.Column.post`) — the rail slot and the stake
/// (boost) bubble over it — is the ACTION COLUMN's two bubbles
/// (`SnapActionColumn`): both the comment band's height, one md apart,
/// standing exactly on the media layout's like pill and sound bubble. The
/// slot rests on the field's line (#669), and the avatar, the field, the own
/// bubble and the slot are one row of `SnapActionColumn.bubbleSize` (#680).
/// The stake (a pill, #669) holds its station over the slot, and a growing
/// field rises BESIDE it. Everything is INSIDE the bar's bounds at rest, so
/// the bar's height (and `restingHeight(for:)`) include it and every host's
/// clearance follows; the empty run left of the column is NOT part of the bar
/// for touches (`point(inside:with:)`), so the stream behind it keeps its taps.
///
/// **THE KEYBOARD MOVES THE INPUT ROW, NEVER THE COLUMN** (asked 2026-10-02).
/// The host pins the BAR at its resting place for good and hands it the
/// keyboard's guide (`riseWithKeyboard(of:)`): only the row — the avatar,
/// the field, the attachments and the own bubble — rides the keyboard's top,
/// above the bar's own bounds, and the column's bubbles stay on the media
/// layout's coordinates (the keyboard covers them). As the row rises clear
/// of the column it WIDENS into the column's width — a function of how far
/// it has risen (`riseProgress(lift:clearance:)`), read off the solved
/// layout on every pass, so it follows the keyboard's own animation and an
/// interactive dismissal frame by frame.
///
/// The slot wears the host's action — REPOST on a post, nothing on a post
/// that does not exist yet (`railFace`) — and nothing else: typing never
/// changes it. The OWN BUBBLE is the emote button over an empty field and
/// the SEND over a draft (a symbol replace), on every host (#2308: the
/// comments' inline waveform and send are gone).
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

    // MARK: The contract (#2308)

    /// What this host declares — its voice, its attachments, its emote panel
    /// and its column — and nothing else: the row, the own bubble, tap to
    /// type, hold to talk and the attachments' rule are the composer's, the
    /// same for every host. A post's comments by default.
    var configuration: ComposerConfiguration = .comments {
        didSet { applyConfiguration(from: oldValue) }
    }

    private func applyConfiguration(from old: ComposerConfiguration) {
        if !ComposerConfiguration.sameEntries(configuration.attachments, old.attachments) {
            rebuildAttachmentBar()
        }
        if configuration.column != old.column { applyColumn() }
        guard configuration.voice != old.voice else { return }
        // The field's hold exists only where it records: a comment's field
        // keeps UIKit's own long press alone.
        if speaksFromField {
            field.addGestureRecognizer(fieldVoiceHold)
        } else {
            field.removeGestureRecognizer(fieldVoiceHold)
        }
        updateFieldAction()
        applyPlaceholder()
    }

    /// No column (a conversation, the comments sheet): no stake, no slot, no
    /// post actions — whatever the column's faces were last set to.
    private func applyColumn() {
        guard configuration.column == .none else { return }
        showsStake = false
        showsPostActions = false
        railFace = .noSlot
    }

    /// The voice hold (#2102, #2183): the empty field's long press, wherever
    /// the host's voice records (`speaksFromField`).
    enum VoiceHoldEvent: Equatable {
        /// The empty field's long press began.
        case began
        /// The finger's travel from touch-down: `leading` toward the leading
        /// edge (mirrored right-to-left), `up` upward.
        case moved(leading: CGFloat, up: CGFloat)
        case ended(leading: CGFloat)
        /// The system took the touch.
        case cancelled
        /// VoiceOver's double-tap: holding is impractical, so it records
        /// straight away, locked.
        case accessibilityStart
    }

    /// The recorder's ear (`VoiceComposer.attach`). The field promises a
    /// voice only once one listens (`promisesVoice`).
    var onVoiceHold: ((VoiceHoldEvent) -> Void)? {
        didSet {
            guard (onVoiceHold == nil) != (oldValue == nil) else { return }
            applyPlaceholder()
            updateFieldAction()
        }
    }

    /// Whether the field PROMISES a voice — "Hold for voice, tap to type",
    /// VoiceOver's record action: where the host's voice records and a
    /// recorder listens. A post's comments declare a voice comment (#2309),
    /// but a source that carries none attaches no recorder, and its field
    /// promises nothing.
    private var promisesVoice: Bool { speaksFromField && onVoiceHold != nil }

    /// A comment's reply is armed with the keyboard up — a row's tap focuses
    /// the field — and goes with it (`onIdleDismiss`): so a voice reply
    /// (#2309) is held from the focused, empty field while a reply is armed.
    /// Elsewhere, focused, the field writes (2026-11-08).
    private var recordsReplyWhileWriting: Bool { configuration.voice == .comment && replyName != nil }

    private var voiceHoldStart: CGPoint = .zero

    /// "Hold for voice, tap to type" (the owner, 2026-11-07): where the
    /// host's voice records (`speaksFromField`) a long press on the empty
    /// field records — the own bubble grows into the mic — and a tap writes.
    /// Later than a tap (0.3 s); a draft keeps the field's native long press
    /// (the loupe, the selection).
    private lazy var fieldVoiceHold: UILongPressGestureRecognizer = {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(voiceHeld(_:)))
        hold.minimumPressDuration = 0.3
        hold.delegate = self
        return hold
    }()

    /// Where the mic and the lock stand while the field's hold records: the
    /// own bubble, which grows into the mic (#2102).
    var voiceHoldAnchor: UIView { rowActionButton }

    /// THE OWN BUBBLE (#2102, the owner, 2026-11-07, Telegram's; every host
    /// since #2308): a glass bubble of its own at the row's end — the emote
    /// button over an empty field, the send over a draft. It belongs to the
    /// INPUT ROW: it rides the keyboard with the avatar and the field, where
    /// a post's column stays down under the keyboard.
    private let rowActionButton = UIButton(configuration: .glass())

    /// Whether the empty field's long press records: the host's voice
    /// (`ComposerConfiguration.voice`) — a post's comments record a voice
    /// comment (#2309). Off, the field only writes, and nothing promises a
    /// voice.
    var speaksFromField: Bool { configuration.voice.records }
    /// The field's emote button's width: 0 while it is gone
    /// (`updateEmoteToggle`), so the text and the placeholder run on.
    private var emoteToggleWidth: NSLayoutConstraint!
    /// Whether the field's emote button was last asked to show: a change
    /// animates (`animateEmoteToggle`), a repeat does nothing.
    private var emoteToggleShown = true
    /// The slot closing for the text once the emote button is out: stopped
    /// when the button comes back before it ends, or its frames ran on under
    /// the button's way in — typed fast, the glyph came in stretched from
    /// the left (the owner's video, 2026-11-09).
    private var emoteSlotAnimator: UIViewPropertyAnimator?
    /// The emote button on its way out: its slot stays open until it is.
    private var emoteToggleLeaving = false
    /// Whether the bar has had a real layout: the first is never animated.
    private var hasLaidOutOnce = false
    /// The own bubble steps aside while a locked or paused take covers the
    /// field (it carries its own send): the field takes the row's width.
    private var rowActionStepsAside = false

    /// The own bubble steps aside or comes back as glass does (the owner,
    /// 2026-11-07): the field stretches over its place, or gives it back, in
    /// one spring, while the bubble shrinks away or swells in.
    private func setRowActionAside(_ aside: Bool) {
        guard aside != rowActionStepsAside else { return }
        rowActionStepsAside = aside
        guard window != nil, !MotionPreference.reducesMotion else {
            if !aside, !voiceHolding { wearRestingFace() }
            rowActionButton.isHidden = aside
            rowActionButton.alpha = 1
            rowActionButton.transform = .identity
            return setNeedsLayout()
        }
        let away = CGAffineTransform(scaleX: 0.5, y: 0.5)
        if !aside {
            if !voiceHolding { wearRestingFace() }
            rowActionButton.isHidden = false
            rowActionButton.alpha = 0
            rowActionButton.transform = away
        }
        setNeedsLayout()
        UIView.animate(
            springDuration: 0.45, bounce: aside ? 0 : 0.2, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.rowActionButton.alpha = aside ? 0 : 1
            self.rowActionButton.transform = aside ? away : .identity
            self.layoutIfNeeded()
        } completion: { _ in
            guard self.rowActionStepsAside else { return }
            self.rowActionButton.isHidden = true
            self.rowActionButton.alpha = 1
            self.rowActionButton.transform = .identity
        }
    }

    // MARK: The hold's bubble (#2102)

    /// How big the action bubble grows under a held finger — the bubble
    /// itself, not a disc laid over it (the owner, 2026-11-07).
    static let voiceHoldSide: CGFloat = 76
    private var voiceHolding = false
    private var voiceHoldShift: CGFloat = 0
    private var voiceHoldSwell: CGFloat = 1
    private var voiceHoldTrash = false
    private var rowActionWidth: NSLayoutConstraint!
    private var rowActionHeight: NSLayoutConstraint!
    private var rowActionTrailing: NSLayoutConstraint!
    private var rowActionBottom: NSLayoutConstraint!
    /// The held bubble's glyph — the mic, the bin — a view of the bar's own
    /// centred on the bubble by constraints: solved in the same pass as the
    /// bubble's size and place, it stays centred through every move. Drawn
    /// by the button, it lagged its glass and drifted off centre (filmed,
    /// 2026-11-07).
    private let holdGlyph = UIImageView()
    private static let holdGlyphConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    /// The hold is over and the bubble shrinks home: the bar's glyph carries
    /// the field action's symbol back, and the button takes it over once
    /// the bubble has landed (`landVoiceHold`).
    private var voiceHoldReturning = false
    /// The held glyph fades away with a bubble stepping aside.
    private var holdGlyphLeaving = false

    /// The hold began: the bubble grows where it stands and wears the mic.
    /// Its glass is sized by its constraints, never a transform: it redraws
    /// at every size, as a system bubble swells.
    func beginVoiceHold() {
        guard !voiceHolding else { return }
        voiceHolding = true
        voiceHoldReturning = false
        if holdGlyphLeaving {
            holdGlyphLeaving = false
            holdGlyph.layer.removeAllAnimations()
            holdGlyph.alpha = 1
            holdGlyph.transform = .identity
        }
        voiceHoldShift = 0
        voiceHoldSwell = 1
        voiceHoldTrash = false
        applyVoiceHoldFace()
        layOutVoiceHold(spring: 0.42, bounce: 0.3)
        updateAttachments()
    }

    /// The finger slides toward cancel: the bubble follows it, and wears
    /// the bin a little of the way in — the mic again if the finger comes
    /// back.
    func moveVoiceHold(cancel: CGFloat, travel: CGFloat) {
        guard voiceHolding else { return }
        voiceHoldShift = cancel * travel
        let trash = cancel > 0.15
        if trash != voiceHoldTrash {
            voiceHoldTrash = trash
            applyVoiceHoldFace()
        }
        layOutVoiceHold(spring: nil)
    }

    /// The voice's level, 0…1: the held bubble breathes with it.
    func setVoiceHoldLevel(_ level: Float) {
        guard voiceHolding, !MotionPreference.reducesMotion else { return }
        voiceHoldSwell = 1 + CGFloat(min(1, level * 2)) * 0.12
        layOutVoiceHold(spring: 0.15, bounce: 0)
    }

    /// The hold is over — locked, sent, cancelled: the bubble springs back
    /// to its place, its size and its face.
    func endVoiceHold() {
        guard voiceHolding else { return }
        voiceHolding = false
        voiceHoldShift = 0
        voiceHoldSwell = 1
        voiceHoldTrash = false
        // A locked or paused take has already sent the bubble aside: its
        // mic leaves with it — no resting face over the take's send (filmed,
        // 2026-11-07). Otherwise the resting face rides home on the glyph.
        voiceHoldReturning = !rowActionStepsAside
        if rowActionStepsAside { carryHoldGlyphAway() }
        applyVoiceHoldFace()
        layOutVoiceHold(spring: 0.42, bounce: 0.15) { [weak self] in self?.landVoiceHold() }
        updateAttachments()
    }

    /// The bubble steps aside under the held glyph: the glyph shrinks and
    /// fades with it, wearing what it wore.
    private func carryHoldGlyphAway() {
        guard !holdGlyph.isHidden else { return }
        holdGlyphLeaving = true
        let finish = { [weak self] in
            guard let self, self.holdGlyphLeaving else { return }
            self.holdGlyphLeaving = false
            self.holdGlyph.isHidden = true
            self.holdGlyph.alpha = 1
            self.holdGlyph.transform = .identity
        }
        guard window != nil, !MotionPreference.reducesMotion else { return finish() }
        UIView.animate(springDuration: 0.45, bounce: 0, options: [.beginFromCurrentState]) {
            self.holdGlyph.alpha = 0
            self.holdGlyph.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        } completion: { _ in
            finish()
        }
    }

    /// The bubble is home: the button wears the field action's symbol
    /// again, where the bar's glyph has just brought it.
    private func landVoiceHold() {
        guard voiceHoldReturning, !voiceHolding else { return }
        voiceHoldReturning = false
        // Taken over in place: no Replace replayed over the glyph's.
        wearRestingFace()
    }

    /// The bubble's resting face put on in place, no Replace played; later
    /// changes replace again.
    private func wearRestingFace() {
        applyVoiceHoldFace(replaces: false)
        rowActionButton.configuration?.symbolContentTransition = UISymbolContentTransition(.replace.offUp, options: .speed(2))
    }

    var isVoiceHolding: Bool { voiceHolding }

    /// The bubble's size and place for the hold as it stands, grown about
    /// its own centre, slid toward cancel.
    private func layOutVoiceHold(
        spring duration: TimeInterval?, bounce: CGFloat = 0, landed: (() -> Void)? = nil
    ) {
        let side = voiceHolding ? Self.voiceHoldSide * voiceHoldSwell : Metrics.controlSize
        let grow = (side - Metrics.controlSize) / 2
        rowActionWidth.constant = side
        rowActionHeight.constant = side
        rowActionTrailing.constant = grow - voiceHoldShift
        rowActionBottom.constant = grow
        guard let duration, window != nil, !MotionPreference.reducesMotion else {
            setNeedsLayout()
            landed?()
            return
        }
        UIView.animate(
            springDuration: duration, bounce: bounce, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutIfNeeded()
        } completion: { _ in
            landed?()
        }
    }

    /// The bubble's face: the mic on the brand's glass while held, the bin
    /// on red past the cancel's start, the field action's otherwise — each
    /// change the symbol's own Replace, quick enough to keep up with the
    /// glass's colour.
    ///
    /// ⚠️ PROMINENT GLASS WHILE HELD: plain glass ignores a background
    /// colour, and the white mic vanished on it (filmed, 2026-11-07). The
    /// prominent glass wears the button's tint.
    ///
    /// ⚠️ THE WAY BACK IS THE BAR'S GLYPH TOO: handed back to the button
    /// in the grown bubble, the symbol kept the frame it had before the
    /// hold — the top-left corner of the big bubble — and slid to the
    /// centre from there (filmed, 2026-11-07). A button lays its image out
    /// only inside the shrink's animation, whatever is forced before it.
    private func applyVoiceHoldFace(replaces: Bool = true) {
        var face: UIButton.Configuration = voiceHolding ? .prominentGlass() : .glass()
        face.cornerStyle = .capsule
        let quick = UISymbolContentTransition(.replace.offUp, options: .speed(2))
        if voiceHolding {
            // The glyph is the bar's (`holdGlyph`): the button wears none.
            face.image = nil
            // Each symbol carries its own size, so a Replace never resizes
            // the outgoing one first (a view-wide configuration would).
            let glyph = UIImage(
                systemName: voiceHoldTrash ? "trash.fill" : "mic.fill", withConfiguration: Self.holdGlyphConfiguration
            )!
            if holdGlyph.isHidden {
                holdGlyph.image = glyph
                holdGlyph.isHidden = false
            } else if holdGlyph.image != glyph {
                holdGlyph.setSymbolImage(glyph, contentTransition: .replace.offUp, options: .speed(2))
            }
            rowActionButton.tintColor = voiceHoldTrash ? .systemRed : Palette.tint
        } else if voiceHoldReturning {
            // The field action's symbol rides home on the bar's glyph,
            // centred all the way, at the size the button draws it: the
            // button scales its symbols up a text style's step, and the
            // glyph's bare size jumped at the hand-over (filmed, 2026-11-07).
            face.image = nil
            let sends = hasDraft || isSending
            if var home = bubbleImage(sends: sends) {
                // The emote face carries its own size (`emoteToggleConfiguration`),
                // which the button draws as is: the button's would shrink it.
                let carriesItsSize = !sends
                if !carriesItsSize, let drawn = rowActionButton.imageView?.preferredSymbolConfiguration {
                    home = home.applyingSymbolConfiguration(drawn) ?? home
                }
                if holdGlyph.image != home {
                    holdGlyph.setSymbolImage(home, contentTransition: .replace.offUp, options: .speed(2))
                }
            }
            holdGlyph.isHidden = false
            rowActionButton.tintColor = nil
        } else if rowActionStepsAside {
            // Aside, the bubble wears nothing: it shows again with its face
            // (`setRowActionAside`).
            face.image = nil
            rowActionButton.tintColor = nil
        } else {
            if !holdGlyphLeaving { holdGlyph.isHidden = true }
            if replaces { face.symbolContentTransition = quick }
            face.image = bubbleImage(sends: hasDraft || isSending)
            face.baseForegroundColor = hasDraft || isSending ? Self.sendTint : Self.restingTint
            face.showsActivityIndicator = isSending
            rowActionButton.tintColor = nil
        }
        rowActionButton.configuration = face
    }

    /// The own bubble's room at the row's end: its side and the gap before
    /// it — none while it steps aside, or while there is no input row (a
    /// guest's sign-up, a post that takes no comments).
    private var ownBubbleInset: CGFloat {
        rowActionStepsAside || field.isHidden ? 0 : Metrics.controlSize + Spacing.sm
    }

    /// Where the own bubble RESTS: at the row's end, short of a post's slot
    /// by the slot's room as the rise leaves it (`applyRise`) — so the
    /// bubble rides the keyboard with the row and stands beside the column
    /// at rest. The bubble's hold grows and slides it about this place, and
    /// the attachments are counted from it, so the hold never moves them.
    private let ownBubbleSlot = UILayoutGuide()
    private var ownBubbleSlotTrailing: NSLayoutConstraint!

    // MARK: The attachments (#2305, #2308, #2344)

    // What the reader can attach from the input row is the host's LIST
    // (`ComposerConfiguration.attachments`), in the row's order: ONE glass
    // capsule holding every entry's glyph (#2344, the owner 2026-11-12),
    // BETWEEN THE FIELD AND THE OWN BUBBLE —
    //
    //     [avatar][field][📷 🖼][☺]
    //
    // — never right of it: hiding it would make the own bubble jump. The
    // capsule is a standalone native toolbar's (`ComposerAttachmentToolbar`):
    // while the reader writes it FOLDS INTO THE OWN BUBBLE, its neighbour,
    // the toolbar's own fold, and the field widens into the room in step;
    // done writing, it comes back out of it. A host that declares none (a
    // post's comments) has no toolbar and keeps its row exactly. The same
    // entries with new actions keep their items: a tap reads its action off
    // the list (`attachmentTapped`).
    private var attachmentBar: ComposerAttachmentToolbar?
    /// The toolbar's place: its anchor under the own bubble's resting place
    /// (`alignAttachmentBar` corrects for the toolbar's own margins).
    private var attachmentBarTrailing: NSLayoutConstraint?
    private var attachmentBarCentreY: NSLayoutConstraint?
    /// What the capsule was last told — the toolbar's items change at once,
    /// their fold runs after.
    private var attachmentsShown = false

    /// Whether the attachments show (#2305, Messenger's rule; the contract's
    /// one rule for every host's list, #2308): only while the reader is NOT
    /// writing — the field not being edited, and the draft empty (no text,
    /// no voice take on its way or held, later no attachment), even with the
    /// keyboard down: a half-written message never gets a narrowed field.
    /// Pure, for tests.
    static func showsAttachments(hasSources: Bool, isEditing: Bool, draft: ComposerDraftContents) -> Bool {
        hasSources && !isEditing && draft.isEmpty
    }

    /// What the draft holds now.
    private var draftContents: ComposerDraftContents {
        var contents: ComposerDraftContents = []
        if hasDraft { contents.insert(.text) }
        if voiceOverlay != nil || voiceHolding { contents.insert(.voiceTake) }
        return contents
    }

    private var attachmentCount: Int { attachmentBar?.sourceItems.count ?? 0 }

    private var attachmentsWanted: Bool {
        Self.showsAttachments(
            hasSources: attachmentCount > 0 && !field.isHidden,
            isEditing: textView.isFirstResponder,
            draft: draftContents
        )
    }

    /// The capsule's room at the field's end, while it shows: the capsule
    /// and the gap before it.
    private var attachmentsInset: CGFloat {
        attachmentsShown ? ComposerAttachmentToolbar.capsuleWidth(count: attachmentCount) + Spacing.sm : 0
    }

    /// One toolbar for the list, on the row's line and riding the keyboard
    /// with the field, laid from the own bubble's RESTING place
    /// (`ownBubbleSlot`), so the bubble's hold (which grows and slides it)
    /// never moves the capsule. Under the own bubble: the toolbar's anchor
    /// stands beneath it.
    private func rebuildAttachmentBar() {
        attachmentBar?.removeFromSuperview()
        attachmentBar = nil
        attachmentBarTrailing = nil
        attachmentBarCentreY = nil
        let sources = configuration.attachments
        guard !sources.isEmpty else {
            attachmentsShown = false
            return setNeedsLayout()
        }
        let bar = ComposerAttachmentToolbar(sources: sources, tint: Self.restingTint) { [weak self] id in
            self?.attachmentTapped(id)
        }
        // ⚠️ THE TOOLBAR PLACES ITS ITEMS IN ITS OWN PASS, after ours — and
        // its first one may come later still, once its items are installed.
        // Read from our pass only, the anchor was not where the toolbar
        // finally put it, and the capsule stood a margin (15.5 pt) short of
        // the own bubble. Each of its passes re-reads the anchor.
        bar.onLayout = { [weak self] in self?.attachmentBarDidLayOut() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.maximumContentSizeCategory = .large
        insertSubview(bar, belowSubview: rowActionButton)
        let trailing = bar.trailingAnchor.constraint(equalTo: ownBubbleSlot.trailingAnchor)
        let centreY = bar.centerYAnchor.constraint(equalTo: ownBubbleSlot.centerYAnchor)
        NSLayoutConstraint.activate([
            trailing,
            centreY,
            bar.widthAnchor.constraint(equalToConstant: ComposerAttachmentToolbar.width(count: sources.count)),
        ])
        attachmentBar = bar
        attachmentBarTrailing = trailing
        attachmentBarCentreY = centreY
        // A new list lands in place: nothing to animate from.
        attachmentsShown = attachmentsWanted
        bar.setShowsSources(attachmentsShown, animated: false)
        setNeedsLayout()
    }

    /// A source's tap: the action its entry carries now.
    private func attachmentTapped(_ id: String) {
        configuration.attachments.first { $0.id == id }?.action()
    }

    /// Lays the toolbar so its anchor stands exactly on the own bubble's
    /// resting place: the toolbar keeps margins of its own, read off its
    /// layout rather than assumed. Settled passes only — never inside an
    /// animation, which would slide the capsule. Returns whether it moved.
    /// `laysOutToolbar`: from our pass, the toolbar is laid out first; from
    /// its own (`attachmentBarDidLayOut`), it just was.
    private func alignAttachmentBar(laysOutToolbar: Bool = true) -> Bool {
        guard let bar = attachmentBar, let trailing = attachmentBarTrailing, let centreY = attachmentBarCentreY,
              UIView.inheritedAnimationDuration == 0, bar.bounds.width > 0 else { return false }
        if laysOutToolbar { UIView.performWithoutAnimation { bar.layoutIfNeeded() } }
        let anchor = bar.anchorView
        guard anchor.superview != nil, anchor.bounds.width > 0 else { return false }
        let centre = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: self)
        let slot = ownBubbleSlot.layoutFrame
        let dx = slot.midX - centre.x
        let dy = slot.midY - centre.y
        // A toolbar not laid out yet reads nonsense: no chase across the row.
        guard abs(dx) > 0.5 || abs(dy) > 0.5, abs(dx) < bar.bounds.width, abs(dy) < bar.bounds.height else {
            return false
        }
        // Leading/trailing constants run against the layout direction.
        trailing.constant += dx * layoutDirectionSign
        centreY.constant += dy
        return true
    }

    /// The toolbar has placed its items: the anchor read where they landed,
    /// and the toolbar moved onto the own bubble on our next pass — a move
    /// that keeps its size, so it lays nothing out again.
    private func attachmentBarDidLayOut() {
        guard alignAttachmentBar(laysOutToolbar: false) else { return }
        setNeedsLayout()
    }

    /// The fold's spring: the toolbar's own, as the lab measured it at
    /// 60 Hz (`SnapGlassColumn`: k 260, ζ 0.75, after a 0.03 s wait) — the
    /// field's end rides it while the capsule folds.
    static var attachmentFoldSpring: (duration: TimeInterval, bounce: CGFloat, delay: TimeInterval) {
        (2 * .pi / SnapGlassColumn.springK.squareRoot(), 1 - CGFloat(SnapGlassColumn.springZeta), SnapGlassColumn.startDelay)
    }

    /// The capsule in or out, as the reader starts or stops writing: it
    /// folds into the own bubble — or comes back out of it — by the
    /// toolbar's own animation, while the field's end springs to its new
    /// width on the toolbar's spring, in the same turn. Reduce Motion: the
    /// field at once, the capsule cross-fading. Off screen, at once.
    private func updateAttachments() {
        guard let bar = attachmentBar else { return }
        let shows = attachmentsWanted
        guard shows != attachmentsShown else { return }
        guard window != nil, hasLaidOutOnce else {
            attachmentsShown = shows
            bar.setShowsSources(shows, animated: false)
            return setNeedsLayout()
        }
        // What is pending lands first, unanimated — a placeholder moving to
        // the field's start on focus — so the spring moves only the width.
        UIView.performWithoutAnimation { layoutIfNeeded() }
        attachmentsShown = shows
        #if DEBUG
        debugAttachmentMotions += 1
        #endif
        setNeedsLayout()
        if MotionPreference.reducesMotion {
            UIView.performWithoutAnimation { layoutIfNeeded() }
            bar.setShowsSources(shows, animated: true, crossFades: true)
            return
        }
        // The fold first, outside the field's block: the toolbar runs its
        // own animation, and its items are never laid out inside ours.
        bar.setShowsSources(shows, animated: true)
        let spring = Self.attachmentFoldSpring
        UIView.animate(
            springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: 0, delay: spring.delay,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutIfNeeded()
        }
    }

    #if DEBUG
    /// The input row — the avatar and the field — shows (#2216).
    var debugShowsInputRow: Bool { !field.isHidden && !avatarBubble.isHidden }
    var debugRowActionButton: UIButton { rowActionButton }
    var debugHoldGlyph: UIImageView { holdGlyph }
    var debugShowsRowAction: Bool { !rowActionButton.isHidden }
    /// The field's emote button shows, with room.
    /// Whether the field's emote button is shown, or on its way in — not
    /// once it is leaving.
    var debugShowsFieldEmoteToggle: Bool { emoteToggleShown && !emotes.toggleButton.isHidden && emoteToggleWidth.constant > 0 }
    /// The emote panel stands in for the keyboard.
    var debugShowsEmotePanel: Bool { emotes.isShowingPanel }
    /// The placeholder's words.
    var debugPlaceholder: String? { placeholderLabel.text }
    /// The placeholder's frame and the field's, in the field's space.
    var debugPlaceholderFrame: CGRect { placeholderLabel.frame }
    var debugPlaceholderAlignment: NSTextAlignment { placeholderLabel.textAlignment }
    /// How many times the field's emote button came or went in sight.
    private(set) var debugEmoteToggleMotions = 0
    var debugEmoteToggle: UIButton { emotes.toggleButton }
    var debugEmoteSlotWidth: CGFloat { emoteToggleWidth.constant }
    var debugFieldBounds: CGRect { field.contentView.bounds }
    /// Whether the field's long press would begin now.
    var debugFieldHoldBegins: Bool { gestureRecognizerShouldBegin(fieldVoiceHold) }
    /// The field's text view, for its VoiceOver actions.
    var debugTextView: UITextView { textView }
    /// The attachments' items, in the row's order (#2305) — the capsule's
    /// glyphs (#2344).
    var debugAttachmentItems: [UIBarButtonItem] { attachmentBar?.sourceItems ?? [] }
    /// The capsule's toolbar, nil without attachments (#2344).
    var debugAttachmentBar: ComposerAttachmentToolbar? { attachmentBar }
    /// Whether the attachments show — or are on their way in.
    var debugShowsAttachments: Bool { attachmentsShown }
    /// How many times the attachments came or went in sight.
    private(set) var debugAttachmentMotions = 0
    /// The field's trailing edge from the bar's, as last laid out.
    var debugFieldTrailingInset: CGFloat { -fieldTrailing.constant }
    #endif

    #if DEBUG
    var debugShowsVoiceDelete: Bool { !voiceDeleteButton.isHidden }
    func debugTapVoiceDelete() { voiceDeleteButton.sendActions(for: .primaryActionTriggered) }
    #endif

    /// Shows a recording strip or bar in the field's place (#2102): the text
    /// and the emote button — and the own bubble steps aside when
    /// `coversButton` (the locked and paused bars carry their own send). Nil
    /// gives the field back.
    func showVoiceOverlay(_ overlay: UIView?, coversButton: Bool = false) {
        // The row is the take's: the attachments go (#2305) — once the
        // strip is laid out, whichever way this returns.
        defer { updateAttachments() }
        let previous = voiceOverlay
        let animated = window != nil && !MotionPreference.reducesMotion
        voiceOverlay = overlay
        let showing = overlay != nil
        voiceOverlayCoversButton = coversButton
        updateEmoteToggle()
        setRowActionAside(showing && coversButton)
        onVoiceOverlayChange?(showing)
        setFieldWordsShown(!showing, animated: animated)
        if let previous, previous !== overlay { retireVoiceOverlay(previous, animated: animated) }
        guard let overlay else { return }
        if previous === overlay {
            // The same strip, another bar (locked, paused): only its end
            // moves, as the bubble steps aside.
            voiceOverlayTrailing?.isActive = false
            voiceOverlayTrailing = voiceOverlayTrailingConstraint(for: overlay, coversButton: coversButton)
            voiceOverlayTrailing?.isActive = true
            if animated {
                UIView.animate(springDuration: 0.45, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.field.contentView.layoutIfNeeded()
                }
            }
            return
        }
        // A strip still leaving (cancelled, then held again) starts over.
        overlay.layer.removeAllAnimations()
        overlay.removeFromSuperview()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        field.contentView.addSubview(overlay)
        let trailing = voiceOverlayTrailingConstraint(for: overlay, coversButton: coversButton)
        voiceOverlayTrailing = trailing
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: field.contentView.leadingAnchor, constant: Spacing.md),
            trailing,
            overlay.topAnchor.constraint(equalTo: field.contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
        ])
        // ⚠️ LAID OUT AT ONCE, OUTSIDE ANY ANIMATION (the owner, 2026-11-07):
        // left to the next pass, the strip was laid out inside the bubble's
        // grow spring, and its parts flew in from the field's top-left
        // corner the first time it showed.
        UIView.performWithoutAnimation {
            field.contentView.layoutIfNeeded()
            overlay.layoutIfNeeded()
        }
        overlay.alpha = 1
        overlay.transform = .identity
        guard animated else { return }
        // In: it fades in sliding a little from the end it comes from.
        overlay.alpha = 0
        overlay.transform = CGAffineTransform(translationX: Self.voiceOverlaySlide * layoutDirectionSign, y: 0)
        UIView.animate(springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState]) {
            overlay.alpha = 1
            overlay.transform = .identity
        }
    }

    /// How far a take's strip slides as it comes in or leaves.
    static let voiceOverlaySlide: CGFloat = 16

    private var layoutDirectionSign: CGFloat { effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1 }

    private var voiceOverlayTrailing: NSLayoutConstraint?

    private func voiceOverlayTrailingConstraint(for overlay: UIView, coversButton: Bool) -> NSLayoutConstraint {
        overlay.trailingAnchor.constraint(
            equalTo: field.contentView.trailingAnchor, constant: coversButton ? -Spacing.xs : 0
        )
    }

    /// The strip leaves — sent, cancelled: it fades out sliding toward the
    /// cancel's side, unless it is shown again meanwhile.
    private func retireVoiceOverlay(_ overlay: UIView, animated: Bool) {
        guard animated else {
            overlay.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState]) {
            overlay.alpha = 0
            overlay.transform = CGAffineTransform(translationX: -Self.voiceOverlaySlide * self.layoutDirectionSign, y: 0)
        } completion: { _ in
            guard self.voiceOverlay !== overlay else { return }
            overlay.removeFromSuperview()
            overlay.alpha = 1
            overlay.transform = .identity
        }
    }

    /// The field's own words — the text, or the placeholder — give way to a
    /// take's strip and come back after it, fading.
    private func setFieldWordsShown(_ shown: Bool, animated: Bool) {
        let placeholderHidden = !shown || hasDraft
        guard animated, textView.isHidden == shown else {
            textView.isHidden = !shown
            placeholderLabel.isHidden = placeholderHidden
            textView.alpha = 1
            placeholderLabel.alpha = 1
            return
        }
        if shown {
            textView.isHidden = false
            placeholderLabel.isHidden = placeholderHidden
            textView.alpha = 0
            placeholderLabel.alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0.08, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.textView.alpha = 1
                self.placeholderLabel.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
                self.textView.alpha = 0
                self.placeholderLabel.alpha = 0
            } completion: { _ in
                guard self.voiceOverlay != nil else { return }
                self.textView.isHidden = true
                self.placeholderLabel.isHidden = true
                self.textView.alpha = 1
                self.placeholderLabel.alpha = 1
            }
        }
    }
    private(set) var voiceOverlay: UIView?
    private var voiceOverlayCoversButton = false
    /// A take shows in the field's place, or the field is back: hosts clear
    /// what floats over the composer's end (the lock rises there).
    var onVoiceOverlayChange: ((Bool) -> Void)?

    /// The bin in the avatar's place while a voice take can be thrown away
    /// (#2102): `onDelete` nil gives the face back. The two cross-fade.
    func showVoiceDelete(_ onDelete: (() -> Void)?) {
        onVoiceDelete = onDelete
        let showing = onDelete != nil
        guard voiceDeleteButton.isHidden == showing else { return }
        let swap = {
            self.voiceDeleteButton.isHidden = !showing
            self.avatarView.isHidden = showing
            self.avatarButton.isHidden = showing
        }
        guard window != nil, !MotionPreference.reducesMotion else { return swap() }
        UIView.transition(
            with: avatarBubble.contentView, duration: 0.2,
            options: [.transitionCrossDissolve, .allowUserInteraction], animations: swap
        )
    }

    @objc private func voiceHeld(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: self)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = rightToLeft ? point.x - voiceHoldStart.x : voiceHoldStart.x - point.x
        let up = voiceHoldStart.y - point.y
        switch hold.state {
        case .began:
            voiceHoldStart = point
            onVoiceHold?(.began)
        case .changed:
            onVoiceHold?(.moved(leading: leading, up: up))
        case .ended:
            onVoiceHold?(.ended(leading: leading))
        default:
            onVoiceHold?(.cancelled)
        }
    }
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
        /// No slot at all (#1790): a text post, which has no sound (#1999). Unlike `.empty`,
        /// the field widens into the slot's place.
        case noSlot
        /// The post's Share (#1999): a pushed text page's slot, in the
        /// sound's old place. The toolbar's glyph, label and identifier.
        case share
        /// The way back to the stream's start (#1929): scrolled away from the
        /// newest message (`down`), or from a post's text. The slot's own
        /// action moves to a hold (`HoldToArmPresenter`).
        case returnTo(down: Bool)
    }

    /// Whether the slot has a place in the row: the field stops short of it.
    var keepsRailSlot: Bool { railFace != .noSlot }

    /// The slot's face: ONE glass button wearing the host's action. It is the
    /// action and only the action — a draft never turns it into send (asked
    /// 2026-10-02: the send arrow lives in the field, and the column's bubbles
    /// never change meaning under the thumb).
    var railFace: RailFace = .empty {
        didSet {
            // No column (`ComposerConfiguration.Column.none`): no slot,
            // whatever a host's page state asks.
            if configuration.column == .none, railFace != .noSlot { railFace = .noSlot }
            guard railFace != oldValue else { return }
            applyRailFace()
            // The slot came or went (#1790): the field's edge moves with the
            // next layout pass, which the page change carries.
            if (railFace == .noSlot) != (oldValue == .noSlot) { setNeedsLayout() }
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

    /// The slot's button, for a host that hangs its own hold on it (#1929,
    /// `HoldToArmPresenter`).
    var railHoldTarget: UIView { railButton }
    /// The sound face's cover as drawn now — the way back's hold carries it
    /// on its disc (#1929).
    var railCoverImage: UIImage? { railCoverView.image }

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
        postActions.isUserInteractionEnabled = hostsActionColumn
        postActions.alpha = hostsActionColumn ? 1 : 0
        guard !hostsActionColumn else { return }
        railButton.alpha = 0
        boostButton.alpha = 0
        railRecord.setSpinning(false)
    }

    /// (#1681, the For You root): save and repost upright
    /// between the stake and the slot — drawn here on a text page, whose
    /// column is the composer's; only its room reserved under a media page's
    /// column, which draws its own (`SnapChromeView.showsPostActions`).
    let postActions = SnapPostActionsCapsule()
    var showsPostActions = false {
        didSet {
            if configuration.column == .none, showsPostActions { showsPostActions = false }
            guard showsPostActions != oldValue else { return }
            applyPostActions()
        }
    }
    private var boostAboveRail: NSLayoutConstraint!

    private func applyPostActions() {
        boostAboveRail.constant = -(SnapActionColumn.gap + (showsPostActions ? SnapPostActionsCapsule.columnExtent : 0))
        postActions.isHidden = !showsPostActions || !showsStake
        applyReservedColumn()
        setNeedsLayout()
    }

    /// Whether the column carries the stake bubble. A conversation's does not:
    /// there is nothing there to like. The slot stays where it was.
    var showsStake = true {
        didSet {
            if configuration.column == .none, showsStake { showsStake = false }
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
        for category: UIContentSizeCategory, showsStake: Bool = true, likeFace: Bool = true, postActions: Bool = false
    ) -> CGFloat {
        let bubble = SnapActionColumn.bubbleSize
        let actions = showsStake && postActions ? SnapPostActionsCapsule.columnExtent : 0
        let column = bubble + (showsStake ? stakeSide(likeFace: likeFace) + SnapActionColumn.gap : 0) + actions
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

    /// The SLOT'S ROOM at the row's end at `progress` — what the own bubble
    /// (and the field after it) stands short of: the column's width and the
    /// gap before it at rest (0), nothing at 1. Pure, for tests. With no slot
    /// (#1790), the own bubble reaches the bar's trailing margin.
    @MainActor static func fieldTrailingInset(progress: CGFloat, keepsSlot: Bool = true) -> CGFloat {
        guard keepsSlot else { return 0 }
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
        /// The emote toggle inside the field: 40pt wide on the 38pt line —
        /// room for its widest face, the keyboard glyph (about 39pt at 20pt
        /// and the large scale, `emoteToggleConfiguration`).
        static let emoteToggleWidth: CGFloat = 40
        /// The smallest touch target the field's emote button answers to —
        /// UIKit's 44pt, reached by `hitTest` around their drawn frames,
        /// which the 38pt line cannot hold.
        static let minimumHitSide: CGFloat = 44
        /// The face sits INSET in its glass bubble, a ring of glass around it
        /// — the sound bubble's cover, at the cover's size, so the row's two
        /// ends read as one family of controls (the owner, 2026-10-08, #692):
        /// the one bubble face size (`AvatarImageView.bubbleDiameter`).
        @MainActor static var avatarDiameter: CGFloat { AvatarImageView.bubbleDiameter }
    }

    /// The viewer's face, leading the bar — the composer's answer to the
    /// question every comment row already answers. Same contract as those
    /// rows: the monogram is the RENDERED identity, drawn immediately; the
    /// picture layers over it and never replaces it, so there is no empty
    /// disc and no third loading state.
    /// The app's avatar (#943) does exactly that.
    private let avatarView = AvatarView(diameter: Metrics.avatarDiameter, size: .avatar)
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
    /// A voice take's delete, in the avatar's bubble while a take is locked
    /// or paused (#2102; the owner, 2026-11-06, Telegram's bin on the left).
    private let voiceDeleteButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "trash")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Delete recording"
        button.isHidden = true
        return button
    }()
    private var onVoiceDelete: (() -> Void)?

    // Effect set on window attach: materializing one in init contacts the
    // render server and stalls headless CI simulators (see ci memory).
    private let field = UIVisualEffectView(effect: nil)
    /// Plays its emotes in place while composing (#699); read and written
    /// through `plainText`, the emoji and `:code:`s that are sent.
    private let textView = EmoteTextView()
    private let placeholderLabel = UILabel()
    /// The placeholder at the text's start, or centred in the field — the
    /// field's own instructions, "Hold for voice, tap to type" (the owner,
    /// 2026-11-07).
    private var placeholderLeading: NSLayoutConstraint?
    private var placeholderCentre: NSLayoutConstraint?
    /// The emote panel and the inline `:query` strip for this field; its
    /// smiley sits at the field's trailing end, where iMessage keeps its own.
    private lazy var emotes = EmoteKeyboard(textView: textView)
    private let boostButton = StakeMenuButton(configuration: .glass())
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
    /// The sound face's record in its own glass (#1150), the column bubble's
    /// component: while it shows, the rail button's glass steps aside.
    private let railRecord = SoundRecordGlass()
    private var railCoverView: UIImageView { railRecord.cover }
    /// The rail's sound cover on the media slot (#1772), the bubble's.
    private lazy var railCoverSlot: CoverSlot = {
        let slot = CoverSlot(view: railRecord.cover, size: SnapMediaAttributionView.coverBucket)
        slot.bone?.fill = Surface.skeletonOnDark
        return slot
    }()
    /// The rail button's glass, put back when the face leaves the sound.
    private var railGlassConfiguration: UIButton.Configuration?
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

    /// The own bubble's faces. Send is the filled arrow in a disc —
    /// iMessage's own — in `sendTint`; at rest, the emote button's smile
    /// (the keyboard while the panel is up), in the row's quiet ink.
    static let sendSymbol = "arrow.up.circle.fill"
    static let emoteSymbol = "face.smiling"
    static let keyboardSymbol = "keyboard"
    /// Every glyph in the row has a POINT SIZE of its own: one size at every
    /// text size, as a bar's.
    static let sendConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    /// A step up, as the row's buttons draw theirs (a glass button scales
    /// its symbols to the large scale) (the owner, 2026-11-07). 20pt since
    /// 2026-11-08 (the owner: larger, in the field and in the bubble).
    static let emoteToggleConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium, scale: .large)
    /// The send arrow's colour, on every host: the brand's tint (#1124),
    /// NAMED rather than inherited. It was `.tintColor`, which resolves
    /// against the button's ancestors — and came out grey in a conversation
    /// while the post's was coloured (asked 2026-10-02: one colour for every
    /// composer).
    static let sendTint: UIColor = Palette.tint
    /// The row's quiet ink at rest: the emote faces and the attachments.
    static let restingTint: UIColor = .secondaryLabel

    /// The emote ↔ send swap, both ways: the old glyph shrinks away and the
    /// new one grows into its place, at 2.5× the system's speed — about
    /// 0.13 s end to end, filmed at 60 fps (asked 2026-10-02: at the default
    /// speed, about 0.3 s, it trailed the typing). `.offUp` was filmed too
    /// and rejected: the old glyph vanished at once but the new one took
    /// 4–7 frames to show, an EMPTY field blinking between the two faces.
    static let fieldActionTransition = UISymbolContentTransition(
        .replace.downUp, options: .speed(fieldActionTransitionSpeed)
    )
    static let fieldActionTransitionSpeed: Double = 2.5

    /// The send face, COLOUR BAKED IN (`.alwaysOriginal`), as the rest face
    /// is (`bubbleImage`): the replace swaps a grey smile for a blue arrow as
    /// one image change. With the glyphs templated, the colour rode the
    /// image view's tint — a channel of its own, applied apart from the
    /// replace — and the leaving glyph flashed blue (or the arriving one
    /// grey) in the frames between the two.
    static var sendImage: UIImage? {
        UIImage(systemName: sendSymbol, withConfiguration: sendConfiguration)?
            .withTintColor(sendTint, renderingMode: .alwaysOriginal)
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
        emoteToggle.tintColor = .secondaryLabel
        textView.translatesAutoresizingMaskIntoConstraints = false
        emoteToggle.translatesAutoresizingMaskIntoConstraints = false
        field.contentView.addSubview(textView)
        field.contentView.addSubview(emoteToggle)
        emoteToggleWidth = emoteToggle.widthAnchor.constraint(equalToConstant: Metrics.emoteToggleWidth)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: field.contentView.leadingAnchor),
            textView.topAnchor.constraint(equalTo: field.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            textView.trailingAnchor.constraint(equalTo: emoteToggle.leadingAnchor),
            // The field's end is the emote button's: the send and the voice
            // are the own bubble's, outside the field (#2308).
            emoteToggle.trailingAnchor.constraint(equalTo: field.contentView.trailingAnchor),
            emoteToggle.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            emoteToggleWidth,
            emoteToggle.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])
        // The trailing glyphs hold one size at every text size, as a bar's
        // do: the field grows with the text, but its buttons stay the 38pt
        // line's, and a glyph that scaled with the text overflowed them (the
        // emote face had no size of its own). The large
        // content viewer is the accessibility answer instead — a long press
        // at the accessibility sizes shows the glyph big.
        //
        // ⚠️ AND THE SPINNER. The send's in-flight face is the
        // configuration's activity indicator, sized by the button's text size
        // — 33×41pt at accessibility M and 63×71pt at XXXL on iOS 26.2 (CI),
        // spilling out of the 38pt cap. Capping the buttons' size category
        // holds every face, glyph or spinner, at its default size.
        emoteToggle.setPreferredSymbolConfiguration(Self.emoteToggleConfiguration, forImageIn: .normal)
        for button in [emoteToggle, rowActionButton] {
            button.maximumContentSizeCategory = .large
            button.showsLargeContentViewer = true
            button.scalesLargeContentImage = true
        }
        addInteraction(UILargeContentViewerInteraction())

        placeholderLabel.text = "Add a comment…"
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        let placeholderInset = Spacing.sm + textView.textContainer.lineFragmentPadding
        placeholderLabel.constrain(in: field.contentView) { parent in
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: parent.leadingAnchor, constant: placeholderInset)
            placeholderLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            // Short of the emote toggle: "Comment as …" runs under it otherwise.
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: emotes.toggleButton.leadingAnchor)
        }
        placeholderLeading = placeholderLabel.leadingAnchor.constraint(
            equalTo: field.contentView.leadingAnchor, constant: placeholderInset
        )
        placeholderCentre = placeholderLabel.centerXAnchor.constraint(equalTo: field.contentView.centerXAnchor)
        placeholderLeading?.isActive = true

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
        boostButton.configuration?.image = LikesSymbol.glyphImage(Self.glyphConfiguration)
        boostButton.configuration?.cornerStyle = .capsule
        boostButton.accessibilityLabel = "Boost post"
        boostButton.addAction(
            UIAction { [weak self] _ in self?.onBoost?(.likes(WalletStore.Policy.defaultStakeAmount)) },
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

        // The own bubble (#2308, every host): ONE glyph, swapped in place —
        // emote ↔ send is a symbol REPLACE on the button's own image, so the
        // bubble never blinks or moves.
        rowActionButton.configuration?.cornerStyle = .capsule
        rowActionButton.configuration?.symbolContentTransition = Self.fieldActionTransition
        rowActionButton.addAction(UIAction { [weak self] _ in self?.fieldActionTapped() }, for: .primaryActionTriggered)

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

        // The keyboard axis: the page-swipe gate, the idle-dismiss seam and
        // the ceiling through transforms (`refreshKeyboardCeiling`).
        keyboardObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    self?.setKeyboardTop(endFrame: frame)
                    self?.setKeyboardOpen(true)
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
            ) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.setKeyboardTop(endFrame: frame) }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setKeyboardTop(endFrame: nil)
                    self?.setKeyboardOpen(false)
                }
            },
        ]

        // The avatar stack, outside in: glass bubble → face (monogram with
        // the picture layered over it) → a transparent button spanning the
        // whole bubble, which owns the touches and carries the menu.
        //
        // The button is LAST and full-bleed over the bubble, so the whole
        // bubble — the glass ring included — is the tap target and owns the
        // menu.
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
        // A tap opens the app's one switcher (#2034), anchored to the face.
        avatarButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onProfileSwitch?(self.avatarButton)
        }, for: .primaryActionTriggered)
        // Nothing to open until a host wires a switcher; without this the
        // button would swallow taps.
        avatarButton.isEnabled = false
        voiceDeleteButton.pin(to: avatarBubble.contentView)
        // Under the face's button: the two never show together, and the face
        // stays the bubble's top view.
        avatarBubble.contentView.sendSubviewToBack(voiceDeleteButton)
        voiceDeleteButton.addAction(UIAction { [weak self] _ in self?.onVoiceDelete?() }, for: .primaryActionTriggered)

        addSubview(avatarBubble)
        addSubview(field)
        addSubview(railButton)
        addSubview(rowActionButton)
        rowActionButton.translatesAutoresizingMaskIntoConstraints = false
        addLayoutGuide(ownBubbleSlot)
        ownBubbleSlotTrailing = ownBubbleSlot.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.fieldTrailingInset(progress: 0)
        )
        NSLayoutConstraint.activate([
            ownBubbleSlotTrailing,
            ownBubbleSlot.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            ownBubbleSlot.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            ownBubbleSlot.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])
        rowActionTrailing = rowActionButton.trailingAnchor.constraint(equalTo: ownBubbleSlot.trailingAnchor)
        rowActionBottom = rowActionButton.bottomAnchor.constraint(equalTo: field.bottomAnchor)
        rowActionWidth = rowActionButton.widthAnchor.constraint(equalToConstant: Metrics.controlSize)
        rowActionHeight = rowActionButton.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        holdGlyph.translatesAutoresizingMaskIntoConstraints = false
        holdGlyph.isUserInteractionEnabled = false
        holdGlyph.contentMode = .center
        holdGlyph.tintColor = .white
        holdGlyph.isHidden = true
        addSubview(holdGlyph)
        NSLayoutConstraint.activate([
            holdGlyph.centerXAnchor.constraint(equalTo: rowActionButton.centerXAnchor),
            holdGlyph.centerYAnchor.constraint(equalTo: rowActionButton.centerYAnchor),
        ])
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
        boostAboveRail = boostButton.bottomAnchor.constraint(equalTo: railButton.topAnchor, constant: -SnapActionColumn.gap)
        postActions.translatesAutoresizingMaskIntoConstraints = false
        postActions.isHidden = true
        addSubview(postActions)
        fieldTrailing = field.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -(Self.fieldTrailingInset(progress: 0) + Metrics.controlSize + Spacing.sm)
        )
        let fieldAtRest = field.bottomAnchor.constraint(equalTo: restingInputRow.bottomAnchor)
        fieldAtRest.priority = .defaultHigh
        fieldAfterAvatar = field.leadingAnchor.constraint(equalTo: avatarBubble.trailingAnchor, constant: Spacing.sm)
        fieldAtLeading = field.leadingAnchor.constraint(equalTo: leadingAnchor)
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
            fieldAfterAvatar,
            fieldAtRest,
            fieldTrailing,
            rowActionTrailing,
            rowActionBottom,
            rowActionWidth,
            rowActionHeight,
            railButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            railButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            railButton.widthAnchor.constraint(equalToConstant: bubble),
            railButton.heightAnchor.constraint(equalToConstant: bubble),
            railButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            boostButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            boostAboveRail,
            postActions.trailingAnchor.constraint(equalTo: trailingAnchor),
            postActions.widthAnchor.constraint(equalToConstant: bubble),
            postActions.heightAnchor.constraint(equalToConstant: SnapPostActionsCapsule.height),
            postActions.bottomAnchor.constraint(equalTo: railButton.topAnchor, constant: -SnapActionColumn.gap),
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
        // The `:query` and `@`/`#` strips RIDE THE INPUT ROW (#960): laid out
        // in the bar, from the avatar's leading edge to the field's trailing
        // one, a fixed 8pt above the field. They floated in the window, placed once
        // per query: the keyboard lifted the field away from them, and the
        // field widened under a strip that kept its width. On the bar's own
        // layout they move in the same pass as the field — the keyboard's
        // rise, an interactive dismissal frame by frame, the widening as the
        // column is cleared (`applyRise`), a line growing the field. Each
        // joins the bar the first time it shows, in front of the bar's other
        // subviews.
        emotes.embedSuggestions(
            in: self, leading: avatarBubble.leadingAnchor,
            trailing: field.trailingAnchor, bottom: field.topAnchor
        )
        // The disc is NEVER empty. Before an identity resolves the bar shows
        // the unknown-viewer placeholder, not a blank circle — the same
        // "monogram is the rendered state" rule the comment rows follow,
        // applied to the frame before anyone has told us who you are.
        avatarView.setMonogram(Self.monogram(nil))
        applyRailFace()
        // The contract the bar starts with is a post's comments, whose field
        // records a voice comment (#2309): its hold is there from the start —
        // `configuration`'s observer only runs on a change.
        if speaksFromField { field.addGestureRecognizer(fieldVoiceHold) }
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
        // The field's voice hold (#2183): over an empty field at rest, nothing
        // on its way. Focused, the field writes (2026-11-08).
        if gestureRecognizer === fieldVoiceHold {
            // A guest records nothing (#2309): the member gate, as for a
            // typed comment — their field is the sign-up button anyway.
            return speaksFromField && onVoiceHold != nil && !hasDraft && !isSending && voiceOverlay == nil
                && (!textView.isFirstResponder || recordsReplyWhileWriting) && !MemberGates.isGuest(self)
        }
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
    ///
    /// So are the emote and completion strips riding over it (#960).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if emotes.suggestionsContain(point, in: self) { return true }
        // No input row (#2216): its band is the stream's, not the bar's.
        if takesComments, point.y >= field.frame.minY, point.y <= field.frame.maxY,
           point.x >= bounds.minX, point.x <= bounds.maxX {
            return true
        }
        guard super.point(inside: point, with: event) else { return false }
        // A reserved column is the page's, drawn above: not the bar's touch.
        guard hostsActionColumn else { return false }
        if !railButton.isHidden, railButton.frame.contains(point) { return true }
        if !postActions.isHidden, postActions.frame.contains(point) { return true }
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
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, takesComments else { return nil }
        var best: (button: UIButton, distance: CGFloat)?
        for button in [emotes.toggleButton] {
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
        postActions.isHidden = !showsPostActions || !showsStake
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
        refreshKeyboardCeiling()
        setNeedsLayout()
    }

    /// How far the host has moved the bar down with the page (#1730: the
    /// side list's overlay offset), drawn as a transform.
    private(set) var overlayOffset: CGFloat = 0

    /// The keyboard's resting top in window space, from the will-show /
    /// will-change-frame notifications; nil while it is down.
    private var keyboardTopInWindow: CGFloat?

    func setOverlayOffset(_ offset: CGFloat) {
        overlayOffset = offset
        transform = offset == 0 ? .identity : CGAffineTransform(translationX: 0, y: offset)
        refreshKeyboardCeiling()
        setNeedsLayout()
    }

    /// Re-solves the keyboard ceiling's constant for the bar's offset and
    /// its ancestors' transforms (the host calls `setOverlayOffset` at every
    /// step of the side list's pose).
    ///
    /// ⚠️ THE KEYBOARD GUIDE IGNORES TRANSFORMS — the bar's own AND the
    /// page's (measured on the SE, 2026-10-25, the owner's video): with the
    /// side list open the page is a card scaled ×0.82, yet the guide's top
    /// in the page's space read 407, the keyboard's top on SCREEN, as though
    /// nothing were scaled; the risen row was drawn 9 pt into the keyboard.
    /// Taking back only the bar's offset (42 pt) overshot to 17 pt too high.
    /// So the constant puts the field's DRAWN bottom `sm` over the keyboard's
    /// real top, through the transforms as they are drawn
    /// (`keyboardCeilingConstant`). With no offset it is `-sm`, the plain
    /// ceiling.
    private func refreshKeyboardCeiling() {
        guard let ceiling = keyboardCeiling else { return }
        var constant = -Spacing.sm - overlayOffset
        // Only while the host moves the bar (the side list's pose, whose
        // every step calls `setOverlayOffset`): elsewhere a transform is a
        // transition in flight, and a constant read off it would outlive it.
        if overlayOffset != 0, let keyboardTop = keyboardTopInWindow,
           let owner = (ceiling.secondItem as? UILayoutGuide)?.owningView {
            let origin = owner.convert(CGPoint.zero, to: nil).y
            let scale = owner.convert(CGPoint(x: 0, y: 1), to: nil).y - origin
            constant = Self.keyboardCeilingConstant(
                keyboardTop: keyboardTop, ownerDrawnOrigin: origin, ownerScale: scale,
                ownerLaidOutOrigin: Self.laidOutMinY(of: owner), barOffset: overlayOffset
            )
        }
        guard abs(ceiling.constant - constant) > 0.01 else { return }
        ceiling.constant = constant
    }

    /// The ceiling's constant that draws the field's bottom `sm` over the
    /// keyboard's top (window space): the guide reads that top as if nothing
    /// were transformed — `keyboardTop - ownerLaidOutOrigin` in the owner's
    /// space — while the owner is drawn at `ownerDrawnOrigin + ownerScale ·
    /// y`, and the bar `barOffset` lower in it. Pure, for tests.
    static func keyboardCeilingConstant(
        keyboardTop: CGFloat, ownerDrawnOrigin: CGFloat, ownerScale: CGFloat,
        ownerLaidOutOrigin: CGFloat, barOffset: CGFloat
    ) -> CGFloat {
        guard ownerScale > 0.01 else { return -Spacing.sm - barOffset }
        let guideTop = keyboardTop - ownerLaidOutOrigin
        let drawnTarget = (keyboardTop - Spacing.sm - ownerDrawnOrigin) / ownerScale
        return drawnTarget - barOffset - guideTop
    }

    /// `view`'s top in its window's space as laid out — every ancestor's
    /// frame and scroll offset, no transform.
    static func laidOutMinY(of view: UIView) -> CGFloat {
        var y: CGFloat = 0
        var current = view
        while let parent = current.superview {
            y += current.center.y - current.bounds.height * current.layer.anchorPoint.y - parent.bounds.origin.y
            current = parent
        }
        return y + current.frame.minY
    }

    /// The keyboard's resting top from a notification's end frame (screen
    /// space). Internal for tests, which raise no keyboard.
    func setKeyboardTop(endFrame: CGRect?) {
        if let endFrame, let window {
            let top = window.convert(endFrame, from: window.screen.coordinateSpace).minY
            keyboardTopInWindow = top < window.bounds.maxY ? top : nil
        } else {
            keyboardTopInWindow = nil
        }
        refreshKeyboardCeiling()
    }

    func debugSetKeyboardTop(inWindow top: CGFloat?) {
        keyboardTopInWindow = top
        refreshKeyboardCeiling()
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
    /// ceiling has already placed the field — and widens the row by it: the
    /// own bubble moves into the slot's room, the field after it.
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
        // The slot's room, as the rise leaves it: the own bubble stands
        // short of it, and the attachments and the field short of the bubble.
        let slot = Self.fieldTrailingInset(progress: progress, keepsSlot: keepsRailSlot)
        let inset = slot + ownBubbleInset + attachmentsInset
        var moved = false
        if abs(ownBubbleSlotTrailing.constant + slot) > 0.01 {
            ownBubbleSlotTrailing.constant = -slot
            moved = true
        }
        if abs(fieldTrailing.constant + inset) > 0.01 {
            fieldTrailing.constant = -inset
            moved = true
        }
        return moved
    }

    /// The input row's top — the field's top edge, which rises as it grows
    /// and with the keyboard. For a host whose chrome belongs to the input
    /// row rather than to the whole bar (the footer band, whose ramp the
    /// stake bubble floats in, and which rides the keyboard with the row).
    var inputRowTopAnchor: NSLayoutYAxisAnchor { field.topAnchor }

    /// The stake station's top — the heart, or the Text Post page's globe,
    /// floating over the input row's trailing end while the keyboard is
    /// down. For a host that stacks something above the row and must clear
    /// it too (a showcase's card, #2216). Valid while the station shows.
    var stakeStationTopAnchor: NSLayoutYAxisAnchor { boostButton.topAnchor }

    /// The view whose top is `inputRowTopAnchor`: what a toast stands on over
    /// the composer (`Feedback`'s `above:`, #729).
    var inputRowView: UIView { field }

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
            // Interactive (#730): the field answers a touch the way the
            // avatar bubble beside it does — the native stretch and lensing.
            let glass = UIGlassEffect()
            glass.isInteractive = true
            field.effect = glass
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
        // ⚠️ THE FIRST LAYOUT IS NEVER ANIMATED (the owner, 2026-11-08: the
        // emote button came in from the top-left corner). A conversation's
        // bar is laid out for the first time inside the push's animation, or
        // the keyboard's: every button and glyph then grew from a zero frame
        // at the corner. The first pass lays the whole bar out at once.
        guard hasLaidOutOnce || UIView.inheritedAnimationDuration == 0 else {
            UIView.performWithoutAnimation {
                layOutBar()
                for subview in subviews { subview.layoutIfNeeded() }
            }
            return
        }
        layOutBar()
    }

    private func layOutBar() {
        super.layoutSubviews()
        // The keyboard has placed the field by now; its width follows, in
        // this same pass (see `applyRise`).
        if applyRise() { super.layoutSubviews() }
        // The capsule's toolbar is placed: its anchor onto the own bubble.
        if alignAttachmentBar() { super.layoutSubviews() }
        // The field is placed: its height for the draft lands in this same
        // pass too (see `updateFieldHeight`).
        if updateFieldHeight() { super.layoutSubviews() }
        if bounds.width > 0 { hasLaidOutOnce = true }
    }

    private func sendTapped() {
        let text = textView.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        textView.plainText = ""
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
        get { textView.plainText }
        set {
            textView.plainText = newValue
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
            textView.plainText += text
        }
        textViewDidChange(textView)
    }

    /// Whether the field holds something to send.
    private var hasDraft: Bool {
        !textView.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The own bubble's tap: send over a draft (nothing while one is in
    /// flight); over an empty field it is the emote button — the panel or
    /// the keyboard, as the field's own emote button does. Keyboard up or
    /// down, every host.
    private func fieldActionTapped() {
        if hasDraft {
            sendTapped()
        } else if !isSending {
            emotes.toggle()
            updateFieldAction()
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
        if !open, textView.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        viewerIdentity = identity
        viewerImagePipeline = imagePipeline
        avatarView.setMonogram(Self.monogram(identity?.name))
        // The placeholder names the viewer, so a profile switch rewrites it
        // on the same beat as the face — one setter, both surfaces.
        viewerName = identity?.name
        applyPlaceholder()
        // The face over the initials; another viewer's late face lands
        // nowhere (the avatar's own rule).
        avatarView.setPicture(identity?.avatarURL, pipeline: imagePipeline)
    }

    /// What a tap on the avatar bubble opens: the profile switcher (#2034),
    /// handed the face to anchor to. Nil disables it — an account with
    /// nothing to switch to must not offer one, and a host that wires no
    /// switcher at all (the pushed comments screen) gets a plain, inert face.
    func setProfileSwitch(_ open: ((UIView) -> Void)?) {
        onProfileSwitch = open
        avatarButton.isEnabled = open != nil
    }
    private var onProfileSwitch: ((UIView) -> Void)?

    /// The composer's initials, by the app's one rule (#811): first letters
    /// of the first two words. The placeholder for an unknown viewer is the
    /// same "?" a nameless comment author gets.
    static func monogram(_ name: String?) -> String {
        MonogramAvatarView.monogram(name: name ?? "", handle: "")
    }

    /// The reply state's face: a non-nil name switches the placeholder to
    /// "Reply to NAME…"; nil restores the default prompt. Pure placeholder
    /// — the reply payload (the thread parent's id) is the HOST's state.
    func setReplyPlaceholder(name: String?) {
        replyName = name
        applyPlaceholder()
        // A comment's reply may be a voice (`recordsReplyWhileWriting`).
        updateFieldAction()
    }

    /// The armed reply target's name, and the viewer's — the two inputs the
    /// placeholder is a function of.
    private var replyName: String?
    private var viewerName: String?
    /// The viewer as last set, for a bar that mirrors this one.
    private var viewerIdentity: ViewerIdentity?
    private var viewerImagePipeline: ImagePipeline?

    /// The field's own instructions where its long press records (the
    /// owner, 2026-11-07: "maintenir pour vocal, taper pour écrire"). Only
    /// at rest: focused, the field is for writing — the host's placeholder
    /// ("Message…"), at the text's start, and no voice hold (2026-11-08).
    static let speakOrWritePlaceholder = "Hold for voice, tap to type"

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
        } else if promisesVoice, !textView.isFirstResponder {
            placeholderLabel.text = Self.speakOrWritePlaceholder
        } else if let defaultPlaceholder {
            placeholderLabel.text = defaultPlaceholder
        } else if let viewerName, !viewerName.isEmpty {
            placeholderLabel.text = "Comment as \(viewerName)"
        } else {
            placeholderLabel.text = "Add a comment…"
        }
        let centred = placeholderLabel.text == Self.speakOrWritePlaceholder
        placeholderLabel.textAlignment = centred ? .center : .natural
        if centred {
            placeholderLeading?.isActive = false
            placeholderCentre?.isActive = true
        } else {
            placeholderCentre?.isActive = false
            placeholderLeading?.isActive = true
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
        if isGuest, takesComments, signUpButton == nil { signUpButton = makeSignUpButton() }
        signUpButton?.isHidden = !isGuest || !takesComments
        avatarBubble.isHidden = isGuest || !takesComments
        field.isHidden = isGuest || !takesComments
        // The own bubble is the input row's: it goes with the field.
        rowActionButton.isHidden = field.isHidden || rowActionStepsAside
        setNeedsLayout()
        updateAttachments()
    }

    /// Whether the post takes comments (#2216): a channel's showcase takes
    /// none — the conversation is the channel (#2211) — so its page has no
    /// input row, only the column: its like and its Share. The row is hidden,
    /// not removed: the column keeps its station, the bar its height, and
    /// every host's clearance with it.
    var takesComments = true {
        didSet {
            guard takesComments != oldValue else { return }
            if !takesComments { textView.resignFirstResponder() }
            applyGuestFace()
        }
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
        guard takesComments else { return }
        textView.becomeFirstResponder()
    }

    /// The field after the avatar, or from the bar's leading edge with the
    /// avatar gone (`showsAvatar`).
    private var fieldAfterAvatar: NSLayoutConstraint!
    private var fieldAtLeading: NSLayoutConstraint!

    /// Whether the avatar leads the field. Off, it fades out and the field
    /// takes its room — the detached composer over the keys (#2087, the
    /// owner 2026-11-04). Inside an animation block, it follows it.
    var showsAvatar = true {
        didSet {
            guard showsAvatar != oldValue else { return }
            fieldAfterAvatar.isActive = showsAvatar
            fieldAtLeading.isActive = !showsAvatar
            avatarBubble.alpha = showsAvatar ? 1 : 0
            layoutIfNeeded()
        }
    }

    /// Asked as the field is about to edit, for a member: false keeps the
    /// keyboard away — a host that edits in another bar instead (#2087's
    /// detached composer, `SnapCommentsDetachedComposer`).
    var shouldBeginEditing: (() -> Bool)?

    /// Sends the draft, as a tap on send does.
    func send() {
        sendTapped()
    }

    /// Wears `other`'s look — its contract, its viewer, its prompt (a
    /// reply's included), its column — for a bar that stands in for it
    /// (`SnapCommentsDetachedComposer`). Its voice excepted: the stand-in
    /// edits text over the keys, where the field never records, and the
    /// recorder is `other`'s.
    func mirrorLook(of other: CommentsInputBar) {
        var look = other.configuration
        look.voice = .none
        configuration = look
        hostsActionColumn = other.hostsActionColumn
        showsStake = other.showsStake
        railFace = other.railFace
        usesLikeFace = other.usesLikeFace
        sendAccessibilityLabel = other.sendAccessibilityLabel
        defaultPlaceholder = other.defaultPlaceholder
        setViewerIdentity(other.viewerIdentity, imagePipeline: other.viewerImagePipeline)
        replyName = other.replyName
        applyPlaceholder()
    }

    #if DEBUG
    private var ranComposerDraftQA = false

    /// `-composer-draft <text>` (DEBUG): puts `<text>` in the draft ~2 s after
    /// the bar is SHOWN (on screen, every ancestor opaque — an engagement's
    /// bar waits offstage at alpha 0), then empties it ~6 s later: the
    /// own bubble's two faces (send over a draft, the emote over an empty
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
            let ink = self.rowActionButton.imageView?.tintColor.resolvedColor(with: self.traitCollection)
            let face = "rail=\(self.debugRailSymbol ?? "-") bubble=\(self.ownBubbleSymbol ?? "-")"
                + " label=\(self.rowActionButton.accessibilityLabel ?? "-")"
                + " ink=\(ink.map { String(describing: $0) } ?? "-")"
                + " dimmed=\(self.rowActionButton.tintAdjustmentMode == .dimmed)"
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
            // `-composer-draft-keep`: the draft stays, to be looked at.
            guard !arguments.contains("-composer-draft-keep") else { return }
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
            rect(boostButton), rect(self), ownBubbleSymbol ?? "-", debugRailSymbol ?? "-"
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

    /// The post's live like count, the viewer's stake already in it
    /// (`WalletStakeLikes`, #896) — the bar draws it as given, as the rail's
    /// chrome does. Nil when the author hides it (#397). Read only by the
    /// like face.
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
            let count = boostPostLikeCount
            let shows = showsStake && visibilityMenu == nil
            if let base = boostButton.configuration {
                boostButton.configuration = SnapActionColumn.likeConfiguration(
                    base, staked: total > 0, count: shows ? count : nil, ink: .label
                )
            }
            boostButton.accessibilityLabel = "Like"
            boostButton.accessibilityValue = SnapRailBoostButton.accessibilityValue(
                likeCount: boostPostLikeCount,
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
            title.foregroundColor = LikesSymbol.tint
            boostButton.configuration?.attributedTitle = title
            boostButton.configuration?.image = nil
            // `.glass()`'s default content insets leave a 38pt circle ~10pt
            // of text width, so "100" WRAPPED into a vertical digit stack
            // (measured in-sim). The number face zeroes them — the rail
            // anchor's recipe, whose circle never wrapped.
            boostButton.configuration?.contentInsets = .zero
        } else {
            boostButton.configuration?.attributedTitle = nil
            boostButton.configuration?.image = LikesSymbol.glyphImage(Self.glyphConfiguration)
        }
        boostButton.accessibilityValue = total > 0 ? "\(total) likes staked" : nil
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
                shotAmount: WalletStore.Policy.StakePack.likesPerShot
            ),
            stake: { [weak self] amount in self?.onBoost?(.likes(amount)) },
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
        label.textColor = LikesSymbol.tint
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

    /// The own bubble's two faces (#2308, every host):
    ///   has text (or a send in flight) → ↑ send
    ///   empty                          → ☺ the emote button (⌨ while the panel is up)
    /// The keyboard plays no part: a draft is sendable with the keyboard
    /// down — a shared link or an emote lands in the field precisely to be
    /// sent. The field itself holds no button any more: the comments' inline
    /// waveform (a voice that didn't work) and send are gone.
    ///
    /// ONE configuration write per change, applied on the spot. Each
    /// `configuration?.x = …` is a write of its own, and the image and the
    /// colour used to land as two; the face also waited for the next layout
    /// pass, which a line break runs INSIDE the field's growth spring
    /// (`updateFieldHeight`), stretching the swap to the spring's length.
    private func updateFieldAction() {
        let sends = hasDraft || isSending
        ownBubbleSymbol = sends ? Self.sendSymbol : (emotes.isShowingPanel ? Self.keyboardSymbol : Self.emoteSymbol)
        // Not while a finger holds it (`applyVoiceHoldFace`).
        if !voiceHolding, !voiceHoldReturning, !rowActionStepsAside, var bubble = rowActionButton.configuration {
            bubble.image = bubbleImage(sends: sends)
            // The spinner's ink (the glyphs carry their own).
            bubble.baseForegroundColor = sends ? Self.sendTint : Self.restingTint
            bubble.showsActivityIndicator = isSending
            if bubble != rowActionButton.configuration {
                rowActionButton.configuration = bubble
                // Applied on the spot, outside the growth spring a line
                // break runs next — never on the first pass (from the corner).
                if hasLaidOutOnce { rowActionButton.layoutIfNeeded() }
            }
        }
        rowActionButton.accessibilityLabel = sends
            ? sendAccessibilityLabel ?? "Send comment"
            : (emotes.isShowingPanel ? "Keyboard" : "Emotes")
        rowActionButton.isEnabled = !isSending
        updateEmoteToggle()
        updateAttachments()
    }

    /// The field's emote button: gone while a take covers the field, and
    /// until there is a draft — the own bubble is the emote button then
    /// (every host, #2308).
    ///
    /// It comes and goes in sight (the owner, 2026-11-08): a scale with a
    /// bounce and a fade, about its own centre. At once under a take or with
    /// Reduce Motion.
    private func updateEmoteToggle() {
        guard emoteToggleWidth != nil else { return }
        let hidden = voiceOverlay != nil || !hasDraft
        let width = hidden && voiceOverlay == nil ? 0 : Metrics.emoteToggleWidth
        let button = emotes.toggleButton
        let changes = emoteToggleShown != !hidden
        let animates = changes && voiceOverlay == nil && window != nil && !MotionPreference.reducesMotion
        emoteToggleShown = !hidden
        if animates {
            animateEmoteToggle(shown: !hidden, width: width)
        } else if !changes {
            // The same state again — the next letter of a draft: a way in or
            // out still running runs to its end (the owner, 2026-11-09: typed
            // fast, the bounce was cut at the second letter). Only the slot's
            // width follows a take leaving the field, never mid-way out.
            if !emoteToggleLeaving, emoteSlotAnimator == nil, emoteToggleWidth.constant != width {
                emoteToggleWidth.constant = width
                UIView.performWithoutAnimation { field.contentView.layoutIfNeeded() }
            }
        } else {
            stopEmoteSlotAnimator()
            emoteToggleLeaving = false
            button.layer.removeAllAnimations()
            button.isHidden = hidden
            button.alpha = 1
            button.transform = .identity
            if emoteToggleWidth.constant != width {
                emoteToggleWidth.constant = width
                // Laid out now: a later pass inside another animation (the
                // keyboard's, a push) would slide it from where it was.
                UIView.performWithoutAnimation { field.contentView.layoutIfNeeded() }
            }
        }
        textView.accessibilityCustomActions = promisesVoice && !hasDraft
            && (!textView.isFirstResponder || recordsReplyWhileWriting) && !MemberGates.isGuest(self)
            ? [UIAccessibilityCustomAction(name: configuration.voice.recordActionName) { [weak self] _ in
                self?.onVoiceHold?(.accessibilityStart)
                return true
            }]
            : nil
    }

    /// The field's emote button in or out (the owner, 2026-11-08: a scale or
    /// a bounce, and a fade — nothing that swings). Its slot never moves
    /// under it: in, the slot opens at once and the button bounces up from a
    /// fifth of its size where it stands; out, it shrinks and fades where it
    /// stands, and only then does the slot close for the text. A slot that
    /// widened with it swung the glyph from the field's edge.
    private func animateEmoteToggle(shown: Bool, width: CGFloat) {
        let button = emotes.toggleButton
        let small = CGAffineTransform(scaleX: 0.2, y: 0.2)
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        #if DEBUG
        debugEmoteToggleMotions += 1
        #endif
        if shown {
            stopEmoteSlotAnimator()
            emoteToggleLeaving = false
            UIView.performWithoutAnimation {
                emoteToggleWidth.constant = width
                field.contentView.layoutIfNeeded()
                // Its glyph too, where it stands: never laid out while it was
                // hidden at no width, it came in from the corner.
                button.layoutIfNeeded()
            }
            if button.isHidden || button.alpha == 0 {
                button.isHidden = false
                button.alpha = 0
                button.transform = small
            }
            UIView.animate(withDuration: 0.15, delay: 0, options: options) { button.alpha = 1 }
            UIView.animate(springDuration: 0.45, bounce: 0.5, options: options) { button.transform = .identity }
            return
        }
        emoteToggleLeaving = true
        UIView.animate(withDuration: 0.18, delay: 0, options: options) {
            button.alpha = 0
            button.transform = small
        } completion: { [weak self] _ in
            guard let self, !self.emoteToggleShown else { return }
            emoteToggleLeaving = false
            button.isHidden = true
            button.alpha = 1
            button.transform = .identity
            emoteToggleWidth.constant = width
            let closing = UIViewPropertyAnimator(duration: 0.25, dampingRatio: 1) {
                self.field.contentView.layoutIfNeeded()
            }
            closing.addCompletion { [weak self, weak closing] _ in
                if self?.emoteSlotAnimator === closing { self?.emoteSlotAnimator = nil }
            }
            emoteSlotAnimator = closing
            closing.startAnimation()
        }
    }

    /// The slot's closing, stopped where it stands: its frames go with it.
    private func stopEmoteSlotAnimator() {
        guard let closing = emoteSlotAnimator else { return }
        emoteSlotAnimator = nil
        if closing.state == .active { closing.stopAnimation(true) }
    }

    /// The own bubble's glyph: the send over a draft; at rest the emote
    /// button's — its smile, or the keyboard while the panel is up.
    private func bubbleImage(sends: Bool) -> UIImage? {
        Self.ownBubbleImage(sends: sends, panelUp: emotes.isShowingPanel)
    }

    /// The own bubble's face, COLOUR BAKED IN: the send in the brand's tint,
    /// the emote faces in the row's quiet ink. Pure, for tests.
    static func ownBubbleImage(sends: Bool, panelUp: Bool) -> UIImage? {
        guard !sends else { return sendImage }
        return UIImage(
            systemName: panelUp ? keyboardSymbol : emoteSymbol, withConfiguration: emoteToggleConfiguration
        )?.withTintColor(restingTint, renderingMode: .alwaysOriginal)
    }

    /// The symbol the own bubble wears at rest or over a draft.
    private var ownBubbleSymbol: String?

    /// The rail button's face: the host's action, never anything the draft
    /// says. Hidden on a draft post (`.empty`), whose slot holds no bubble.
    private func applyRailFace() {
        let symbol: String?
        switch railFace {
        case .empty, .noSlot:
            symbol = nil
            railButton.accessibilityLabel = nil
        case .repost:
            symbol = PostActionSymbol.repost
            railButton.accessibilityLabel = "Repost"
        case .pin(let isPinned):
            symbol = isPinned ? "pin.fill" : "pin"
            railButton.accessibilityLabel = isPinned ? "Unpin conversation" : "Pin conversation"
        case .returnTo(let down):
            symbol = down ? "chevron.down" : "chevron.up"
            railButton.accessibilityLabel = down ? "Scroll to latest message" : "Back to top"
        case .share:
            symbol = Self.shareRailSymbol
            railButton.accessibilityLabel = "Share"
        case .sound(let face):
            // The cover as a disc, the bubble's size less the sound bubble's
            // inset, so the two read as one (#671). Not a symbol: no replace.
            railButton.isHidden = false
            if railGlassConfiguration == nil {
                railGlassConfiguration = railButton.configuration
                var clear = UIButton.Configuration.plain()
                clear.contentInsets = .zero
                clear.background.backgroundColor = .clear
                railButton.configuration = clear
            }
            if railRecord.isHidden || railFaceSymbol != Self.soundRailSymbol || railCoverSlot.image == nil {
                face.draw(into: railCoverSlot)
            }
            railRecord.isHidden = false
            railButton.accessibilityLabel = "Sound"
            railButton.alpha = face.isAvailable ? 1 : 0.45
            railFaceSymbol = Self.soundRailSymbol
            railButton.isEnabled = isRailFaceEnabled && face.isAvailable
            applyReservedColumn()
            return
        }
        railButton.alpha = 1
        railButton.isHidden = symbol == nil
        // Share answers to the toolbar's identifier, which the page no longer
        // shows (#1999); every other face, none.
        railButton.accessibilityIdentifier = railFace == .share ? SnapFooterToolbar.ID.share : nil
        railRecord.isHidden = true
        railRecord.setSpinning(false)
        if let glass = railGlassConfiguration {
            // Back to the button's own glass; its glyph is drawn afresh.
            railButton.configuration = glass
            railGlassConfiguration = nil
            railFaceSymbol = nil
        }
        if let symbol, railFaceSymbol != symbol {
            railButton.configuration?.image = UIImage.symbol(named: symbol, configuration: Self.glyphConfiguration)
        }
        railFaceSymbol = symbol
        // The way back always answers, even on a draft with nothing to pin
        // (#1929); the hold is what a draft refuses.
        if case .returnTo = railFace {
            railButton.isEnabled = true
            applyReservedColumn()
            return
        }
        railButton.isEnabled = isRailFaceEnabled
        applyReservedColumn()
    }

    /// Redraws the rail face as it stands.
    func redrawRailFace() {
        railFaceSymbol = nil
        railCoverSlot.reset()
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
        railRecord.isHidden = true
        railRecord.translatesAutoresizingMaskIntoConstraints = false
        railButton.addSubview(railRecord)
        NSLayoutConstraint.activate([
            railRecord.centerXAnchor.constraint(equalTo: railButton.centerXAnchor),
            railRecord.centerYAnchor.constraint(equalTo: railButton.centerYAnchor),
            railRecord.widthAnchor.constraint(equalTo: railButton.widthAnchor),
            railRecord.heightAnchor.constraint(equalTo: railButton.heightAnchor),
        ])
        // The button's highlight presses the record with its glass.
        railButton.configurationUpdateHandler = { [weak self] button in
            self?.railRecord.setPressed(button.isHighlighted && !(self?.railRecord.isHidden ?? true))
        }
    }

    /// The share face's glyph: the toolbar's Share (`SnapFooterToolbar`).
    static let shareRailSymbol = "arrowshape.turn.up.right"

    /// What `debugRailSymbol` reads while the slot wears the sound's cover.
    static let soundRailSymbol = "sound.cover"

    /// The symbol the rail button wears, so an unchanged face is not
    /// re-applied (a re-applied image would replay the replace).
    private var railFaceSymbol: String?

    #if DEBUG
    /// The rail button, for the specs that read its face and tap it.
    var debugRailButton: UIButton { railButton }
    /// The sound face's cover and whether it is turning now (#692).
    var debugRailCover: SoundRecordGlass { railRecord }
    var debugRailIsSpinning: Bool { railRecord.isSpinning }
    /// The symbol the rail button wears.
    var debugRailSymbol: String? { railButton.isHidden ? nil : railFaceSymbol }
    /// The symbol the own bubble wears at rest or over a draft: the send,
    /// the emote button's smile, or the keyboard (#2308).
    var debugOwnBubbleSymbol: String? { ownBubbleSymbol }
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
    /// width is the field's less the emote button's slot, known as soon as
    /// the field is placed. Returns whether the height moved without an
    /// animation, for `layoutSubviews` to apply it in the same pass.
    @discardableResult
    private func updateFieldHeight(animated: Bool = false) -> Bool {
        let textWidth = field.bounds.width - Metrics.emoteToggleWidth
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

/// The field's voice hold asks the bar whether it may begin (#2102).
extension CommentsInputBar: UIGestureRecognizerDelegate {}

extension CommentsInputBar: UITextViewDelegate {
    /// A guest cannot write: the field opens the sign-up sheet instead of the
    /// keyboard, and takes focus after they sign up — the comment they were
    /// about to write. Every entry into editing passes here (a tap, a reply
    /// row, the emote panel), so this one check covers them all.
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        guard let gate = MemberGates.gate(from: self), !gate.isMember else {
            return shouldBeginEditing?() ?? true
        }
        Task { @MainActor [weak self] in
            guard await gate.requireMember(for: .comment) else { return }
            self?.textView.becomeFirstResponder()
        }
        return false
    }

    /// Focused, a conversation's field writes: its placeholder and its
    /// voice action follow (2026-11-08).
    func textViewDidBeginEditing(_ textView: UITextView) {
        applyPlaceholder()
        updateFieldAction()
    }

    /// The emote panel goes with the keyboard: the bubble's glyph follows,
    /// once the panel has left (after this turn). The field speaks again.
    func textViewDidEndEditing(_ textView: UITextView) {
        applyPlaceholder()
        // An empty field let go: the attachments come back now (#2305).
        updateAttachments()
        DispatchQueue.main.async { [weak self] in self?.updateFieldAction() }
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = textView.hasText
        updateFieldAction()
        updateFieldHeight(animated: true)
        onTextChange?(self.textView.plainText)
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
