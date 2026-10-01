import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The author identity (avatar + name/meta) hosted as the navigation bar's
/// *trailing* bar item custom view (right-aligned, mirroring system floating
/// actions). The bar never hides or transforms it during a hero flight — the
/// card flies beneath the real, static bar.
///
/// TWO WIDTH MODES.
/// - FIXED (`setFixedWidth`, the snap feed): one width, read off the bar's
///   geometry (`SnapBarPillWidths`), whoever the author — the name and the
///   handle truncate inside it, the follow glyph keeps the pill's trailing
///   end. Asked 2026-09-30: a pill that hugged its text grew and shrank on
///   every page.
/// - HUGGING (every other host — a conversation's header, a published text
///   post): the view sizes itself to its content under a width cap
///   (`setWidthBudget`), and a content change re-negotiates the item's size
///   through the blur (`BarItemRemeasure`).
final class SnapAuthorIdentityView: UIView {
    /// What the pill's trailing glyph says about the viewer and the author.
    ///
    /// Only `.follow` is an ACTION (the "+"). The other two are STATE, drawn so
    /// following someone does not simply make the pill forget it — and so a
    /// friend (a mutual follow) reads apart from a one-way follow. A state
    /// glyph takes no tap of its own: it falls through to the pill, which
    /// opens the author's profile, where unfollowing lives.
    enum FollowBadge: Equatable, Sendable {
        /// Nothing drawn: the viewer themself, someone blocked, a relation not
        /// known yet, or a host that offers no follow at all.
        case none
        /// "+": the viewer does not follow them. A tap follows.
        case follow
        /// The viewer follows them; they do not follow back.
        case following
        /// Both follow each other.
        case friends

        /// The symbols, chosen from what iOS 26 ships:
        /// - `plus` — the action, as before.
        /// - `person.fill.checkmark` — a person, confirmed: the most literal
        ///   "you follow them" in the catalogue (the `.badge.checkmark`
        ///   variants read as a verified avatar, and their badge is too small
        ///   to read at this size).
        /// - `person.2.fill` — two people: the app already means "Friends" by
        ///   it (the map's Friends filter), and it is the one symbol that says
        ///   the relation goes BOTH ways.
        var symbolName: String? {
            switch self {
            case .none: nil
            case .follow: "plus"
            case .following: "person.fill.checkmark"
            case .friends: "person.2.fill"
            }
        }

        /// The person symbols are wider than the "+" at the same point size;
        /// a step smaller keeps them to the "+"'s optical weight in the pill.
        var pointSize: CGFloat { self == .follow ? 15 : 13 }

        var accessibilityLabel: String? {
            switch self {
            case .none: nil
            case .follow: "Follow"
            case .following: "Following"
            case .friends: "Friends"
            }
        }
    }

    /// Matches the bar's standard control height.
    private static let height: CGFloat = 40
    /// The fixed height of the bar's own item wrapper on iOS 26 — the box the
    /// avatar centers in (see the breathing math at the row constraints).
    private static let barItemWrapperHeight: CGFloat = 36
    /// Long display names truncate here rather than crowding the back item.
    private static let maxWidth: CGFloat = 220
    /// The unhydrated (cold-tap) floor: the pill opens at a plausible
    /// footprint instead of a nub, so hydration is a small glide, not a pop.
    private static let minWidth: CGFloat = 150

    /// Narrows the pill without changing what it IS.
    ///
    /// The budget is real — the system overflows the whole item into a `•••`
    /// menu the moment the trailing run does not fit (measured: the author's
    /// view chain dead-ended at its item wrapper, never reaching the window),
    /// and losing the author entirely is worse than any amount of truncation.
    /// A COMPACT form once paid for it by dropping the handle line and the
    /// follow button, which made the pill a visibly different component in
    /// the two states. This pays for it in WIDTH instead: same two lines, same
    /// follow button, same platter — the name simply truncates earlier.
    ///
    /// The floor comes off below `minWidth`: it exists to hold the pill open
    /// while a name hydrates, and it would otherwise out-argue the budget.
    /// HUGGING mode only: a fixed width ignores it.
    func setWidthBudget(_ budget: CGFloat?) {
        let target = min(Self.maxWidth, budget ?? Self.maxWidth)
        guard target > 0, maxWidthConstraint?.constant != target else { return }
        maxWidthConstraint?.constant = target
        minWidthConstraint?.isActive = fixedWidth == nil && target >= Self.minWidth
    }

