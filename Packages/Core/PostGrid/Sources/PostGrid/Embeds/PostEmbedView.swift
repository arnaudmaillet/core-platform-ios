import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A text post's embed card (#2216): ONE view, a case per embed type —
/// Telegram-iOS's `ChatMessageWebpageBubbleContentNode`, which draws every
/// link preview and picks the action by the entity's type. Only `.channel`
/// exists today; a group, a place or a quoted post is one more case here.
///
/// **The channel case**, at the size the host's room allows
/// (`PostEmbeds.Size`):
/// - **full:** photo, name, description (two lines), subscriber count, the
///   last message's first line when the backend gives it, and the action;
/// - **compact:** photo, name, count, the action;
/// - **mark:** the photo with a channel glyph, the name — not interactive.
///
/// **The action follows the viewer's state** (`ChannelEmbed.action`): Join,
/// Request to Join, Requested (a tap offers the cancel, through a
/// confirmation menu), Open; none for a banned viewer. A deleted, private or
/// blocked channel has its own drawing and no action.
///
/// **Taps:** the action button takes its own; the rest of the card leaves
/// the surface's alone (open the post, the hold's preview) — a host's tap
/// recognizer asks `keepsTouch(_:)`. A mark takes no touch at all.
///
/// **Writes** go through `channelActions`, the seam Chat implements and the
/// app registers once (`ChannelEmbedActing`): Feed, Maps and PostGrid can't
/// depend on Chat. The answer shows at once, and is remembered for the
/// session (`ChannelEmbedLocalState`) so a card drawn again from a read made
/// before the tap shows the new state too.
///
/// ⚠️ Lives in PostGrid, not VoiceKitUI as #2216 asks: see `PostEmbeds`.
@MainActor
public final class PostEmbedView: UIView {
    /// What the channel card's button does — Chat's, registered by the app
    /// (`AppContainer`). Nil (a test, a preview, the channels off): the
    /// button shows, and a tap does nothing.
    public static var channelActions: (any ChannelEmbedActing)?

    /// Where `channelActions` comes from when nothing set it yet: the app
    /// registers this at launch, and it is asked on the first tap — so the
    /// card acts on a launch that never opened Messages, without building
    /// Chat before anyone taps (#2216).
    public static var makeChannelActions: (@MainActor () -> (any ChannelEmbedActing)?)?

    /// The actions a tap uses: the ones set, or the ones made now. Public
    /// for a profile's Channels rows (#2232), which act as the card does —
    /// through the same instance, so Chats reloads the same catalog.
    public static var resolvedChannelActions: (any ChannelEmbedActing)? {
        if let channelActions { return channelActions }
        channelActions = makeChannelActions?()
        return channelActions
    }

    /// The embed shown, as last drawn (a tap's answer included); nil while
    /// nothing is.
    public private(set) var embed: PostEmbed?
    public private(set) var size: PostEmbeds.Size?
    /// Told when a tap changed the embed (Join → Open…), for a host that
    /// keeps its model in step.
    public var onEmbedChange: ((PostEmbed) -> Void)?

    // MARK: - Parts

    private let stack = UIStackView()
    private let header = UIStackView()
    private let titles = UIStackView()
    private let nameRow = UIStackView()
    private let photoHolder = UIView()
    private let photo = AvatarView(diameter: Metrics.photo(.full), size: .avatar)
    private var photoWidth: NSLayoutConstraint?
    /// The channel's glyph on the mark's photo.
    private let badge = UIImageView()
    /// The channel's glyph before the name, on the larger sizes.
    private let glyph = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let lastMessageLabel = UILabel()
    private let actionButton = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Join"))
    private let unavailableRow = UIStackView()
    private let unavailableIcon = UIImageView()
    private let unavailableLabel = UILabel()
    /// The write in flight, for a test that awaits it.
    private(set) var pendingAction: Task<Void, Never>?
    /// Which write `pendingAction` is: an answer for an earlier one is
    /// remembered (`ChannelEmbedLocalState`) and drawn by no one here.
    private var actionGeneration = 0
    private var pipeline: ImagePipeline?

