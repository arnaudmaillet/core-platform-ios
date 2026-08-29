import CoreModels
import MediaCore
import DesignSystem
import UIKit

/// A single comment: identity disc, "Name · time" header (display name
/// only — the @handle identifier was removed for reading comfort), and body.
///
/// REUSABLE by design. It is configured, not constructed, per appearance:
/// `CommentCell` owns one instance for its lifetime and re-points it at a
/// model on every dequeue. Building a fresh row per dequeue — a view tree,
/// two gesture recognizers, and a context-menu interaction, all on the main
/// thread mid-scroll — is exactly the kind of per-frame allocation that
/// costs a stream its 60fps.
///
/// AVATARS follow the app-wide contract: the two-letter monogram is the
/// RENDERED state, drawn synchronously at configure time; the picture is an
/// enhancement layered OVER it that may never arrive. No row waits on a
/// face, and nothing here has a third "loading" state — a missing URL, a
/// slow network, and a failed fetch all leave the same disc standing.
///
/// Interactions, all host-wired seams:
/// - avatar tap → the author's profile (the outbound push lifecycle).
/// - row tap → the composer's reply state, bound to this thread.
/// - long press → the native context menu (share / block / report).
final class CommentRowView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 32
        static let avatarGap: CGFloat = Spacing.sm
        /// The level-2 indentation: replies step in by one avatar column
        /// (avatar + its gap), the standard thread offset — a reply's
        /// avatar starts where its parent's text does.
        static let replyIndent: CGFloat = avatarSize + 8
    }

    /// Exposed for layout tests: the leading inset a reply row applies.
    static var replyIndent: CGFloat { Metrics.replyIndent }
    /// The avatar column, shared with the caption bubble row so the two
    /// align to the point — that alignment is what makes the caption read
    /// as the thread's first message.
    static var avatarSize: CGFloat { Metrics.avatarSize }
    static var avatarGap: CGFloat { Metrics.avatarGap }

    /// The shared identity disc — the SAME component the chat inbox, the
    /// compose picker, and the profile relationship lists draw, at this
    /// surface's diameter. Two features rolling their own discs drift, and
    /// the lists read as different products the moment they do.
    private let avatarView = MonogramAvatarView(diameter: Metrics.avatarSize)
    /// The picture, pinned OVER the monogram (never swapped for it — the
    /// monogram stays behind as the permanent fallback).
    private let avatarImageView = AvatarImageView()
    /// The in-flight avatar fetch, cancelled on reuse.
    private var avatarTask: Task<Void, Never>?
    /// REUSE GUARD, and it must be an identity check rather than
    /// cancellation alone: a recycled row can outlive its own fetch, and
    /// without this a slow avatar lands on whichever comment the row has
    /// since become.
    private var representedID: String?
    /// The reply indent, restated per configure — a reused row can switch
    /// depth between a top-level comment and a reply.
    private var rowLeading: NSLayoutConstraint?
    /// The row's own two comment-only interactions, held so a caption can take
    /// them off and a recycled row can put them back.
    private var rowTapRecognizer: UITapGestureRecognizer?
    private var contextMenu: UIContextMenuInteraction?
    private let headerLabel = UILabel()
    private let bodyLabel = UILabel()
    /// The header line's trailing control: ♥ + counter, pushed to the far
    /// right of the name/time axis by the header label's stretch (the
    /// dynamic spacer) — and anchored to the row's trailing edge, which
    /// the engaged layout already stops at the reactions rail's boundary
    /// (`setEngagedInsets(trailing:)`), so the counter can never sit
    /// under the rail.
    private let likeButton = UIButton(configuration: .plain())

    /// Avatar tapped — push the author's profile.
    var onAvatarTap: (() -> Void)?
    /// The header's ♥ tapped. Like state is the HOST's affair (session-
    /// local optimistic toggle — the bookmark posture; comment.v1 carries
    /// no like API yet).
    var onLikeTap: (() -> Void)?
    /// Row tapped — enter the composer's reply state for this thread.
    var onReplyTap: (() -> Void)?
    /// Context-menu actions. Share presents the system sheet; block and
    /// report are seams (no moderation backend yet — the repost/save
    /// posture: honest affordances, unwired mutations).
    var onShare: (() -> Void)?
    var onBlock: (() -> Void)?
    var onReport: (() -> Void)?

    init() {
        super.init(frame: .zero)
        buildLayout()

        // The avatar's tap outranks the row's (recognizers resolve to the
        // deepest view); everything else on the row is the reply trigger.
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        )
        // The row's reply tap is FILTERED (see the gesture delegate):
        // touches on the avatar or any control (the like button) keep
        // their own actions exclusive — without the filter the row tap
        // fires alongside them.
        let rowTap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
        rowTap.delegate = self
        addGestureRecognizer(rowTap)
        rowTapRecognizer = rowTap
        // Held, because a caption row takes them away and a recycled row puts
        // them back — see `configureAsPostCaption`.
        let menu = UIContextMenuInteraction(delegate: self)
        contextMenu = menu
        addInteraction(menu)
    }

    /// Test/preview convenience: build and configure in one step.
    convenience init(model: CommentDisplayModel) {
        self.init()
        configure(with: model)
    }

    /// Points the row at a comment. Everything textual lands SYNCHRONOUSLY,
    /// including the monogram — the row is fully readable on the frame it
    /// appears, and only the picture arrives later.
    func configure(with model: CommentDisplayModel, imagePipeline: ImagePipeline? = nil) {
        representedID = model.id
        headerLabel.text = "\(model.authorName) · \(model.metaText)"
        bodyLabel.text = model.body
        avatarView.setMonogram(model.monogram)
        rowLeading?.constant = model.isReply ? Metrics.replyIndent : 0
        loadAvatar(model.avatarURL, for: model.id, using: imagePipeline)
    }

    /// Points the row at the POST — the thread's first message.
    ///
    /// ⚠️ THE SAME VIEW, not a twin. The caption used to be its own component
    /// (a Liquid Glass bubble, then a flat card) and its own geometry, and the
    /// whole job of that geometry was to line up with this row: same avatar
    /// column, same header line, same body inset. Two objects kept in step by
    /// hand drift the first time either is touched, so there is one now.
    ///
    /// What it does NOT inherit is a comment's affordances. A caption is not
    /// something to reply to, block or report, and its counter is not a control
    /// — the post's like lives on the toolbar, and two places to like one post
    /// is one too many. Everything a comment can do is switched off here rather
    /// than left wired to a nil handler, so a stray tap cannot find it.
    func configureAsPostCaption(
        authorName: String,
        timestamp: String,
        caption: String,
        monogram: String,
        avatarURL: URL?,
        likeCount: Int64?,
        imagePipeline: ImagePipeline?
    ) {
        representedID = nil
        headerLabel.text = timestamp.isEmpty ? authorName : "\(authorName) · \(timestamp)"
        bodyLabel.text = caption
        avatarView.setMonogram(monogram)
        rowLeading?.constant = 0
        setCaptionLikeCount(likeCount)
        becomeCaption()
        loadAvatar(avatarURL, for: nil, using: imagePipeline)
    }

    /// The counter as a READING: the heart is quiet, the number is the post's,
    /// and an unknown count draws nothing at all rather than a nought.
    private func setCaptionLikeCount(_ count: Int64?) {
        var config = likeButton.configuration
        config?.image = UIImage(
            systemName: "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        config?.baseForegroundColor = .secondaryLabel
        if let count {
            var title = AttributedString(SnapSubtitleView.countText(Int(count)))
            title.font = UIFont.preferredFont(forTextStyle: .caption1)
            config?.attributedTitle = title
        } else {
            config?.attributedTitle = nil
        }
        likeButton.configuration = config
    }

    /// Switches off everything that belongs to a comment and not to a post.
    /// Idempotent: a recycled row re-runs it, and `prepareForReuse` undoes it.
    private func becomeCaption() {
        isCaption = true
        likeButton.isUserInteractionEnabled = false
        rowTapRecognizer?.isEnabled = false
        if let menu = contextMenu { removeInteraction(menu) }
    }

    /// Whether this row is standing in for the post rather than a comment.
    private var isCaption = false

    /// Cell recycling: drop the in-flight fetch, the picture, and the
    /// identity it belonged to. Called from `CommentCell.prepareForReuse`.
    func prepareForReuse() {
        avatarTask?.cancel()
        avatarTask = nil
        representedID = nil
        avatarImageView.image = nil
        // ⚠️ BACK TO A COMMENT. A row that stood in for a caption has its reply
        // tap, its menu and its like control switched off, and a recycled cell
        // that inherited that would be a comment nobody could interact with —
        // the tile-cell lesson applied to a row.
        if isCaption {
            isCaption = false
            likeButton.isUserInteractionEnabled = true
            rowTapRecognizer?.isEnabled = true
            if let contextMenu, !interactions.contains(where: { $0 === contextMenu }) {
                addInteraction(contextMenu)
            }
        }
        onAvatarTap = nil
        onLikeTap = nil
        onReplyTap = nil
        onShare = nil
        onBlock = nil
        onReport = nil
    }

    /// Fetches the picture and draws it over the monogram — off the main
    /// thread, and only if the row is still showing the comment it started
    /// for. Every failure path (no URL, cancelled, decode error, recycled
    /// row) simply leaves the monogram, which is already on screen.
    /// - Parameter id: the comment the fetch belongs to, or `nil` for the
    ///   caption, which is not one. The guard is the same either way: what a
    ///   recycled row must never do is paint a picture fetched for the row it
    ///   used to be.
    private func loadAvatar(_ url: URL?, for id: String?, using pipeline: ImagePipeline?) {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImageView.image = nil
        guard let url, let pipeline else { return }
        avatarTask = Task { [weak self] in
            let image = try? await pipeline.image(for: url)
            guard let self, let image, !Task.isCancelled, self.representedID == id else { return }
            self.avatarImageView.image = image
        }
    }

    @objc private func avatarTapped() { onAvatarTap?() }
    @objc private func rowTapped() { onReplyTap?() }

    /// Renders the like control's state: filled pink heart when liked,
    /// quiet outline otherwise; the counter shows only a real number
    /// (zero renders bare — no lying "0").
    func setLiked(_ liked: Bool, count: Int) {
        var config = likeButton.configuration
        config?.image = UIImage(
            systemName: liked ? "heart.fill" : "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        config?.baseForegroundColor = liked ? .systemPink : .secondaryLabel
        if count > 0 {
            var title = AttributedString(SnapSubtitleView.countText(count))
            title.font = UIFont.preferredFont(forTextStyle: .caption1)
            config?.attributedTitle = title
        } else {
            config?.attributedTitle = nil
        }
        likeButton.configuration = config
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // The picture overlays the disc and inherits its circle — the
        // monogram behind it is the permanent fallback, so an absent or
        // failed image is simply the disc, never a hole.
        avatarImageView.pin(to: avatarView)

        headerLabel.font = .preferredFont(forTextStyle: .footnote)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = .secondaryLabel
        headerLabel.numberOfLines = 1

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .label
        bodyLabel.numberOfLines = 0

        likeButton.configuration?.imagePadding = 3
        likeButton.configuration?.contentInsets = .zero
        // COUNT LEFT OF HEART: the button is trailing-anchored, so with
        // the glyph at the trailing edge the control grows LEFTWARD as
        // the counter appears or gains digits — the heart never shifts
        // off its anchor.
        likeButton.configuration?.imagePlacement = .trailing
        likeButton.accessibilityLabel = "Like comment"
        likeButton.addAction(UIAction { [weak self] _ in self?.onLikeTap?() }, for: .primaryActionTriggered)
        setLiked(false, count: 0)

        // [Name · Time][———— stretch ————][♥ count]: the header label is
        // the designated absorber (hugging floor), the like control is
        // rigid — the label's stretch IS the dynamic spacer, and the
        // control lands on the exact name/time axis at the far right.
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        likeButton.setContentHuggingPriority(.required, for: .horizontal)
        likeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let headerRow = UIStackView(arrangedSubviews: [headerLabel, likeButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = Spacing.sm

        let textStack = UIStackView(arrangedSubviews: [headerRow, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Metrics.avatarGap
        // Level-2 rows step in by the reply indent; level-1 rows fill the
        // width. The indent is the row's ONLY depth cue — same avatar,
        // same type — which is exactly the standard thread grammar. The
        // constraint is STORED, not baked: a reused row can switch depth.
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false

        let leading = row.leadingAnchor.constraint(equalTo: leadingAnchor)
        rowLeading = leading
        NSLayoutConstraint.activate([
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The disc sizes itself (MonogramAvatarView pins its own
            // diameter), so no width/height constraints belong here.
        ])
    }
}

/// The comment list's FIRST ROW: the post itself, drawn as the thread's first
/// message.
///
/// ```
///  ( )  Ava Moreau · 10 weeks                    ♥ 271
///       Weekend build log: rebuilt the pipeline…
///  ( )  Kenji Tanaka · 20m                       ♥ 3
///       Love this shot 🔥
/// ```
///
/// ⚠️ IT IS A `CommentRowView`, not something shaped like one. The caption has
/// been three things now — a Liquid Glass bubble beside an avatar, the gallery
/// card's flat content for text posts, and a bubble again with its own closing
/// line — and each of them existed to line up with the rows beneath it: same
/// avatar column, same header, same body inset, kept in step by hand. Sharing
/// the row deletes that whole class of drift, and it is also the design: the
/// post is the first message in its own thread, so it looks like one.
///
/// What it does not share is a comment's affordances — see
/// `CommentRowView.configureAsPostCaption`.
final class CaptionBubbleCell: UICollectionViewCell {
    private let row = CommentRowView()

    /// The avatar was tapped — the host pushes the author's profile.
    var onAvatarTap: (() -> Void)? {
        get { row.onAvatarTap }
        set { row.onAvatarTap = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // The inter-row breathing every other stream row uses.
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.lg),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.prepareForReuse()
    }

    /// Measures this row at the width the layout is actually going to give it,
    /// rather than at whatever width the cell happens to be carrying.
    ///
    /// THE RACE THIS CLOSES. A self-sizing cell is asked its height once, and
    /// on the feed's resting engagement it is asked early — the comments are
    /// installed into a feed cell from `willDisplay`, while the page is still
    /// arriving, so the container's width is not final. Measured against a
    /// too-wide box the caption is one line, and one line is the height the
    /// layout keeps: the row never grows back, and the label — which HAS the
    /// full string — renders as much of it as fits and clips the rest. That is
    /// the "clipped to one line, end of the text missing" report, and it
    /// reproduced about one launch in three.
    ///
    /// So the width comes from the ATTRIBUTES, which are authoritative, and the
    /// layout is forced through synchronously before measuring, so nothing
    /// downstream can hand back a cached one-line height.
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetWidth = layoutAttributes.frame.width
        guard targetWidth > 0 else {
            return super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        if abs(bounds.width - targetWidth) > 0.5 {
            bounds.size.width = targetWidth
        }
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let fitted = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // Ceil, not round: half a point short of the caption is a clipped
        // descender on the last line.
        layoutAttributes.frame.size.height = ceil(fitted.height)
        return layoutAttributes
    }

    /// Renders from what the FEED already knows, before this screen's own post
    /// fetch returns — enough for the row to exist, occupy its real height, and
    /// be somewhere a flight can aim at.
    ///
    /// The author travels too, and it has to: the row names its author, and a
    /// seeded row that showed an empty disc and no name until the fetch
    /// returned would be a hole in the object the reveal is carrying the eye
    /// to. The feed knows the name and the picture already.
    func configureSeed(
        caption: String, timestamp: String, authorName: String, monogram: String,
        avatarURL: URL?, likeCount: Int64?, imagePipeline: ImagePipeline?
    ) {
        row.configureAsPostCaption(
            authorName: authorName, timestamp: timestamp, caption: caption,
            monogram: monogram, avatarURL: avatarURL, likeCount: likeCount,
            imagePipeline: imagePipeline
        )
    }

    /// `likeCount` comes from the HOST, deliberately, and is not derived here.
    ///
    /// A `PostDetailDisplayModel` carries no engagement at all — the screen
    /// tracks it separately, because it moves: the viewer can like the post
    /// from the toolbar while this row is on screen. The host passes whichever
    /// number is currently true (the live one once the post has landed, the
    /// opener's until then), and `nil` when nobody has said.
    func configure(
        with model: PostDetailDisplayModel,
        imagePipeline: ImagePipeline?,
        likeCount: Int64? = nil
    ) {
        row.configureAsPostCaption(
            authorName: model.authorName, timestamp: model.timestampText,
            caption: model.caption, monogram: model.avatarMonogram,
            avatarURL: model.avatarURL, likeCount: likeCount,
            imagePipeline: imagePipeline
        )
    }
}


/// The stream's comment cell: ONE `CommentRowView`, built once and
/// reconfigured per dequeue.
///
/// It exists to give the row a real recycling lifecycle. The stream used to
/// tear every subview out of the cell and construct a fresh row on each
/// appearance, which meant a full view tree, two gesture recognizers, and a
/// context-menu interaction allocated on the main thread for every row that
/// scrolled past — and, with no `prepareForReuse` anywhere, no place to
/// cancel an avatar fetch that outlived its row.
final class CommentCell: UICollectionViewCell {
    let row = CommentRowView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // The inter-row breathing the old stack spacing provided.
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.lg),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.prepareForReuse()
    }
}

extension CommentRowView: UIGestureRecognizerDelegate {
    /// The row-tap filter: the reply trigger yields wherever a touch
    /// belongs to a control (the like button) or the avatar — their
    /// actions stay exclusive instead of firing alongside the reply.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.view === self else { return true }
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl || current === avatarView { return false }
            view = current.superview
        }
        return true
    }
}

extension CommentRowView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: "Share Comment",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in self?.onShare?() },
                UIAction(
                    title: "Block User",
                    image: UIImage(systemName: "hand.raised"),
                    attributes: .destructive
                ) { _ in self?.onBlock?() },
                UIAction(
                    title: "Report",
                    image: UIImage(systemName: "flag"),
                    attributes: .destructive
                ) { _ in self?.onReport?() },
            ])
        }
    }
}

