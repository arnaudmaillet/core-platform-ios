import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The author band a list row wears above its caption: the disc on the left at
/// two lines tall, the display name over the handle beside it, an overflow
/// control trailing and centred on the pair.
///
/// ## Why it is a view and not a method on the cell
///
/// It is drawn TWICE, in two packages, and the two must be pixel-identical.
///
/// The row draws it. And a reveal draws it again — inside the destination, as a
/// transition prop, so that the window a viewer is holding shows the same
/// header the card does instead of a blank strip that the card's own header
/// then fades into. The whole point of that prop is that the swap at the
/// landing is the IDENTITY; two hand-written copies of one band would agree on
/// the day they were written and diverge from the first correction onward —
/// and they would diverge silently, because the only moment both are on screen
/// is the moment the transition is trying to make invisible.
///
/// So there is one band, configured from one model.
public final class PostAuthorBandView: UIView {
    /// The band's disc: two lines tall, because that is what it sits beside —
    /// the display name over the handle.
    public static let avatarDiameter: CGFloat = 40
    /// The gap between the band and the caption under it.
    public static let captionGap: CGFloat = 12
    /// The width of one control in the trailing cluster.
    ///
    /// 36 rather than the disc's 40: three of those plus the pill's own padding
    /// came to more than the free-standing squares they replaced, and every
    /// point the cluster takes is a point off a handle that truncates. The three
    /// and the capsule together are 120pt — exactly what the bare squares were.
    public static let actionControlWidth: CGFloat = 36
    /// The cluster pill's padding. Narrower than the text pills' 12: a glyph
    /// button already carries its own margin inside its width, so the text
    /// value would push the three apart and swell the capsule.
    static let actionPillInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 6, bottom: 0, trailing: 6
    )
    /// How far below a card's top edge its caption begins, when the card wears
    /// one of these. The card's own top inset cancels — the band starts at
    /// `captionTopInset` and so does the caption inside a reveal's window — so
    /// what is left between them is the disc and the gap.
    public static let captionOffset: CGFloat = avatarDiameter + captionGap

    /// Everything the band draws, so a row and a transition prop are configured
    /// from one value rather than from two readings of a post.
    public struct Model: Equatable, Sendable {
        public let name: String
        public let handle: String
        public let avatarURL: URL?
        public let monogram: String

        /// `nil` when the post carries no identity at all — a profile
        /// gallery's posts do not, being already scoped to one author — and the
        /// band is then not drawn.
        public init?(post: GalleryPost) {
            let name = post.authorName?.trimmingCharacters(in: .whitespaces) ?? ""
            let handle = post.authorHandle?.trimmingCharacters(in: .whitespaces) ?? ""
            // Either half is enough to draw an identity, and neither is enough
            // to draw one without the other's absence showing — so the band is
            // shown for a post that has ANY of them and each label carries what
            // it has.
            guard !name.isEmpty || !handle.isEmpty else { return nil }
            self.name = name.isEmpty ? handle : name
            self.handle = handle
            avatarURL = post.authorAvatarURL
            monogram = Self.monogram(name: name, handle: handle)
        }

        /// Initials, on the app's rule: the display name when there is one, the
        /// handle when there is not.
        private static func monogram(name: String, handle: String) -> String {
            let source = name.isEmpty ? handle : name
            let initials = source
                .split(separator: " ")
                .prefix(2)
                .compactMap { $0.first.map { String($0).uppercased() } }
            return initials.isEmpty ? "?" : initials.joined()
        }
    }

    /// Fired when the viewer taps the identity — the disc, the name or the
    /// handle. `nil` on the reveal's prop, which is scenery and takes no
    /// touches.
    public var onAuthorTapped: (() -> Void)?

    /// The rows the "..." offers, asked for at the moment it is pressed.
    ///
    /// A PROVIDER rather than a stored menu, because what a row can offer
    /// depends on state the cell does not own and that can move under it — a
    /// follow that was just undone, a reporting seam that resolved late.
    ///
    /// ⚠️ It is asked TWICE, and the first time is the whole reason the control
    /// is ever hidden. Whether a provider EXISTS says nothing: a surface hands
    /// one to every row that has an author, and it is the ANSWER that turns out
    /// to be empty — the viewer's own post, which nobody may report and nobody
    /// may unfollow. Visibility that tracked the provider left a "..." that
    /// opened an empty sheet. So the rows are asked for once here, to decide
    /// whether the control is drawn at all, and again when it is pressed, for
    /// what it says.
    public var menuActions: (() -> [PostCardMenuAction])? {
        didSet {
            menuButton.isHidden = menuActions?().isEmpty ?? true
            syncPillVisibility()
        }
    }

    private let avatar = MonogramAvatarView(diameter: PostAuthorBandView.avatarDiameter)
    private let avatarImage = AvatarImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let menuButton = BandActionButton(type: .system)
    private let repostButton = BandActionButton(type: .system)
    private let bookmarkButton = BandActionButton(type: .system)
    /// The trailing cluster: repost, bookmark, "..." — in a PILL, the same one
    /// the counters and the date wear over the media, at the same height.
    ///
    /// One container rather than three anchored buttons so the identity has ONE
    /// thing to be squeezed by, so a hidden control closes its own gap, and so
    /// three glyphs floating against the card fill read as a group of controls
    /// instead of three loose marks beside a name.
    private var actionPill: PostActionPillView!
    /// The whole trailing group: the bare overflow, then the pill.
    private let actionCluster = UIStackView()
    private let identityControl = UIControl()

    /// Fired when the viewer asks to repost this post. Nil HIDES the control —
    /// the same rule the "..." follows: visibility tracks the answer, never the
    /// presence of a provider.
    public var onRepostTapped: (() -> Void)? {
        didSet {
            repostButton.isHidden = onRepostTapped == nil
            syncPillVisibility()
        }
    }

    /// Fired when the viewer saves or unsaves this post. Nil hides the control.
    public var onBookmarkTapped: (() -> Void)? {
        didSet {
            bookmarkButton.isHidden = onBookmarkTapped == nil
            syncPillVisibility()
        }
    }

    /// Whether this post is saved — the glyph follows, filled or outline.
    ///
    /// Set by the HOST from whatever owns the pile, never toggled here: a
    /// control that flipped its own state would be a second opinion about
    /// something the store already answers, and the two would drift the first
    /// time a save failed.
    public var isBookmarked: Bool = false {
        didSet { applyBookmarkGlyph() }
    }
    private var avatarTask: Task<Void, Never>?

    /// What a popover-shaped presentation should point at — the control the
    /// viewer actually pressed.
    public var menuAnchor: UIView { menuButton }

    public init() {
        super.init(frame: .zero)

        nameLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail

        handleLabel.font = .preferredFont(forTextStyle: .footnote)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel
        handleLabel.lineBreakMode = .byTruncatingTail

        let identity = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        identity.axis = .vertical
        identity.alignment = .leading
        identity.spacing = 1
        // A CONTROL around the disc and the two labels, not a tap gesture on
        // them.
        //
        // The band lives inside a collection view cell whose whole face opens
        // the post. A `UITapGestureRecognizer` on a subview does not reliably
        // stop that — the collection view's selection is driven by its own
        // touch handling, and both would fire, opening the post *and* pushing
        // the profile. A `UIControl` consumes the touch, which is the same
        // reason an ordinary button inside a cell has never selected its row.
        identityControl.addTarget(self, action: #selector(authorPressed), for: .touchUpInside)
        // The contents are made INERT so the control itself is the hit view.
        //
        // Forwarding up the responder chain from a hit subview is not enough
        // here: the band sits inside a collection view, and a scroll view
        // decides whether to delay and whether to cancel a touch by asking what
        // the hit view IS — a control gets the touch immediately, anything else
        // is held and can be cancelled out from under it. This is the same
        // reason `UIButton` disables interaction on its own image and title.
        avatar.isUserInteractionEnabled = false
        identity.isUserInteractionEnabled = false
        nameLabel.isUserInteractionEnabled = false
        handleLabel.isUserInteractionEnabled = false

        menuButton.configuration = Self.actionConfiguration(systemName: "ellipsis")
        menuButton.accessibilityLabel = "More actions"
        // The menu IS the button's action — no touch-up handler, so there is no
        // frame in which the control is pressed and nothing has appeared.
        menuButton.showsMenuAsPrimaryAction = true
        // UNCACHED and deferred: the rows are asked for when the menu opens,
        // not when the cell is configured. A cached menu would offer to
        // unfollow someone the viewer unfollowed a moment ago from the same
        // row — the same reason the profile's "..." defers its own moderation
        // group.
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let actions = self?.menuActions?() else { return completion([]) }
                completion(actions.map(\.element))
            }
        ])
        menuButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        menuButton.setContentHuggingPriority(.required, for: .horizontal)
        // ⚠️ The width is the CONTROL's, not the cluster's. It used to live in
        // the band's own constraint block; moving the button into a stack took
        // it with it, and the "..." silently fell back to its glyph's intrinsic
        // width — 21.7pt against 40 — so it stopped being the tap target the
        // note above describes. Sized here, beside the two that already are.
        sizeActionControl(menuButton)

        buildActionButton(repostButton, systemName: "arrow.2.squarepath", label: "Repost")
        repostButton.addTarget(self, action: #selector(repostPressed), for: .touchUpInside)
        buildActionButton(bookmarkButton, systemName: "bookmark", label: "Save")
        bookmarkButton.addTarget(self, action: #selector(bookmarkPressed), for: .touchUpInside)
        repostButton.isHidden = true
        bookmarkButton.isHidden = true

        // ⚠️ The "..." is NOT in the capsule, and leads it: `••• [ repost save ]`.
        //
        // The pill groups the two controls that act on the POST — send it on,
        // keep it. The overflow acts on the row itself and on the person, which
        // is a different kind of thing, and a capsule is a claim that what is
        // inside belongs together. Outside it, bare, it also stops competing
        // with the two glyphs it used to sit beside.
        //
        // The pill still builds its own row from its contents, so a hidden
        // control collapses its slot and an empty pill hides itself — an empty
        // capsule beside a name is the same defect as an empty one on a
        // photograph. Which is now reachable: a surface that wires only the
        // overflow draws the "..." alone and no capsule at all.
        actionPill = PostActionPillView(
            contents: [repostButton, bookmarkButton],
            spacing: 0, insets: Self.actionPillInsets
        )
        actionCluster.axis = .horizontal
        // FILL, so the bare "..." is as tall as the capsule beside it and the
        // two share one hit height. Centring instead would leave the overflow a
        // ~18pt target between two 29pt ones.
        actionCluster.alignment = .fill
        actionCluster.spacing = Spacing.xs
        actionCluster.addArrangedSubview(menuButton)
        actionCluster.addArrangedSubview(actionPill)
        // ⚠️ The trailing cluster OUTRANKS the identity horizontally.
        //
        // A name and a handle are the compressible half of this band: they
        // already truncate by tail, and a long one must give way rather than
        // push a control off the card. Required resistance on the cluster plus
        // low resistance on the labels is what decides that — without both, the
        // labels' default 750 wins some layouts and the buttons are clipped.
        actionCluster.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionCluster.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The picture is laid OVER the monogram rather than replacing it — the
        // app's avatar contract: initials are the rendered state and a
        // photograph hydrates in front of them.
        avatarImage.pin(to: avatar)
        avatarImage.isHidden = true

        identityControl.addSubview(avatar)
        identityControl.addSubview(identity)
        addSubview(identityControl)
        addSubview(actionCluster)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        identityControl.translatesAutoresizingMaskIntoConstraints = false
        actionCluster.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            identityControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityControl.topAnchor.constraint(equalTo: topAnchor),
            identityControl.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The control ends where the IDENTITY ends, not where the band
            // does: the tappable region is the person, and the empty run
            // between a short name and the "..." belongs to the card.
            identityControl.trailingAnchor.constraint(
                lessThanOrEqualTo: actionCluster.leadingAnchor, constant: -Spacing.sm
            ),

            avatar.leadingAnchor.constraint(equalTo: identityControl.leadingAnchor),
            avatar.topAnchor.constraint(equalTo: identityControl.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: identityControl.bottomAnchor),

            identity.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Spacing.sm),
            identity.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            identity.trailingAnchor.constraint(equalTo: identityControl.trailingAnchor),

            actionCluster.trailingAnchor.constraint(equalTo: trailingAnchor),
            // ⚠️ TOP-ALIGNED, and it is the CARD's corner that decides that.
            //
            // Centred on the disc, the capsule sat below the card's top-right
            // arc and its curve answered to nothing. Hung from the band's top
            // edge it lands inset from that corner by exactly what the band is
            // inset by, and the concentric rule then says its radius should be
            // the card's minus that inset: 26 - 12 = 14. A capsule this tall has
            // a radius of 14.5. It is already the right shape — it was only in
            // the wrong place, and the half point is invisible.
            //
            // No height here: the pill declares its own, the same one every pill
            // on the card is (`PostMetaPillView.height`). The band stays as tall
            // as the disc, so a shorter cluster does not move the caption.
            actionCluster.topAnchor.constraint(equalTo: topAnchor)
        ])
        menuButton.isHidden = true
        syncPillVisibility()
    }

    /// The capsule is drawn only when it has something in it.
    ///
    /// A row that wires no control at all — a profile gallery's, whose posts
    /// are already scoped to one author — would otherwise carry an empty pill
    /// where the identity's breathing room used to be. Same rule as the
    /// counters over the media: the container tracks its contents' ANSWER.
    private func syncPillVisibility() {
        actionPill?.syncVisibilityToContents()
    }

    /// One control of the trailing cluster: a fixed width, glyph floating in the
    /// middle, height left to the pill.
    ///
    /// Zero insets and an explicit width rather than padding a glyph out to
    /// size, for the reason the "..." states: the cluster is centred on the
    /// disc, so a tap target grown by insets grows the band and pushes the
    /// caption down.
    private func buildActionButton(_ button: UIButton, systemName: String, label: String) {
        button.configuration = Self.actionConfiguration(systemName: systemName)
        button.accessibilityLabel = label
        sizeActionControl(button)
    }

    /// ⚠️ A LONE GLYPH IS SIZED TO ITS CONTAINER, NOT TO THE CARD'S TYPE.
    ///
    /// Two wrong answers were tried first, in opposite directions. A `UIButton`
    /// sizes a symbol from its own font — body, 17pt — which was right while
    /// these were 40pt squares standing free in the band and crowded a capsule
    /// the height of a footnote. Matching `PostMetaPillView.font` instead, so
    /// every glyph on the card would be drawn at one size, produced glyphs that
    /// LOOK smaller than the counters' — and measuring the rendered ink is what
    /// explained it: the heart beside "160" is 9pt tall, the bookmark here was
    /// 13pt. Bigger, and reading as smaller.
    ///
    /// Because they are not measured against the same thing. A glyph next to a
    /// number is read against that number and belongs at its size; a glyph alone
    /// in a capsule is read against the empty capsule around it, and at the
    /// counters' size it is a small mark in a wide field. UIKit's own bar
    /// buttons settle this at a little over half their container.
    ///
    /// So this one is derived from the PILL, and the counters stay derived from
    /// their text — which is also why enlarging the pill would be the wrong fix:
    /// the height is shared with every chip on the card, and the counters do not
    /// need it.
    private static var glyphPointSize: CGFloat {
        (PostMetaPillView.height * 0.58).rounded()
    }

    /// One configuration for all three controls.
    ///
    /// Zero content insets, rather than padding a glyph out to size: the width
    /// is set by a constraint, so insets would only fight it.
    private static func actionConfiguration(systemName: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        // `.medium`, one step up from regular and deliberately not two.
        //
        // Compared on screen at all three: regular reads thin on a filled
        // ground, semibold empties the repost arrows into a blob and turns the
        // "..." into three heavy dots that compete with the author's name. The
        // band's hierarchy is name, then handle, then these — a control that has
        // a CONTAINER to give it presence does not also need weight to shout.
        //
        // Colour stays `.secondaryLabel` for the same reason: `.label` would put
        // three near-black marks beside a `.label` name and flatten the order
        // the band is built on.
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: glyphPointSize, weight: .medium, scale: .medium
        )
        return configuration
    }

    /// ⚠️ WIDTH ONLY — the height belongs to the pill.
    ///
    /// These were 40pt squares standing free in the band. Inside a capsule the
    /// height of a line of type, a 40pt square would either swell the pill past
    /// every other one on the card or be clipped by it; the drawn control is now
    /// as tall as the row it sits in, and `BandActionButton` grows the TOUCH
    /// region back to 44 without growing the chrome.
    private func sizeActionControl(_ button: UIButton) {
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.actionControlWidth).isActive = true
    }

    @objc private func repostPressed() { onRepostTapped?() }
    @objc private func bookmarkPressed() { onBookmarkTapped?() }

    private func applyBookmarkGlyph() {
        bookmarkButton.configuration?.image =
            UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
        bookmarkButton.accessibilityLabel = isBookmarked ? "Saved" : "Save"
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func authorPressed() {
        onAuthorTapped?()
    }

    public func configure(with model: Model, imagePipeline: ImagePipeline?) {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true

        nameLabel.text = model.name
        handleLabel.text = model.handle.isEmpty ? nil : "@" + model.handle
        handleLabel.isHidden = model.handle.isEmpty
        avatar.setMonogram(model.monogram)

        guard let url = model.avatarURL, let imagePipeline else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            avatarImage.image = cached
            avatarImage.isHidden = false
            return
        }
        // Reuse is handled by CANCELLATION, as the row's cover load is: the
        // task is dropped in `prepareForReuse`, so a picture cannot arrive for
        // a post this band has stopped representing.
        avatarTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url),
                  !Task.isCancelled, let self
            else { return }
            self.avatarImage.image = image
            self.avatarImage.isHidden = false
        }
    }

    /// Draws the "..." without wiring it.
    ///
    /// For the reveal's PROPS — the destination's borrowed band and the
    /// dismissal's stand-in card. They are scenery: interaction is off, so
    /// nothing can be pressed, but they must show what the card shows or the
    /// control pops in at the landing, which is the one frame the whole
    /// transition exists to make invisible.
    public func showMenuControlAsScenery() {
        menuButton.isHidden = false
        syncPillVisibility()
    }

    /// Draws the trailing cluster without wiring it — for a transition's
    /// stand-in card, which has to look like the row it stands in for.
    ///
    /// ⚠️ The stand-in must match the ROW, not the design: a row on the profile
    /// gallery has no repost or bookmark unless its host wired them, so the
    /// caller passes what that row actually shows. A stand-in that drew all
    /// three unconditionally would end every dismissal with two controls
    /// vanishing — the same last-frame pop the "..." version of this note
    /// describes.
    public func showActionControlsAsScenery(repost: Bool, bookmark: Bool, saved: Bool) {
        repostButton.isHidden = !repost
        bookmarkButton.isHidden = !bookmark
        isBookmarked = saved
        syncPillVisibility()
    }

    /// What this band is currently drawing, so a stand-in can be told to match.
    public var visibleActionControls: (repost: Bool, bookmark: Bool, saved: Bool) {
        (!repostButton.isHidden, !bookmarkButton.isHidden, isBookmarked)
    }

    /// Drops any in-flight picture load. Called from the row's reuse.
    public func cancelPendingWork() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true
    }

}