    /// The pill's width in FIXED mode; nil while it hugs its content.
    private(set) var fixedWidth: CGFloat?
    private var fixedWidthConstraint: NSLayoutConstraint?

    /// Pins the pill to `width` — or, with nil, lets it hug its content again.
    /// Returns whether anything changed.
    ///
    /// The bar reads a custom view's size when the item is handed over, so a
    /// host sets this BEFORE installing the item; the frame is written too
    /// while the pill has no bar (a custom view keeps
    /// `translatesAutoresizingMaskIntoConstraints`, and the size UIKit reads
    /// at hand-over is its frame). A change on an installed pill asks the bar
    /// for a pass — the host changes it only with the bar's own geometry.
    ///
    /// 999, never required: the bar pins its item wrapper with autoresizing
    /// constraints, and anything required loses to them with a console break.
    /// 999 still outranks everything inside — the labels truncate (the name
    /// first, `nameLabel`'s resistance), the redaction bars give way.
    @discardableResult
    func setFixedWidth(_ width: CGFloat?) -> Bool {
        guard width != fixedWidth else { return false }
        fixedWidth = width
        if let width {
            if let fixedWidthConstraint {
                fixedWidthConstraint.constant = width
            } else {
                let constraint = widthAnchor.constraint(equalToConstant: width)
                constraint.priority = UILayoutPriority(999)
                fixedWidthConstraint = constraint
            }
            fixedWidthConstraint?.isActive = true
        } else {
            fixedWidthConstraint?.isActive = false
        }
        // A fixed width answers for itself: no cap, no floor.
        maxWidthConstraint?.isActive = width == nil
        minWidthConstraint?.isActive = width == nil && (maxWidthConstraint?.constant ?? 0) >= Self.minWidth
        if superview == nil {
            frame.size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        } else {
            BarItemRemeasure.run(self, duration: nil)
        }
        return true
    }

    /// Called when the identity is tapped, with the shown author.
    var onAuthorTapped: ((ProfileID) -> Void)?
    /// Called when the "+" is tapped, with the shown author. Never for a
    /// state glyph (`FollowBadge`): those take no tap of their own.
    var onFollowTapped: ((ProfileID) -> Void)?

    /// The author's INITIALS, always drawn — the app's avatar contract:
    /// initials first, the picture hydrates in front of them. It used to be a
    /// grey disc for anyone without a picture, the one place in the app a
    /// person was faceless.
    private let monogramView = MonogramAvatarView(diameter: AvatarImageView.barDiameter)
    private let avatarView = AvatarImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let followButton = UIButton(configuration: .plain())
    /// Redacted stand-ins shown where the labels will be until the first
    /// author hydrates (cold tap) — the system placeholder idiom, resolved
    /// through the same cross-fade that swaps authors.
    private let namePlaceholder = SnapAuthorIdentityView.makeRedactionBar(width: 96, height: 12)
    private let metaPlaceholder = SnapAuthorIdentityView.makeRedactionBar(width: 64, height: 9)
    private let labelsStack = UIStackView()
    /// Everything the pill draws, edge-pinned: the one view a content change
    /// fades (`contentTransition`) — a CONTAINER, because a platter flattens a
    /// label's own partial alpha to opaque.
    private let contentView = UIView()
    /// Blurs one author out and the next in, inside the one bar item
    /// (`BarItemContentTransition`).
    private lazy var contentTransition: BarItemContentTransition = {
        let transition = BarItemContentTransition(host: self, content: contentView)
        // A FIXED pill never re-measures: its width is the bar's, not the
        // author's. Only a hugging one has a new width to take.
        transition.remeasure = { [weak self] duration in
            guard let self, self.fixedWidth == nil else { return }
            BarItemRemeasure.run(self, duration: duration)
        }
        transition.didSettle = { [weak self] in self?.onContentSettled?() }
        return transition
    }()
    /// Once a content change has fully landed.
    var onContentSettled: (() -> Void)?

