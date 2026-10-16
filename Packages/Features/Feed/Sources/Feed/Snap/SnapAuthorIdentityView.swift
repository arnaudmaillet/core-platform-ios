import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The author identity (avatar + name/meta) hosted as the navigation bar's
/// *trailing* bar item custom view (right-aligned, mirroring system floating
/// actions). The bar never hides or transforms it during a hero flight — the
/// card flies beneath the real, static bar.
///
/// ITS WIDTH IS ITS CONTENT'S (#925): the pill hugs the face and the two
/// lines, under a cap — the room its bar leaves it (`setWidthBudget`) — and a
/// new person re-negotiates the item's size through the blur
/// (`BarItemRemeasure`). It used to be FIXED in the snap feed (asked
/// 2026-09-30, so the glass did not change size from page to page); the owner
/// asked for the intrinsic width on 2026-10-11, once the follow glyph had
/// left the trailing end.
///
/// THE RELATION IS A BADGE ON THE AVATAR (#925), not a glyph at the pill's
/// trailing end: a small mark over the face's bottom-right corner, so a
/// relation that loads or changes never touches the pill's width, and every
/// change of it is an SF Symbols replace — never the pill's blur.
final class SnapAuthorIdentityView: UIView {
    /// What the avatar's badge says about the viewer and the person.
    ///
    /// Only `.follow` is an ACTION (the "+"). The others are STATE, drawn so
    /// following someone does not simply make the pill forget it — and so a
    /// friend (a mutual follow) reads apart from a one-way follow, and a
    /// request a private account has not answered reads apart from both. A
    /// state mark takes no tap of its own: it falls through to the pill,
    /// which opens the person's profile, where unfollowing and withdrawing a
    /// request live.
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
        /// The viewer asked a private account to follow them, and the request
        /// is pending (#968).
        case pending

        /// The symbols the owner chose (#925):
        /// - `plus` — the action;
        /// - `checkmark.circle.fill` — the viewer follows them;
        /// - `person.2.fill` — two people: the app already means "Friends" by
        ///   it (the map's Friends filter), and it is the one symbol that says
        ///   the relation goes BOTH ways;
        /// - `clock.circle.fill` — waiting on the other person (#968). Not
        ///   `clock.fill`: that symbol is ONE layer, a white disc with its
        ///   hands cut out, so on the badge it can only be a white disc with
        ///   black hands. `clock.circle.fill` is the same clock in two layers,
        ///   like the check: its circle draws black and its hands white — and
        ///   the two marks a "+" can turn into share one construction.
        var symbolName: String? {
            switch self {
            case .none: nil
            case .follow: "plus"
            case .following: "checkmark.circle.fill"
            case .friends: "person.2.fill"
            case .pending: "clock.circle.fill"
            }
        }

        /// The symbol the badge draws: the relation's glyph inside its own
        /// disc (#1199), so the disc and the mark move as one.
        var circledSymbolName: String {
            switch self {
            case .none, .follow: "plus.circle.fill"
            case .following: "checkmark.circle.fill"
            case .friends: "person.2.circle.fill"
            case .pending: "clock.circle.fill"
            }
        }

        /// Each glyph's size on the badge's disc: the check and the clock are
        /// discs of their own, as large as it (drawn black, their marks white:
        /// `AvatarStatusBadge.glyphImage`); the "+" and the two people sit
        /// inside it.
        var pointSize: CGFloat {
            switch self {
            case .following, .pending: 13
            case .friends: 7
            case .none, .follow: 9
            }
        }

        var accessibilityLabel: String? {
            switch self {
            case .none: nil
            case .follow: "Follow"
            case .following: "Following"
            case .friends: "Friends"
            case .pending: "Requested"
            }
        }