    enum Metrics {
        static func photo(_ size: PostEmbeds.Size) -> CGFloat {
            switch size {
            case .full: 44
            case .compact: 36
            case .mark: 24
            }
        }

        static let cornerRadius: CGFloat = 16
        static let badgeSide: CGFloat = 12
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        isHidden = true
        // Another card's answer (#2216, part 2): the same channel drawn
        // elsewhere on screen — the post's tile beside its bubble, a card
        // and its lift — shows it at once, not on its next redraw.
        NotificationCenter.default.addObserver(
            self, selector: #selector(otherCardChanged(_:)), name: Self.channelStateDidChange, object: nil
        )
    }

    public convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Showing

    /// Shows `embed` at `size`. A view shown again (a reused cell) forgets the
    /// last one first: a write still in flight for it answers to no one.
    public func show(_ embed: PostEmbed, size: PostEmbeds.Size, pipeline: ImagePipeline?) {
        if self.embed?.channel?.conversationID != embed.channel?.conversationID { forgetPendingAction() }
        self.pipeline = pipeline
        switch embed {
        case .channel(let channel): present(ChannelEmbedLocalState.applied(to: channel), size: size)
        }
    }

    /// Draws `channel` as given — this session's taps already applied.
    private func present(_ channel: ChannelEmbed, size: PostEmbeds.Size) {
        isHidden = false
        embed = .channel(channel)
        self.size = size
        showChannel(channel, size: size)
    }

    /// A write in flight answers to no one any more: the card shows another
    /// channel, or nothing.
    private func forgetPendingAction() {
        pendingAction?.cancel()
        pendingAction = nil
        actionGeneration += 1
    }

    /// Shows nothing — a cell reused for a post with no embed.
    public func clear() {
        forgetPendingAction()
        embed = nil
        size = nil
        isHidden = true
        photo.setPicture(nil, pipeline: nil)
    }

    /// Whether `touch` is the card's own — its action button — so a host's
    /// tap recognizer leaves it alone and the rest of the card keeps the
    /// surface's action (#2216).
    public static func keepsTouch(_ touch: UITouch) -> Bool {
        ownsTouch(in: touch.view)
    }

    /// The same for a point already hit-tested — a host that decides from a
    /// location, not a touch (a context menu's configuration, a view's
    /// `hitTest`): whether `view`, what the point landed on, is a card's
    /// action button.
    public static func keepsTouch(on view: UIView?) -> Bool {
        ownsTouch(in: view)
    }