    /// Blurs the pill by `amount` (0…1) as the SCROLL says — the feed's paging
    /// drives it (`BarPillScrub`), and an author set meanwhile lands under
    /// the blur (`BarItemContentTransition.setScrubBlur`).
    func setScrubBlur(_ amount: CGFloat) { contentTransition.setScrubBlur(amount) }

    /// Renders the blurred still a scroll may need, before the page moves.
    func prepareScrub() { contentTransition.prepareScrub() }

    /// Whose face the avatar task is loading — compared on arrival so a fast
    /// page-past cannot land a picture on the wrong pill.
    private var authorID: ProfileID?
    /// What is actually on screen, so a repeat call can tell "same page again"
    /// from "same page, better data".
    private var renderedModel: FeedItemDisplayModel?
    private var avatarTask: Task<Void, Never>?
    /// The hugging width bounds, held so `setWidthBudget` and `setFixedWidth`
    /// can retune them.
    private var maxWidthConstraint: NSLayoutConstraint?
    private var minWidthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)

        // Size and circle geometry come from the shared component: the same
        // diameter as the Maps toolbar's profile avatar, and a radius bound
        // to the bounds each layout pass — a perfect circle by construction.
        // Clear: with no picture (yet) the initials behind show through.
        avatarView.backgroundColor = .clear
        avatarView.pin(to: monogramView)

        nameLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        nameLabel.textColor = .label
        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = .secondaryLabel
        // THE ORDER THE PILL GIVES WAY IN, when the bar is too narrow to
        // hold everything: the display NAME truncates first, the handle
        // line only once the name has nothing left to give. A name is the
        // thing a reader can still recognize half-written ("Rosa Igle…");
        // a half-written handle is not an identifier at all. Resistance,
        // not two width rules — Auto Layout squeezes the lower one first
        // and never has to be told about the second.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // The bar is transparent over arbitrary media; shadows keep the
        // identity legible without a background.
        for label in [nameLabel, metaLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        applyFollowBadge()
        // ONE SLOT for the three glyphs: "+", the followed mark and the friends
        // mark differ in width, and a pill whose width is fixed would
        // otherwise re-truncate its labels whenever the relation changed.
        let badgeSlot = followButton.widthAnchor.constraint(equalToConstant: Self.followBadgeSlotWidth)
        badgeSlot.priority = UILayoutPriority(999)
        badgeSlot.isActive = true
        followButton.addAction(UIAction { [weak self] _ in
            guard let self, self.followBadge == .follow, let id = self.authorID else { return }
            self.onFollowTapped?(id)
        }, for: .primaryActionTriggered)

        for view in [nameLabel, namePlaceholder, metaLabel, metaPlaceholder] {
            labelsStack.addArrangedSubview(view)
        }
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        setRedacted(true)

        let row = UIStackView(arrangedSubviews: [monogramView, labelsStack, followButton])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        // The row is edge-pinned, so any width the pill has beyond (or short
        // of) natural content must be absorbed by exactly one member — and at
        // UIKit's defaults the button and the labels stack TIE (hugging
        // 250/250, compression 750/750), letting the solver deform an
        // arbitrary one per pass: the "+" visibly dances during early bar
        // passes and the hydration glide. Make the button rigid, and make the
        // labels area the designated absorber — its content is leading-aligned,
        // so a stretched frame just gains invisible trailing space.
        // Rigid at its SLOT (the 999 width above), so its hugging sits just
        // under it: a required hugging would pin a narrow glyph to its own
        // width and break the slot.
        followButton.setContentHuggingPriority(UILayoutPriority(998), for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        // Interaction stays on: the follow button consumes its own taps (a
        // control descendant defeats the container's gesture), while taps on
        // the avatar/labels fall through to the container's author tap.
        // The avatar's leading inset matches its vertical breathing exactly:
        // the bar's item wrapper renders 36pt tall and the avatar is
        // vertically centered, so the same computed gap on the left keeps it
        // uniform on all three sides whatever the shared diameter is. A
        // slightly larger trailing inset gives the follow glyph room against
        // the pill's rounded end. The bar self-sizes custom views through
        // Auto Layout; the height pin and width cap are the only external
        // metrics.
        let avatarBreathing = (Self.barItemWrapperHeight - AvatarImageView.barDiameter) / 2
        contentView.pin(to: self)
        row.constrain(in: contentView) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: avatarBreathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.sm)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, not required: the bar wraps items in its own fixed-height
        // container (36pt on iOS 26) via autoresizing constraints; a required
        // height fights it and UIKit breaks ours at runtime with a console
        // warning. Yield to the wrapper — the content row centers regardless.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        let maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth)
        maxWidth.isActive = true
        maxWidthConstraint = maxWidth
        // The floor only binds while content is narrower than it (the redacted
        // cold state); real name+meta content exceeds it, keeping the flush
        // pill. 999 so it can never fight the bar's own constraints.
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)
        minWidth.priority = UILayoutPriority(999)
        minWidth.isActive = true
        minWidthConstraint = minWidth

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `model`'s author, IN PLACE: the pill is one view in one bar item
    /// for the screen's life, and a change of what it draws blurs the old
    /// content out and the new in (`BarItemContentTransition`) while the
    /// item's glass stays where it is — at its fixed width in the feed, so
    /// the glass does not so much as change size.
    ///
    /// The meta line is the author's HANDLE alone (`pillMetaLine`): the post's
    /// age is not the pill's to say (asked 2026-10-01) — so paging between
    /// posts by the same author changes nothing on it at all.
    ///
    /// The pill's STATE (`shownAuthor`, the tap target) is the new author at
    /// once; only the drawing waits for the transition's midpoint.
    /// `animated: false`, or a pill not in a window, swaps in one frame.
    func setAuthor(_ model: FeedItemDisplayModel, pipeline: ImagePipeline, animated: Bool = true) {
        guard model != renderedModel else { return }
        // The fast path is for PAGING between posts by one person: the face and
        // the name are already right, and there is no reason to refetch an
        // avatar. Only a handle the projection lacked can still move.
        let sameFace = showsSameFace(as: model)
        let meta = Self.pillMetaLine(fromMeta: model.metaText)
        renderedModel = model
        authorID = model.authorID
        guard !sameFace else {
            guard metaLabel.text != meta else { return }
            contentTransition.perform(animated: animated) { self.metaLabel.text = meta }
            return
        }
        let cached = model.avatarURL.flatMap(SnapAuthorFaceCache.face(for:))
        contentTransition.perform(animated: animated) {
            self.setRedacted(false)
            self.nameLabel.text = model.authorName
            self.metaLabel.text = meta
            self.showFace(cached, animated: false)
            self.monogramView.setMonogram(MonogramAvatarView.monogram(
                name: model.authorName, handle: Self.handle(fromMeta: model.metaText)
            ))
        }

        avatarTask?.cancel()
        avatarTask = nil
        // A face already in hand is drawn above, in the same pass as the name:
        // nothing to fetch, and nothing to fade in after the pill appears.
        guard cached == nil, let url = model.avatarURL else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-pill-no-face") { return }
        #endif
        let id = model.authorID
        avatarTask = Task { [weak self] in
            guard let fetched = try? await pipeline.image(for: url) else { return }
            let image = await SnapAuthorFaceCache.prepared(fetched)
            SnapAuthorFaceCache.store(image, for: url)
            guard let self, self.authorID == id else { return }
            // Onto the NEW author's content: mid-blur, the old one is still
            // what the live views draw.
            self.contentTransition.afterSwap { [weak self] in
                guard let self, self.authorID == id else { return }
                self.showFace(image)
            }
        }
    }

    /// Whether `model` would draw the same face and name this pill draws now —
    /// so at most its handle line differs.
    ///
    /// ⚠️ It has to check what is DRAWN, not just who it belongs to. A page
    /// is configured twice from one id — the grid's projection, then the real
    /// entry — and those can carry the same author with a better name and an
    /// avatar the projection had no URL for. Keyed on `authorID` alone, the
    /// second call took the fast path and the capsule kept a blank face.
    func showsSameFace(as model: FeedItemDisplayModel) -> Bool {
        model.authorID == authorID
            && model.authorName == renderedModel?.authorName
            && model.avatarURL == renderedModel?.avatarURL
    }

    /// The author on the pill, if one has been set with `setAuthor`.
    var shownAuthor: FeedItemDisplayModel? { renderedModel }

    /// Fetches `url`'s face into the pill's cache ahead of need — the next
    /// page's author — so the pill's swap to them is drawn with it.
    static func warmFace(_ url: URL, pipeline: ImagePipeline) {
        guard SnapAuthorFaceCache.face(for: url) == nil else { return }
        Task { @MainActor in
            guard let image = try? await pipeline.image(for: url) else { return }
            SnapAuthorFaceCache.store(await SnapAuthorFaceCache.prepared(image), for: url)
        }
    }

    /// Shows a person who is not a post's author — a conversation's
    /// correspondent. The same pill and the same cross-
    /// fade as `setAuthor`; the meta line says whatever the host passes, and
    /// an empty one simply leaves the name alone on the pill.
    func setPerson(id: ProfileID?, name: String, meta: String, avatarURL: URL?, pipeline: ImagePipeline) {
        let faceChanged = id != authorID || avatarURL != personAvatarURL
        guard faceChanged || name != nameLabel.text || meta != metaLabel.text else { return }
        renderedModel = nil
        authorID = id
        personAvatarURL = avatarURL
        defer { BarItemRemeasure.run(self, duration: 0.22) }

        UIView.transition(with: self, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.setRedacted(false)
            self.nameLabel.text = name
            self.metaLabel.text = meta
            if faceChanged { self.showFace(nil) }
            self.monogramView.setMonogram(MonogramAvatarView.monogram(
                name: name, handle: Self.handle(fromMeta: meta)
            ))
        }

        guard faceChanged else { return }
        avatarTask?.cancel()
        guard let url = avatarURL else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.personAvatarURL == url else { return }
            self.showFace(image)
        }
    }

    /// Puts a picture on the disc, or takes it off.
    ///
    /// With a picture the avatar is the picture ALONE: the initials plate is
    /// covered once the picture has faded in (not before, or the disc would
    /// be empty for the fade). Without one, the initials show on their round
    /// plate.
    private func showFace(_ image: UIImage?, animated: Bool = true) {
        guard let image else {
            avatarView.image = nil
            monogramView.isCovered = false
            return
        }
        guard animated else {
            avatarView.image = image
            monogramView.isCovered = true
            return
        }
        UIView.transition(with: avatarView, duration: 0.15, options: [.transitionCrossDissolve]) {
            self.avatarView.image = image
        } completion: { _ in
            self.monogramView.isCovered = self.avatarView.image != nil
        }
    }

    /// What the pill's second line says for a post's meta ("@handle · 3m"):
    /// the "@handle" alone — never the age, which is the post's, not the
    /// author's. Empty when the meta carries no handle.
    static func pillMetaLine(fromMeta meta: String) -> String {
        let handle = handle(fromMeta: meta)
        return handle.isEmpty ? "" : "@" + handle
    }

    /// "@handle" off a meta line ("@handle · 3m"); empty when it carries none.
    private static func handle(fromMeta meta: String) -> String {
        let first = meta.components(separatedBy: " · ").first ?? ""
        return first.hasPrefix("@") ? String(first.dropFirst()) : ""
    }

    /// The face `setPerson` last asked for — the arrival guard for its fetch.
    private var personAvatarURL: URL?

    /// What the trailing glyph says. A conversation draws none from its header
    /// (the correspondent's profile is one tap away, and that is where
    /// following lives); the snap feed draws the viewer's relation to the
    /// author, and none for the viewer themself or while it does not know.
    ///
    /// `animated`: the glyph changes through the author's own blur (the "+"
    /// turning into the followed mark after a tap), and a badge set in the
    /// same turn as a new author lands in the SAME swap.
    func setFollowBadge(_ badge: FollowBadge, animated: Bool = false) {
        guard badge != followBadge else { return }
        followBadge = badge
        contentTransition.perform(animated: animated) { self.applyFollowBadge() }
    }

    /// Whether the "+" is on offer.
    var offersFollow: Bool { followBadge == .follow }

    /// The widest of the badge glyphs at their own point sizes — the one slot
    /// every badge is drawn in.
    ///
    /// Measured off BUTTONS wearing each glyph, not off the symbol images: a
    /// button draws a symbol wider than the image's own `size` says (the
    /// friends mark measured 26.7 in its button against a 22pt "slot" read
    /// off the images, and grew past it).
    static let followBadgeSlotWidth: CGFloat = {
        [FollowBadge.follow, .following, .friends].map { badge in
            UIButton(configuration: badgeConfiguration(badge))
                .systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }.max().map { ceil($0) } ?? 24
    }()

    /// The glyph `badge` draws, as its button's configuration.
    private static func badgeConfiguration(_ badge: FollowBadge) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.image = badge.symbolName.flatMap { UIImage(systemName: $0) }?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: badge.pointSize, weight: .semibold))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        return config
    }

    /// The pill's own default is the "+", as it always was: a host that offers
    /// no follow says so (`setFollowBadge(.none)`).
    private(set) var followBadge: FollowBadge = .follow

    /// Draws `followBadge`, in place. The glyph is a plain button: only the
    /// "+" takes touches — a state glyph lets them through to the pill's own
    /// tap (the author's profile), which is the natural reading of tapping
    /// someone's "friends" mark and keeps unfollowing where it already lives.
    private func applyFollowBadge() {
        followButton.configuration = Self.badgeConfiguration(followBadge)
        followButton.accessibilityLabel = followBadge.accessibilityLabel
        followButton.isUserInteractionEnabled = followBadge == .follow
        followButton.accessibilityTraits = followBadge == .follow ? .button : .staticText
        followButton.isHidden = followBadge == .none
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    /// The SHADOW only — the colours are semantic and resolve from the
    /// bar's theme (`SnapChromeTheme`, applied to the navigation bar).
    ///
    /// The shadow is not a theme question: it exists because this pill
    /// floats over an arbitrary photo with no background of its own, and a
    /// text page's own ground makes it unnecessary. Keeping it here — while
    /// the colour comes from the theme — is what stopped the pill from
    /// having a second, private opinion about light and dark.
    func setOverMedia(_ overMedia: Bool) {
        for label in [nameLabel, metaLabel] {
            label.layer.shadowOpacity = overMedia ? 0.5 : 0
        }
    }

    /// Swaps the label area between redacted stand-ins and the real labels.
    /// The stand-in bars need a gap of their own; label line-heights carry it
    /// once hydrated.
    private func setRedacted(_ redacted: Bool) {
        isRedacted = redacted
        applyLabelVisibility()
    }

    private var isRedacted = true

    /// The label area's visibility: the real labels once hydrated, the
    /// redaction bars before.
    private func applyLabelVisibility() {
        nameLabel.isHidden = isRedacted
        namePlaceholder.isHidden = !isRedacted
        metaLabel.isHidden = isRedacted
        metaPlaceholder.isHidden = !isRedacted
        labelsStack.spacing = isRedacted ? 5 : 0
    }

    private static func makeRedactionBar(width: CGFloat, height: CGFloat) -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        bar.layer.cornerRadius = height / 2
        bar.layer.cornerCurve = .continuous
        // Below a fixed pill's 999: a narrow pill shortens the bar rather than
        // being widened by it. Still above a fitting pass's own level, so a
        // hugging pill keeps the bar's length.
        let length = bar.widthAnchor.constraint(equalToConstant: width)
        length.priority = .defaultHigh
        length.isActive = true
        bar.heightAnchor.constraint(equalToConstant: height).isActive = true
        return bar
    }
}