/// A popular thread's fold seam, standing at reply depth so it reads as
/// part of the thread it toggles: "View N more replies… ∨" while
/// collapsed, "Hide replies ∧" while expanded — one row, two faces, the
/// inverse actions of the same fold.
final class CommentThreadToggleRow: UIView {
    enum Kind: Hashable {
        case expand(hidden: Int)
        case collapse
    }

    var onTap: (() -> Void)?
    /// The thread this seam folds — the host finds the surviving seam
    /// after a collapse re-render to keep the user's place.
    let parentID: String

    init(kind: Kind, parentID: String) {
        self.parentID = parentID
        super.init(frame: .zero)
        let label = UILabel()
        let chevronName: String
        switch kind {
        case .expand(let hidden):
            label.text = "View \(hidden) more \(hidden == 1 ? "reply" : "replies")…"
            chevronName = "chevron.down"
        case .collapse:
            label.text = "Hide replies"
            chevronName = "chevron.up"
        }
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let chevron = UIImageView(image: UIImage(
            systemName: chevronName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center

        let row = UIStackView(arrangedSubviews: [label, chevron])
        row.axis = .horizontal
        row.spacing = Spacing.xs
        row.alignment = .center
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CommentRowView.replyIndent
            ),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped() { onTap?() }
}

/// The comments stream's first-load skeleton row, assembled from the design
/// system's `SkeletonBoneView` — the MESSAGES screens' exact doctrine (one
/// window-coherent shimmer band, shared phase across every bone; see
/// `ChatSkeletons`): placeholder geometry reuses the real row's layout
/// constants (avatar size, indent, header/body stack recipe), and bone
/// widths cycle organic fractions so the stack reads as content hydrating,
/// not a repeated stamp.
final class CommentSkeletonRowView: UIView {
    private enum Metrics {
        static let headerHeight: CGFloat = 11
        static let bodyHeight: CGFloat = 13
        static let headerFractions: [CGFloat] = [0.38, 0.52, 0.33, 0.45]
        static let bodyFractions: [CGFloat] = [0.86, 0.58, 0.72, 0.94]
    }

    /// The trailing band the real row's like control (count + ♥) occupies.
    /// Skeletons only mimic ORGANIC content — avatar, name/time, body —
    /// so this band stays empty: no bone ever shimmers where the
    /// structural heart will stand.
    static let likeColumnReservation: CGFloat = 28

    init(index: Int) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        let avatar = SkeletonBoneView(rounding: .capsule)
        let header = SkeletonBoneView(rounding: .capsule)
        let body = SkeletonBoneView(rounding: .capsule)

        let textColumn = UIStackView(arrangedSubviews: [header, body])
        textColumn.axis = .vertical
        textColumn.spacing = 6
        textColumn.alignment = .leading

        let row = UIStackView(arrangedSubviews: [avatar, textColumn])
        row.alignment = .top
        row.spacing = Spacing.sm
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false

        let headerFraction = Metrics.headerFractions[index % Metrics.headerFractions.count]
        let bodyFraction = Metrics.bodyFractions[index % Metrics.bodyFractions.count]
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.likeColumnReservation),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            header.widthAnchor.constraint(equalTo: textColumn.widthAnchor, multiplier: headerFraction),
            body.heightAnchor.constraint(equalToConstant: Metrics.bodyHeight),
            body.widthAnchor.constraint(equalTo: textColumn.widthAnchor, multiplier: bodyFraction),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The comments-only stream's empty page: the app's shared `EmptyStateView`
/// as a list row, at a height it is TOLD rather than one it works out.
///
/// # Why a class of its own
/// `EmptyStateView` centres its block in whatever bounds it is given and has
/// no vertical intrinsic size, so the row's height is a decision, not a
/// measurement — and a decision made twice is a jump. This cell exists so
/// there is exactly one place that decision lands: `targetHeight` in, the
/// same number out of `preferredLayoutAttributesFitting`, every pass.
///
/// # The jump this ends
/// The height used to be seeded and then corrected against the collection
/// view's settled geometry. That geometry is not settled during the
/// engagement — the stream's bottom constraint moves to the view's bottom as
/// part of the transition, so the available height GROWS while the animation
/// runs. Recomputing on each layout meant the last recomputation landed as
/// the animation finished: the block rendered low and snapped up at the end.
///
/// The answer is not to recompute more carefully but to stop recomputing.
/// The height is resolved once, from geometry that is already final on frame
/// 0 (`PostDetailViewController.emptyPageHeight`), and this cell returns it
/// unchanged for the life of the configuration.
final class CommentsEmptyPageCell: UICollectionViewCell {
    private let empty = EmptyStateView()

    /// The row's height, decided by the owner. `preferredLayoutAttributesFitting`
    /// returns exactly this — never a self-sized alternative.
    private var targetHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        empty.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: contentView.topAnchor),
            empty.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(symbolName: String, title: String, subtitle: String, height: CGFloat) {
        targetHeight = max(0, height)
        empty.configure(symbolName: symbolName, title: title, subtitle: subtitle)
        // No implicit animation may attach to the setup pass: this runs
        // inside the engagement's animation block on the resting-engagement
        // path, and an animatable layout here is a block sliding into place
        // behind the transition.
        UIView.performWithoutAnimation {
            contentView.setNeedsLayout()
            contentView.layoutIfNeeded()
        }
    }

    /// The height, locked. Laid out synchronously first so what UIKit is
    /// handed on frame 0 is byte-identical to what the settled layout would
    /// produce — there is no second answer for a later pass to find.
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let width = layoutAttributes.frame.width
        UIView.performWithoutAnimation {
            if width > 0, abs(bounds.width - width) > 0.5 {
                bounds.size.width = width
            }
            contentView.setNeedsLayout()
            contentView.layoutIfNeeded()
        }
        layoutAttributes.frame.size.height = ceil(targetHeight)
        return layoutAttributes
    }
}