    /// Whether a touch landing on `view` is a card's own: on its action
    /// button, inside a card.
    static func ownsTouch(in view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is AppButton, candidate.superview(of: PostEmbedView.self) != nil { return true }
            if candidate is PostEmbedView { return false }
            current = candidate.superview
        }
        return false
    }

    // MARK: - The channel case

    private func showChannel(_ channel: ChannelEmbed, size: PostEmbeds.Size) {
        let available = channel.availability == .available
        applyGround(size)
        // A mark is the tile's: it takes no touch, so the tile's tap and
        // hold reach it whatever is drawn.
        isUserInteractionEnabled = size != .mark

        photoHolder.isHidden = !available
        unavailableRow.isHidden = available
        header.isHidden = !available
        if !available {
            showUnavailable(channel.availability, size: size)
            hideChannelParts()
            accessibilityLabel = ChannelEmbedCopy.accessibilityLabel(channel)
            return
        }

        let side = Metrics.photo(size)
        photo.setDiameter(side)
        photoWidth?.constant = side
        photo.setMonogram(MonogramAvatarView.monogram(name: channel.displayName, handle: ""))
        photo.setPicture(channel.photoURL, pipeline: pipeline)
        badge.isHidden = size != .mark

        nameLabel.text = channel.displayName
        let nameStyle: UIFont.TextStyle = switch size {
        case .full: .headline
        case .compact: .subheadline
        case .mark: .footnote
        }
        nameLabel.font = UIFont.scaledFont(forTextStyle: nameStyle, weight: .semibold)
        glyph.isHidden = size == .mark
        countLabel.text = ChannelEmbedCopy.subscriberCount(channel.subscriberCount)
        let countStyle: UIFont.TextStyle = size == .full ? .footnote : .caption1
        countLabel.font = UIFont.appFont(forTextStyle: countStyle)
        countLabel.isHidden = size == .mark

        let description = channel.description.trimmingCharacters(in: .whitespacesAndNewlines)
        descriptionLabel.text = description
        descriptionLabel.isHidden = size != .full || description.isEmpty
        lastMessageLabel.text = channel.lastMessagePreview
        lastMessageLabel.isHidden = size != .full || channel.lastMessagePreview == nil

        placeButton(for: size)
        applyAction(channel.action, size: size)
        header.spacing = size == .mark ? Spacing.xs + 2 : Spacing.md
        accessibilityLabel = ChannelEmbedCopy.accessibilityLabel(channel)
    }

    private func hideChannelParts() {
        descriptionLabel.isHidden = true
        lastMessageLabel.isHidden = true
        actionButton.isHidden = true
        photo.setPicture(nil, pipeline: nil)
    }

    private func showUnavailable(_ availability: ChannelEmbed.Availability, size: PostEmbeds.Size) {
        unavailableIcon.image = UIImage(systemName: ChannelEmbedCopy.unavailableSymbol(availability))
        unavailableIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: size == .mark ? 11 : 15, weight: .semibold
        )
        unavailableLabel.text = size == .mark
            ? ChannelEmbedCopy.unavailableMark(availability)
            : ChannelEmbedCopy.unavailable(availability)
        let unavailableStyle: UIFont.TextStyle = size == .mark ? .caption1 : .subheadline
        unavailableLabel.font = UIFont.appFont(forTextStyle: unavailableStyle)
        unavailableRow.spacing = size == .mark ? Spacing.xs : Spacing.sm
    }

    /// The card's ground: a fill on the larger sizes, none on a mark, which
    /// sits on its tile's face.
    private func applyGround(_ size: PostEmbeds.Size) {
        let filled = size != .mark
        backgroundColor = filled ? .tertiarySystemFill : .clear
        layer.cornerRadius = filled ? Metrics.cornerRadius : 0
        let inset = filled ? Spacing.md : 0
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        stack.spacing = size == .full ? Spacing.sm : Spacing.xs
    }

    /// The button stands at the card's foot, full width (full), or at the
    /// header's end (compact); a mark has none.
    private func placeButton(for size: PostEmbeds.Size) {
        actionButton.removeFromSuperview()
        switch size {
        case .full: stack.addArrangedSubview(actionButton)
        case .compact: header.addArrangedSubview(actionButton)
        case .mark: break
        }
    }

    private func applyAction(_ action: ChannelEmbed.Action?, size: PostEmbeds.Size) {
        guard let action, size != .mark else {
            actionButton.isHidden = true
            actionButton.menu = nil
            return
        }
        actionButton.isHidden = false
        actionButton.setPhase(.content, animated: false)
        // Join and Request stand on the prominent ground; Requested and Open
        // on the quiet one (Follow → Following).
        let quiet = action == .requested || action == .open
        actionButton.setContent(.title(ChannelEmbedCopy.title(for: action)), selected: quiet, animated: window != nil)
        actionButton.haptic = quiet ? nil : .toggleOn
        actionButton.accessibilityHint = action == .requested ? ChannelEmbedCopy.cancelRequestMessage : nil
        // Requested: the tap opens the cancel's confirmation, not a write.
        if action == .requested {
            actionButton.menu = cancelMenu()
            actionButton.showsMenuAsPrimaryAction = true
        } else {
            actionButton.menu = nil
            actionButton.showsMenuAsPrimaryAction = false
        }
    }

    /// The confirmation a tap on Requested opens.
    func cancelMenu() -> UIMenu {
        let cancel = UIAction(title: ChannelEmbedCopy.cancelRequestTitle, attributes: .destructive) { [weak self] _ in
            self?.cancelRequest()
        }
        return UIMenu(title: ChannelEmbedCopy.cancelRequestMessage, children: [cancel])
    }

    // MARK: - Actions

    @objc private func actionTapped() {
        performAction()
    }

    /// What a tap on the button does for the action shown (Requested's is
    /// its menu's: `cancelRequest`).
    func performAction() {
        guard case .channel(let channel)? = embed, let action = channel.action else { return }
        switch action {
        case .open:
            Self.resolvedChannelActions?.open(channel.conversationID)
        case .join:
            run(on: channel) { actions, id in try await actions.join(id) }
        case .requestToJoin:
            run(on: channel) { actions, id in try await actions.requestToJoin(id) }
        case .requested:
            break
        }
    }

    /// The confirmed cancel of a waiting request.
    func cancelRequest() {
        guard case .channel(let channel)? = embed, channel.action == .requested else { return }
        run(on: channel) { actions, id in try await actions.cancelJoinRequest(id) }
    }

    private typealias Write = @MainActor (any ChannelEmbedActing, ConversationID) async throws -> ChannelEmbed.ViewerState

    /// One write: the button loads, the answer shows; a refusal shakes the
    /// button and leaves the card as it was.
    private func run(on channel: ChannelEmbed, _ write: @escaping Write) {
        guard let actions = Self.resolvedChannelActions, pendingAction == nil else { return }
        actionButton.setPhase(.loading, animated: window != nil)
        let id = channel.conversationID
        actionGeneration += 1
        let generation = actionGeneration
        pendingAction = Task { [weak self] in
            do {
                let state = try await write(actions, id)
                // Remembered whoever draws it: a recycled card included.
                ChannelEmbedLocalState.record(id, from: channel.viewerState, to: state)
                self?.finish(channel, with: state, generation: generation)
            } catch {
                self?.failed(generation: generation)
            }
        }
    }

    private func finish(_ channel: ChannelEmbed, with state: ChannelEmbed.ViewerState, generation: Int) {
        // Every card on screen showing this channel follows, this one's
        // host included through `onEmbedChange` below.
        NotificationCenter.default.post(
            name: Self.channelStateDidChange, object: self,
            userInfo: [Self.conversationKey: channel.conversationID, Self.stateKey: state]
        )
        // Reused for another channel meanwhile: the answer is remembered,
        // and drawn by whichever card shows it next.
        guard generation == actionGeneration, let size else { return }
        pendingAction = nil
        let changed = channel.with(viewerState: state)
        present(changed, size: size)
        onEmbedChange?(.channel(changed))
    }

    // MARK: - The same channel elsewhere on screen (#2216, part 2)

    /// Posted by the card whose tap changed a channel's standing; every
    /// other card showing that channel draws the answer.
    ///
    /// `ChannelEmbedLocalState` covers a card drawn AFTER the tap (a
    /// recycled cell, the page the tile opens); this covers one already on
    /// screen — a map pin's mark under its bubble, a list card under its
    /// lift. Deliberately not through `ChannelEmbedLocalState.applied`,
    /// which forgets a change when it meets a read that already shows it.
    public static let channelStateDidChange = Notification.Name("PostEmbedView.channelStateDidChange")
    private static let conversationKey = "conversationID"
    private static let stateKey = "viewerState"

    /// A channel's standing changed somewhere other than a card — a
    /// profile's Channels row (#2232): remembered for the session
    /// (`ChannelEmbedLocalState`) and drawn at once by every card on screen
    /// showing that channel, as a card's own tap is.
    public static func announceChannelStanding(
        _ id: ConversationID, from: ChannelEmbed.ViewerState, to: ChannelEmbed.ViewerState
    ) {
        ChannelEmbedLocalState.record(id, from: from, to: to)
        NotificationCenter.default.post(
            name: channelStateDidChange, object: nil,
            userInfo: [conversationKey: id, stateKey: to]
        )
    }

    /// The channel and its new standing a `channelStateDidChange` carries —
    /// for a surface that draws channels without a card (a profile's
    /// Channels rows, #2232). Nil for a note that says neither.
    public static func channelStanding(in note: Notification) -> (id: ConversationID, state: ChannelEmbed.ViewerState)? {
        guard let id = note.userInfo?[conversationKey] as? ConversationID,
              let state = note.userInfo?[stateKey] as? ChannelEmbed.ViewerState else { return nil }
        return (id, state)
    }

    @objc private func otherCardChanged(_ note: Notification) {
        guard note.object as? PostEmbedView !== self,
              let id = note.userInfo?[Self.conversationKey] as? ConversationID,
              let state = note.userInfo?[Self.stateKey] as? ChannelEmbed.ViewerState,
              case .channel(let channel)? = embed, channel.conversationID == id,
              channel.viewerState != state, let size else { return }
        // Its own write in flight answers to no one now: the standing moved.
        forgetPendingAction()
        let changed = channel.with(viewerState: state)
        present(changed, size: size)
        onEmbedChange?(.channel(changed))
    }

    private func failed(generation: Int) {
        guard generation == actionGeneration else { return }
        pendingAction = nil
        actionButton.setPhase(.content, animated: window != nil)
        actionButton.fail()
    }

    // MARK: - Build

    private func build() {
        layer.cornerCurve = .continuous
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup

        stack.axis = .vertical
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // The photo, and the mark's glyph on its corner.
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.isUserInteractionEnabled = false
        photoHolder.addSubview(photo)
        badge.image = UIImage(systemName: ChannelEmbedCopy.channelSymbol)
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        badge.tintColor = Palette.onPrimary
        badge.backgroundColor = Palette.prominentFill
        badge.contentMode = .center
        badge.layer.cornerRadius = Metrics.badgeSide / 2
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        photoHolder.addSubview(badge)
        let width = photoHolder.widthAnchor.constraint(equalToConstant: Metrics.photo(.full))
        photoWidth = width
        NSLayoutConstraint.activate([
            width,
            photoHolder.heightAnchor.constraint(equalTo: photoHolder.widthAnchor),
            photo.leadingAnchor.constraint(equalTo: photoHolder.leadingAnchor),
            photo.topAnchor.constraint(equalTo: photoHolder.topAnchor),
            photo.trailingAnchor.constraint(equalTo: photoHolder.trailingAnchor),
            photo.bottomAnchor.constraint(equalTo: photoHolder.bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: Metrics.badgeSide),
            badge.heightAnchor.constraint(equalToConstant: Metrics.badgeSide),
            badge.trailingAnchor.constraint(equalTo: photoHolder.trailingAnchor, constant: 3),
            badge.bottomAnchor.constraint(equalTo: photoHolder.bottomAnchor, constant: 3),
        ])

        glyph.image = UIImage(systemName: ChannelEmbedCopy.channelSymbol)
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        glyph.tintColor = Palette.tint
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs
        nameRow.addArrangedSubview(glyph)
        nameRow.addArrangedSubview(nameLabel)

        countLabel.textColor = .secondaryLabel
        titles.axis = .vertical
        titles.spacing = 2
        titles.addArrangedSubview(nameRow)
        titles.addArrangedSubview(countLabel)
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Spacing.md
        header.addArrangedSubview(photoHolder)
        header.addArrangedSubview(titles)

        descriptionLabel.font = .appFont(forTextStyle: .subheadline)
        descriptionLabel.textColor = .label
        descriptionLabel.numberOfLines = 2
        lastMessageLabel.font = .appFont(forTextStyle: .footnote)
        lastMessageLabel.textColor = .secondaryLabel
        lastMessageLabel.numberOfLines = 1

        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .primaryActionTriggered)

        unavailableIcon.tintColor = .secondaryLabel
        unavailableIcon.setContentHuggingPriority(.required, for: .horizontal)
        unavailableLabel.textColor = .secondaryLabel
        unavailableLabel.numberOfLines = 2
        unavailableRow.axis = .horizontal
        unavailableRow.alignment = .center
        unavailableRow.addArrangedSubview(unavailableIcon)
        unavailableRow.addArrangedSubview(unavailableLabel)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(descriptionLabel)
        stack.addArrangedSubview(lastMessageLabel)
        stack.addArrangedSubview(unavailableRow)
        stack.addArrangedSubview(actionButton)

        // VoiceOver: the card reads as one element — "Channel Harbour notes,
        // 10 subscribers" — and its button as another.
        header.isAccessibilityElement = true
        unavailableRow.isAccessibilityElement = true
    }

    public override var accessibilityLabel: String? {
        didSet {
            header.accessibilityLabel = accessibilityLabel
            unavailableRow.accessibilityLabel = accessibilityLabel
        }
    }
}