/// The snap feed's navigation-bar controls, built as *custom views* so their
/// on-screen frames are readable with public API (a system-styled
/// `UIBarButtonItem` exposes no view), and so the hero flight's stand-ins can
/// be second instances of the exact same controls — pixel-identical at the
/// landing swap by construction.
enum SnapNavControls {
    /// The back chevron for a presented (map-opened) feed; dismisses to the map.
    static func makeBackButton() -> UIButton {
        makeCircularBarButton(systemName: "chevron.backward", pointSize: 17)
    }

    /// A NAVIGATION-bar action that stands in the back button's slot (the
    /// comments ✕). The back button's 17pt metric, not the toolbar's 15,
    /// because it sits in the same slot and swaps with it — two glyphs at
    /// different weights trading places would read as a size change.
    static func makeNavActionButton(systemName: String) -> UIButton {
        makeCircularBarButton(systemName: systemName, pointSize: 17)
    }

    /// A bottom-toolbar action (share, more): the same 36pt circle as the
    /// back button, hosted as a bar item custom view so the system glass
    /// wraps each action in its own isolated bubble — custom views never
    /// join a shared item background.
    static func makeToolbarActionButton(systemName: String) -> UIButton {
        makeCircularBarButton(systemName: systemName, pointSize: 15)
    }