/// The band's control cluster, wearing the card's own pill.
///
/// Interaction is ON, which is the one thing every other `PostMetaPillView` on
/// a card turns off — the counters and the date are furniture over a photo and
/// must not swallow the tap that opens the post. This one exists to be pressed.
private final class PostActionPillView: PostCardPillView {
    override init(
        contents: [UIView], spacing: CGFloat = 8,
        insets: NSDirectionalEdgeInsets = PostMetaPillView.insets
    ) {
        super.init(contents: contents, spacing: spacing, insets: insets)
        // Interaction is ON, which is the one thing every other pill on a card
        // turns off — the counters and the date are furniture and must not
        // swallow the tap that opens the post. This one exists to be pressed.
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Folds the pill's vertical hit-slop onto the row inside it.
    ///
    /// ⚠️ `point(inside:)` alone does NOT give the buttons a 44pt target. It
    /// lets the touch reach the PILL, and hit-testing then walks its subviews —
    /// which are bounded normally, so a touch 6pt below the capsule finds the
    /// content view outside itself, and the pill answers for a press that was
    /// aimed at a control. Clamping the point back into the pill hands it to
    /// whichever button it was under.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event), hit !== self { return hit }
        guard self.point(inside: point, with: event), bounds.height > 2 else { return nil }
        let clamped = CGPoint(x: point.x, y: min(max(point.y, 1), bounds.height - 1))
        let retargeted = super.hitTest(clamped, with: event)
        return retargeted === self ? nil : retargeted
    }
}

/// A control of that cluster. The pill is the height of a line of type, which
/// is shorter than a finger — so the drawn glyph stays small and the hit region
/// grows around it, the way `PostMetaPillView` sizes its own chips.
private final class BandActionButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slopY = max((PostMetaPillView.minimumTouchTarget - bounds.height) / 2, 0)
        return bounds.insetBy(dx: 0, dy: -slopY).contains(point)
    }
}