        /// What the pill draws for where the viewer stands — ONE rule for a
        /// post's author and a conversation's correspondent (#752).
        init(_ relation: FollowRelation) {
            self = switch relation {
            case .notFollowing, .followedBy: .follow
            case .following: .following
            case .mutual: .friends
            // Drawn, not offered: the profile screen withdraws it.
            case .requested: .pending
            case .viewer, .blocked: .none
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
    /// Only while the redaction bars show: a hydrated pill takes its
    /// content's width (#925), a short name included.
    private static let minWidth: CGFloat = 150

    /// Caps the pill's width — the room its bar leaves it. The pill takes its
    /// intrinsic width, at most this (#925).
    ///
    /// The cap is real — the system overflows the whole item into a `•••`
    /// menu the moment the run does not fit (measured: the author's view
    /// chain dead-ended at its item wrapper, never reaching the window), and
    /// losing the author entirely is worse than any amount of truncation. So
    /// the pill pays for it in WIDTH: same two lines, same badge, same
    /// platter — the name simply truncates earlier.
    ///
    /// The floor comes off below `minWidth` (`applyWidthFloor`). A cap
    /// changed on an installed pill asks its bar for a pass.
    func setWidthBudget(_ budget: CGFloat?) {
        let target = min(Self.maxWidth, budget ?? Self.maxWidth)
        guard target > 0, maxWidthConstraint?.constant != target else { return }
        maxWidthConstraint?.constant = target
        applyWidthFloor()
        if superview != nil { BarItemRemeasure.run(self, duration: nil) }
    }

    /// The cold-tap floor holds while the redaction bars show, and never
    /// under a cap narrower than it, which it would otherwise out-argue.
    private func applyWidthFloor() {
        minWidthConstraint?.isActive = isRedacted && widthCap >= Self.minWidth
    }

    /// The widest the pill is drawn: the budget, under the pill's own cap.
    var widthCap: CGFloat { maxWidthConstraint?.constant ?? Self.maxWidth }

    /// Called when the identity is tapped, with the shown author.
    var onAuthorTapped: ((ProfileID) -> Void)?
    /// Called when the "+" is tapped, with the shown author. Never for a
    /// state mark (`FollowBadge`): those take no tap of their own.
    var onFollowTapped: ((ProfileID) -> Void)?

    /// The author's INITIALS, always drawn — the app's avatar contract:
    /// initials first, the picture hydrates in front of them. It used to be a
    /// grey disc for anyone without a picture, the one place in the app a
    /// person was faceless.
    ///
    /// The app's avatar (#943): the initials, the picture dissolved in over
    /// them and covering them once landed, a late face for someone else
    /// landing nowhere. Its load starts INSIDE the content swap (`draw`), so
    /// a face that arrives late can only land on the new author's content —
    /// never mid-blur on the old one.
    private let avatar = AvatarView(diameter: AvatarImageView.bubbleDiameter, size: SnapAuthorIdentityView.faceBucket)
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    /// The relation's mark over the avatar's bottom-right corner (#925).
    private let statusBadge = AvatarStatusBadge()
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
    /// (`BarItemContentTransition`), the glass taking the new width.
    private lazy var contentTransition: BarItemContentTransition = {
        let transition = BarItemContentTransition(host: self, content: contentView)
        transition.remeasure = { [weak self] duration in
            guard let self else { return }
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

    /// How blurred the pill SHOWS: the scroll's blur, or a swap's envelope.
    var shownScrubBlur: CGFloat { contentTransition.scrubBlur }

    /// Renders the blurred still a scroll may need, before the page moves.
    func prepareScrub() { contentTransition.prepareScrub() }

    /// Whose face the avatar task is loading — compared on arrival so a fast
    /// page-past cannot land a picture on the wrong pill.
    private var authorID: ProfileID?
    /// What is actually on screen, so a repeat call can tell "same page again"
    /// from "same page, better data".
    private var renderedModel: FeedItemDisplayModel?
    /// The width bounds, held so `setWidthBudget` can retune them.
    private var maxWidthConstraint: NSLayoutConstraint?
    private var minWidthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)

        // Size and circle geometry come from the shared component: the same
        // diameter as the Maps toolbar's profile avatar, and a radius bound
        // to the bounds each layout pass — a perfect circle by construction.
        // Clear: with no picture (yet) the initials behind show through.
        avatar.picture.backgroundColor = .clear

        // The bars' one identity look (`BarIdentityStyle`, the owner
        // 2026-10-15): the name at a bar item's title size over the handle.
        BarIdentityStyle.apply(name: nameLabel, handle: metaLabel)
        // THE ORDER THE PILL GIVES WAY IN, when the bar is too narrow to
        // hold everything: the display NAME truncates first, the handle
        // line only once the name has nothing left to give. A name is the
        // thing a reader can still recognize half-written ("Rosa Igle…");
        // a half-written handle is not an identifier at all. Resistance,
        // not two width rules — Auto Layout squeezes the lower one first
        // and never has to be told about the second.
        // (Set by `BarIdentityStyle.apply`.)

        // The bar is transparent over arbitrary media; shadows keep the
        // identity legible without a background.
        for label in [nameLabel, metaLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        applyFollowBadge(animated: false)
        statusBadge.addAction(UIAction { [weak self] _ in
            guard let self, self.followBadge == .follow, let id = self.authorID else { return }
            self.onFollowTapped?(id)
        }, for: .primaryActionTriggered)

        for view in [nameLabel, namePlaceholder, metaLabel, metaPlaceholder] {
            labelsStack.addArrangedSubview(view)
        }
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        setRedacted(true)

        let row = UIStackView(arrangedSubviews: [avatar, labelsStack])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        // The badge reaches half its width past the face (centred on its
        // edge, #1277): the name starts clear of it, whatever the relation —
        // a constant, so a badge arriving never moves the pill's width.
        row.setCustomSpacing(AvatarStatusBadge.overhang + Spacing.xs, after: avatar)
        row.alignment = .center
        // Any width the pill has beyond (or short of) its content — the floor
        // while it hydrates, the cap — is the labels area's: its content is
        // leading-aligned, so a stretched frame just gains invisible trailing
        // space, and it is the one member that gives way.
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        // The avatar's leading inset matches its vertical breathing exactly:
        // the bar's item wrapper renders 36pt tall and the avatar is
        // vertically centered, so the same computed gap on the left keeps it
        // uniform on all three sides whatever the shared diameter is. The
        // labels end the pill, so the trailing inset is the text's room
        // against the rounded end. The bar self-sizes custom views through
        // Auto Layout; the height pin and width cap are the only external
        // metrics.
        let avatarBreathing = max(0, (Self.barItemWrapperHeight - AvatarImageView.bubbleDiameter) / 2)
        contentView.pin(to: self)
        row.constrain(in: contentView) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: avatarBreathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // The badge rides the face's bottom-right corner, a little outside
        // it, over everything else the pill draws — inside the content, so a
        // new person's blur carries it with the face. Its size is its own:
        // nothing in the row is measured against it, so no relation ever
        // moves the pill's width. It takes its own taps (a control descendant
        // defeats the container's gesture) only while it is the "+";
        // otherwise touches fall through to the pill's author tap.
        // Trailing to trailing, not centre to trailing: only an edge-to-edge
        // offset mirrors under a right-to-left layout.
        //
        // ⚠️ CENTRED ON THE DISC'S EDGE, AT ITS MID-HEIGHT (the owner,
        // 2026-10-16, #1277): the badge's centre sits over the far end of the
        // face's disc, level with the face — no longer hanging off its
        // bottom corner.
        statusBadge.constrain(in: contentView) { _ in
            statusBadge.trailingAnchor.constraint(
                equalTo: avatar.trailingAnchor, constant: AvatarStatusBadge.overhang
            )
            statusBadge.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)
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
        // The redacted cold state's floor (`applyWidthFloor`). 999 so it can
        // never fight the bar's own constraints.
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)
        minWidth.priority = UILayoutPriority(999)
        minWidthConstraint = minWidth
        applyWidthFloor()

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `model`'s author, IN PLACE: the pill is one view in one bar item
    /// for the screen's life, and a change of what it draws blurs the old
    /// content out and the new in (`BarItemContentTransition`) while the
    /// item's glass stays where it is, gliding to the new author's width
    /// while only the blurred stills show.
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
        var faceURL = model.avatarURL
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-pill-no-face") { faceURL = nil }
        #endif
        contentTransition.perform(animated: animated) {
            self.setRedacted(false)
            self.nameLabel.text = model.authorName
            self.metaLabel.text = meta
            self.avatar.setMonogram(MonogramAvatarView.monogram(
                name: model.authorName, handle: Self.handle(fromMeta: model.metaText)
            ))
            // A face already in the pipeline's memory is drawn here, in the
            // same pass as the name — nothing to fade in after the pill
            // appears. Any other lands later, on THIS author's content.
            self.avatar.setPicture(faceURL, pipeline: pipeline)
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

    /// The bucket the pill's face is decoded at: the pipeline's avatar size,
    /// a small bitmap decoded off the main thread (#894).
    ///
    /// ⚠️ Never the full-size picture. The pill is also drawn by
    /// `CALayer.render` — the blurred stills of `BarItemContentTransition` —
    /// and that CPU path scales whatever the disc holds, on the main thread,
    /// on a frame of the scroll: a full-size face cost 22–40ms per first still
    /// on the iPhone 18 Pro simulator (`-pill-probe`), the same pill 3–7ms
    /// with a small one. The pipeline's memory answers synchronously, so a
    /// swap made on this turn draws the new author already wearing the face.
    static let faceBucket = ImageBucket.avatar

    /// Decodes `url`'s face into the pipeline ahead of need — the next page's
    /// author — so the pill's swap to them is drawn with it.
    static func warmFace(_ url: URL, pipeline: ImagePipeline) {
        guard !pipeline.isDecoded(url, size: faceBucket) else { return }
        Task { @MainActor in
            _ = try? await pipeline.image(for: url, size: faceBucket)
        }
    }

    /// Shows a person who is not a post's author — a conversation's
    /// correspondent. The meta line says whatever the host passes, and an
    /// empty one simply leaves the name alone on the pill.
    ///
    /// ⚠️ ONE PERSON IS DRAWN ONCE (#889). The correspondent arrives in
    /// pieces — the name, then their id, then the face and the @handle from
    /// one profile read — and a piece that lands for the person already on
    /// the pill changes in place: the new line is set and the glass glides
    /// to its width, the face fades in on the avatar alone. Only a
    /// DIFFERENT person (or the first one over the redaction bars) cross-
    /// fades the whole pill, as `setAuthor` does.
    func setPerson(id: ProfileID?, name: String, meta: String, avatarURL: URL?, pipeline: ImagePipeline) {
        let faceChanged = id != authorID || avatarURL != personAvatarURL
        guard faceChanged || name != nameLabel.text || meta != metaLabel.text else { return }
        // Someone else than the person drawn: an id that replaces another
        // id. A first id for the name already drawn is the same person.
        let personChanged = isRedacted || (authorID != nil && id != authorID)
        renderedModel = nil
        authorID = id
        let urlChanged = avatarURL != personAvatarURL
        personAvatarURL = avatarURL
        defer { BarItemRemeasure.run(self, duration: 0.22) }

        let draw = {
            self.setRedacted(false)
            self.nameLabel.text = name
            self.metaLabel.text = meta
            if personChanged { self.avatar.setPicture(nil, pipeline: nil) }
            self.avatar.setMonogram(MonogramAvatarView.monogram(
                name: name, handle: Self.handle(fromMeta: meta)
            ))
        }
        if personChanged {
            personFades += 1
            UIView.transition(with: self, duration: 0.18,
                              options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: draw) { _ in self.personFades -= 1 }
        } else {
            draw()
        }

        guard personChanged || urlChanged else { return }
        // The face over the initials (nil: the person's picture is gone, the
        // initials again); the avatar fades it in on the disc alone.
        avatar.setPicture(avatarURL, pipeline: pipeline)
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

    /// What the avatar's badge says: the viewer's relation to the author (the
    /// snap feed) or to the correspondent (a conversation, #752), and none
    /// for the viewer themself or while it does not know.
    ///
    /// ⚠️ EVERY CHANGE IS ONE SYMBOL REPLACING ANOTHER (#925) — a follow tap
    /// turning the "+" into the followed mark and a relation read landing
    /// late alike: `animated`, on screen, the badge's symbol changes through
    /// SF Symbols' replace transition, and nothing else moves. The pill is
    /// never blurred or faded for it (it used to be, through the author's own
    /// swap, #889), and the bar item is never resized — the badge sits over
    /// the face, outside anything the pill's width is made of.
    ///
    /// A swap of the pill's WHOLE content already under way (a new author
    /// blurring in) takes the badge with it instead: set in the same turn as
    /// a new author, the badge lands in that one swap.
    func setFollowBadge(_ badge: FollowBadge, animated: Bool = false) {
        guard badge != followBadge else { return }
        followBadge = badge
        // `afterSwap` runs the change at once, unless the pill's content is
        // being swapped: then at that swap's midpoint, under its blur, where
        // a symbol transition would play unseen and its still would picture
        // it half-drawn — so only a change made NOW animates.
        var now = true
        contentTransition.afterSwap { [weak self] in
            guard let self else { return }
            self.applyFollowBadge(animated: now && animated && self.window != nil)
        }
        now = false
    }

    /// Whether the WHOLE pill is being redrawn through a transition — the
    /// blur swap, or the person cross-fade. Tests: a relation change must
    /// never show one (#889, #925).
    var isRedrawingWholePill: Bool { contentTransition.isRunning || personFades > 0 }

    /// The person cross-fades under way (`setPerson`).
    private var personFades = 0

    /// Whether the "+" is on offer.
    var offersFollow: Bool { followBadge == .follow }

    /// The pill's own default is the "+": a host that offers no follow says
    /// so (`setFollowBadge(.none)`).
    private(set) var followBadge: FollowBadge = .follow

    /// The symbol the badge draws now — nil for none. Tests.
    var drawnBadgeSymbol: String? { statusBadge.drawn.symbolName }

    /// How many badge changes were drawn through the symbol replace. Tests.
    var badgeReplaceCount: Int { statusBadge.replaceCount }

    /// The badge's disc and glyph images as drawn now. Tests (#968).
    var drawnBadgeImages: (disc: UIImage?, glyph: UIImage?) { statusBadge.drawnImages }

    /// Draws `followBadge` on the avatar. Only the "+" takes touches — a
    /// state mark lets them through to the pill's own tap (the profile),
    /// which is the natural reading of tapping someone's "friends" mark and
    /// keeps unfollowing where it already lives.
    private func applyFollowBadge(animated: Bool) {
        statusBadge.show(followBadge, animated: animated)
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
        applyWidthFloor()
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
        // Below the width cap: a narrow pill shortens the bar rather than
        // being widened by it. Still above a fitting pass's own level, so a
        // hugging pill keeps the bar's length.
        let length = bar.widthAnchor.constraint(equalToConstant: width)
        length.priority = .defaultHigh
        length.isActive = true
        bar.heightAnchor.constraint(equalToConstant: height).isActive = true
        return bar
    }
}

/// The person pill's relation badge (#925): a small disc over the avatar's
/// bottom-right corner wearing the relation's symbol.
///
/// TWO SYMBOL VIEWS, BOTH SF SYMBOLS: the disc (`circle.fill`) and the glyph
/// on it. A change of relation REPLACES the glyph (SF Symbols' replace
/// transition); to or from no badge, the disc is replaced too, from or into a
/// clear one — so appearing and disappearing are that same replace, and the
/// badge is never faded, scaled or hidden by hand.
///
/// ⚠️ FIXED INK, and a disc that is a SYMBOL, not a background. On glass a
/// semantic ink pair draws vibrant and an inverted badge vanishes in dark mode
/// (memory `sheet-glass-vibrancy-ink`), and the glass repaints a subview's
/// `backgroundColor` with its own corner (`glass-paints-background-color`).
/// So both inks are fixed (`.alwaysOriginal`, or a palette) and the disc is
/// drawn by an image.
///
/// BLACK DISC, WHITE GLYPH, in light and dark mode alike (owner, #968): the
/// badge is one mark whatever the appearance or the photo behind the bar.
private final class AvatarStatusBadge: UIButton {
    /// The disc's side — larger than the 16pt it was (the owner, 2026-10-16,
    /// #1277).
    static let diameter: CGFloat = 20
    /// How far the badge reaches past the face's edge: half its side, its
    /// centre being ON that edge.
    static var overhang: CGFloat { diameter / 2 }
    /// The touch area around the disc: a 20pt disc is still too small a target.
    private static let touchOutset: CGFloat = 8

    /// The badge — its disc and its mark are ONE circled symbol drawn with a
    /// palette (#1199): two image views, a disc and a mark each with its own
    /// replace, arrived and left out of step (the owner, on a device).
    private let glyph = UIImageView()
    /// The badge on screen.
    private(set) var drawn: SnapAuthorIdentityView.FollowBadge = .none
    /// Changes drawn through the replace transition.
    private(set) var replaceCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [glyph] {
            view.isUserInteractionEnabled = false
            view.contentMode = .center
            view.constrain(in: self) { parent in
                view.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
                view.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            }
        }
        // Its size is its own and never the pill's to negotiate.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
        glyph.image = Self.glyphImage(.none)
        apply(interactionFor: .none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchOutset, dy: -Self.touchOutset).contains(point)
    }

    /// Draws `badge` — through the symbol replace when `animated`, at once
    /// otherwise.
    func show(_ badge: SnapAuthorIdentityView.FollowBadge, animated: Bool) {
        guard badge != drawn else { return }
        drawn = badge
        apply(interactionFor: badge)
        let glyphImage = Self.glyphImage(badge)
        guard animated else {
            glyph.image = glyphImage
            return
        }
        replaceCount += 1
        // ONE replace for the disc and the mark (#1199): they are one symbol.
        glyph.setSymbolImage(glyphImage, contentTransition: .replace)
    }

    private func apply(interactionFor badge: SnapAuthorIdentityView.FollowBadge) {
        isUserInteractionEnabled = badge == .follow
        isAccessibilityElement = badge != .none
        accessibilityLabel = badge.accessibilityLabel
        accessibilityTraits = badge == .follow ? .button : .staticText
    }

    /// The disc's ink and the glyph's: fixed, never resolved per appearance
    /// (#968).
    static let restingDiscInk = UIColor.black
    static let glyphInk = UIColor.white

    static var accentInk: UIColor { AvatarBadgeInks.accent }
    static var quietDiscInk: UIColor { AvatarBadgeInks.quietDisc }

    /// The disc's ink for a badge (#1197, the owner 2026-10-15): the "+"
    /// black; a FOLLOWED check and a pending request grey, their mark pink;
    /// FRIENDS pink, their mark white; clear for none.
    static func discInk(for badge: SnapAuthorIdentityView.FollowBadge) -> UIColor {
        switch badge {
        case .none: .clear
        case .follow: restingDiscInk
        case .following, .pending: quietDiscInk
        case .friends: accentInk
        }
    }

    /// The glyph's ink for a badge: pink on the grey discs, white elsewhere.
    static func glyphInk(for badge: SnapAuthorIdentityView.FollowBadge) -> UIColor {
        switch badge {
        case .none: .clear
        case .following, .pending: accentInk
        case .follow, .friends: glyphInk
        }
    }

    /// The badge as one image: the relation's circled symbol — its disc and
    /// its mark one symbol — in a palette (mark, disc); for none, the same
    /// symbol in clear ink, so the badge's arrival and departure are replaces
    /// too.
    ///
    /// ⚠️ A palette is fixed ink already (no tint reaches it), and must NOT
    /// be re-marked `.alwaysOriginal`: that drops the palette and draws the
    /// whole symbol in the view's tint (measured: the system blue).
    private static func glyphImage(_ badge: SnapAuthorIdentityView.FollowBadge) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: diameter - 3, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [glyphInk(for: badge), discInk(for: badge)]))
        return UIImage(systemName: badge.circledSymbolName)?
            .applyingSymbolConfiguration(configuration)
            ?? UIImage()
    }

    /// The disc's and the glyph's images as drawn now. Tests.
    var drawnImages: (disc: UIImage?, glyph: UIImage?) { (nil, glyph.image) }
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
        config.image = UIImage.symbol(named: systemName)?
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

#if DEBUG
extension SnapAuthorIdentityView {
    /// The picture on the disc now; nil while the initials show.
    var debugFaceImage: UIImage? { avatar.shownPicture }
    /// The lines the pill shows, top to bottom, and the name's font.
    var debugShownLines: [String] {
        [nameLabel, metaLabel].filter { !$0.isHidden }.compactMap(\.text)
    }
    var debugNameFont: UIFont { nameLabel.font }
    var debugHandleFont: UIFont { metaLabel.font }

    /// `-pill-probe`: what the pill's disc actually is at this instant — its
    /// frame in the window, its corner and mask, every transformed ancestor up
    /// to the bar, and any OTHER view in the window drawing the same initials.
    func debugProbe(_ tag: String) {
        guard let window else { print("[pill-probe] \(tag) pill=\(ObjectIdentifier(self)) NO WINDOW"); return }
        let disc = avatar.monogram
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

/// The author pill badge's fixed inks (#968, #1197): one value in either
/// appearance.
enum AvatarBadgeInks {
    /// The accent pink.
    static let accent = Palette.tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    /// A quiet grey disc.
    static let quietDisc = UIColor.systemGray5.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
}