    /// One symbol in a strict 1:1 box: symbol intrinsic sizes are asymmetric
    /// and the system glass pill wraps the custom view's bounds, which
    /// renders slightly oval without this. Both metrics are 999, never
    /// required: the bar's FIRST pass pins its item wrapper to the raw
    /// intrinsic size with autoresizing constraints, and anything required
    /// loses to that with a console break. 36 matches the wrapper's real
    /// item height, so the settled pill is an exact circle (a 40pt box
    /// would settle 40×36 — subtly oval).
    private static func makeCircularBarButton(systemName: String, pointSize: CGFloat) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        let height = button.heightAnchor.constraint(equalToConstant: 36)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        let aspect = button.widthAnchor.constraint(equalTo: button.heightAnchor)
        aspect.priority = UILayoutPriority(999)
        aspect.isActive = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
        return button
    }
}

/// The faces the author pill has drawn lately, readable SYNCHRONOUSLY.
///
/// A swap made on this turn must draw the new author already wearing the
/// right face — otherwise they blur in with their initials and pop to the
/// picture once the blur has landed. The pipeline's cache answers
/// synchronously too, but with the full-size picture; this one holds the
/// pill's own small, already-decoded bitmap (`prepared(_:)`), which is what
/// keeps the swap's still from paying a decode on a frame of the scroll.
@MainActor
enum SnapAuthorFaceCache {
    /// A few pages either way is all paging ever asks for.
    static let capacity = 24
    private static var faces: [URL: UIImage] = [:]
    /// Least recently stored first.
    private static var order: [URL] = []