private extension UIView {
    /// The nearest ancestor of `type`.
    func superview<T: UIView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

#if DEBUG
/// What a test reads of the card — public, for the surfaces' own tests.
extension PostEmbedView {
    public var debugActionTitle: String? { actionButton.isHidden ? nil : actionButton.content.title }
    public var debugActionIsQuiet: Bool { actionButton.isSelected }
    public var debugActionOpensMenu: Bool { actionButton.showsMenuAsPrimaryAction && actionButton.menu != nil }
    public var debugUnavailableText: String? { unavailableRow.isHidden ? nil : unavailableLabel.text }
    public var debugNameText: String? { header.isHidden ? nil : nameLabel.text }
    public var debugCountText: String? { countLabel.isHidden || header.isHidden ? nil : countLabel.text }
    public var debugDescriptionText: String? { descriptionLabel.isHidden ? nil : descriptionLabel.text }
    public var debugLastMessageText: String? { lastMessageLabel.isHidden ? nil : lastMessageLabel.text }
    public var debugShowsBadge: Bool { !badge.isHidden && !photoHolder.isHidden }
    public var debugCardLabel: String? { header.isHidden ? unavailableRow.accessibilityLabel : header.accessibilityLabel }
    public var debugActionButton: UIView { actionButton }
    /// Awaits the write a tap started.
    public func debugSettle() async { await pendingAction?.value }
    /// A tap on the action button, as `primaryActionTriggered` makes it —
    /// for a surface's own tests (#2216, part 2).
    public func debugTapAction() { performAction() }
}
#endif

/// What this session's taps changed on channels (#2216), remembered so a
/// card drawn again from a read made BEFORE the tap shows the answer — a
/// recycled cell, the page the tile opens.
///
/// Each entry is the standing the tap moved FROM and TO: it applies to a
/// read that still says FROM (stale), and is dropped by one that says
/// anything else — the server has moved on (a leave in Messages, an admin's
/// approval), and is believed.
@MainActor
public enum ChannelEmbedLocalState {
    private static var changes: [ConversationID: (from: ChannelEmbed.ViewerState, to: ChannelEmbed.ViewerState)] = [:]

    static func record(_ id: ConversationID, from: ChannelEmbed.ViewerState, to: ChannelEmbed.ViewerState) {
        // A change undone (a cancel after a request) leaves the first FROM:
        // a read from before both is still stale.
        let origin = changes[id]?.from ?? from
        changes[id] = origin == to ? nil : (origin, to)
    }

    /// `channel` as this session knows it.
    public static func applied(to channel: ChannelEmbed) -> ChannelEmbed {
        guard let change = changes[channel.conversationID] else { return channel }
        if channel.viewerState == change.from { return channel.with(viewerState: change.to) }
        changes[channel.conversationID] = nil
        return channel
    }

    /// Forgets everything — a viewer change, a test.
    public static func reset() { changes = [:] }
}