    static func face(for url: URL) -> UIImage? { faces[url] }

    /// `image` as the pill draws it: a small, already-DECODED square bitmap,
    /// made off the main thread.
    ///
    /// ⚠️ Because the pill is also drawn by `CALayer.render` — the blurred
    /// stills of `BarItemContentTransition` — and that CPU path decodes and
    /// scales a full-size picture itself, on the main thread, on a frame of
    /// the scroll: the first still of each new face cost 22–40ms on the
    /// iPhone 18 Pro simulator (`-pill-probe`), the same pill 3–7ms once the
    /// face had been drawn.
    static func prepared(_ image: UIImage) async -> UIImage {
        let side = AvatarImageView.barDiameter
        return await Task.detached(priority: .userInitiated) {
            let size = image.size
            guard size.width > 0, size.height > 0 else { return image }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = false
            // Aspect FILL into the disc's square, as the avatar view draws it.
            let fill = max(side / size.width, side / size.height)
            let drawn = CGSize(width: size.width * fill, height: size.height * fill)
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
            }
        }.value
    }

    static func store(_ image: UIImage, for url: URL) {
        if faces.updateValue(image, forKey: url) != nil {
            order.removeAll { $0 == url }
        }
        order.append(url)
        while order.count > capacity {
            faces[order.removeFirst()] = nil
        }
    }

    static func removeAll() {
        faces.removeAll()
        order.removeAll()
    }
}

#if DEBUG
extension SnapAuthorIdentityView {
    /// `-pill-probe`: what the pill's disc actually is at this instant — its
    /// frame in the window, its corner and mask, every transformed ancestor up
    /// to the bar, and any OTHER view in the window drawing the same initials.
    func debugProbe(_ tag: String) {
        guard let window else { print("[pill-probe] \(tag) pill=\(ObjectIdentifier(self)) NO WINDOW"); return }
        let disc = monogramView
        let frame = disc.convert(disc.bounds, to: window)
        let presentation = disc.layer.presentation()
        let maskPath = (disc.layer.mask as? CAShapeLayer)?.path?.boundingBox
        let pres = presentation.map {
            String(format: "%.1fx%.1f r=%.1f", $0.bounds.width, $0.bounds.height, $0.cornerRadius)
        } ?? "nil"
        let mask = maskPath.map { String(format: "%.1fx%.1f", $0.width, $0.height) } ?? "NONE"
        var line = String(format: "[pill-probe] %@ pill=%.1fx%.1f disc@win=(%.1f,%.1f %.1fx%.1f) r=%.1f",
                          tag, bounds.width, bounds.height, frame.minX, frame.minY, frame.width, frame.height,
                          disc.layer.cornerRadius)
        line += " pres=\(pres) mask=\(mask) curve=\(disc.layer.cornerCurve.rawValue)"
            + " clips=\(disc.layer.masksToBounds) bg=\(disc.layer.backgroundColor.map { String(format: "%.2f", $0.alpha) } ?? "nil")"
            + " sublayers=\((disc.layer.sublayers ?? []).map { "\(type(of: $0))" })"
        var chain: [String] = []
        var view: UIView? = self
        while let current = view, !(current is UIWindow) {
            let t = current.layer.presentation()?.transform ?? current.layer.transform
            var entry = "\(type(of: current))[\(Int(current.bounds.width))x\(Int(current.bounds.height))"
            if !CATransform3DIsIdentity(t) { entry += String(format: " s=%.3f", t.m11) }
            if current.alpha < 1 { entry += String(format: " a=%.2f", current.alpha) }
            if current.layer.cornerRadius > 0 { entry += String(format: " r=%.1f", current.layer.cornerRadius) }
            if current.layer.mask != nil { entry += " MASK" }
            chain.append(entry + "]")
            if current is UINavigationBar { break }
            view = current.superview
        }
        line += " chain=" + chain.joined(separator: " < ")
        // Copies: any other label in the window reading the same initials,
        // and any portal/snapshot in the bar band.
        let initials = disc.debugMonogramText
        var copies: [String] = []
        func scan(_ root: UIView) {
            for sub in root.subviews {
                if let label = sub as? UILabel, label.text == initials, label.superview !== disc {
                    let f = label.convert(label.bounds, to: window)
                    copies.append(String(format: "label(%.1f,%.1f %.1fx%.1f)", f.minX, f.minY, f.width, f.height))
                }
                let name = String(describing: type(of: sub))
                // Anything painting a background over the disc: the plate's
                // square has to be drawn by SOMETHING.
                let over = sub.convert(sub.bounds, to: window)
                if sub !== disc, over.intersects(frame.insetBy(dx: 4, dy: 4)), over.width < 80,
                   let bg = sub.layer.backgroundColor, bg.alpha > 0 {
                    copies.append(String(format: "BG %@(%.1f,%.1f %.1fx%.1f r=%.1f %@%@)", name, over.minX, over.minY,
                                         over.width, over.height, sub.layer.cornerRadius,
                                         sub.layer.cornerCurve.rawValue, sub.layer.mask == nil ? "" : " MASK"))
                }
                if name.contains("Portal") || name.contains("Snapshot") || name.contains("Replica") {
                    let f = sub.convert(sub.bounds, to: window)
                    if f.minY < 140 {
                        copies.append(String(format: "%@(%.1f,%.1f %.1fx%.1f)", name, f.minX, f.minY, f.width, f.height))
                    }
                }
                scan(sub)
            }
        }
        scan(window)
        line += " copies=\(copies)"
        print(line)
    }
}
#endif
