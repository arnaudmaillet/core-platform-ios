import MediaCore
import DesignSystem
import FeedInterface
import UIKit

/// The stream's diffable identity space. Content is looked up at cell-
/// configure time (`streamModels`); identity is what animates.
private enum StreamSection: Hashable { case main }
private enum StreamItem: Hashable {
    case postSection
    case emptyState
    case skeletonPlaceholder(Int)
    case comment(String)
    case seam(CommentThreadToggleRow.Kind, parentID: String)
}

final class PostDetailViewController: UIViewController {
    private enum Metrics {
        static let avatarSize: CGFloat = 44
    }

    private let viewModel: PostDetailViewModel
    private let imagePipeline: ImagePipeline
    private let mode: PostDetailMode

    /// The stream surface: a compositional-list collection view driven by
    /// a diffable data source — thread folds and sort re-ranks land as
    /// NATIVE animated snapshot applies (insertions, deletions, moves),
    /// never manual view surgery. Still a UIScrollView underneath, so the
    /// engaged inset/keyboard machinery operates on it unchanged.
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            // The trailing inset carries the engaged rail exclusion — the
            // stream's rows end where the action rail's column begins.
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.lg,
                leading: Spacing.lg,
                bottom: Spacing.lg,
                trailing: Spacing.lg + (self?.railExclusion ?? 0)
            )
            return section
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.allowsSelection = false
        return view
    }()
    private var streamDataSource: UICollectionViewDiffableDataSource<StreamSection, StreamItem>!
    /// The engaged rail exclusion, read by the layout's section provider.
    private var railExclusion: CGFloat = 0
    /// Snapshot bookkeeping: the first apply lands without animation (a
    /// cold load has nothing to animate FROM); everything after — folds,
    /// sorts, submissions — animates natively.
    private var hasAppliedStream = false
    private var commentsLoaded = false
    private var streamModels: [String: CommentDisplayModel] = [:]
    /// The full-mode post section (header/media/engagement), built once
    /// and hosted by the stream's leading cell.
    private let postSectionHost = UIView()
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private let avatarView = UIView()
    private let avatarImageView = UIImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let captionLabel = UILabel()
    private let mediaView = UIImageView()
    private let timestampLabel = UILabel()
    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()

    private let commentsHeaderLabel = UILabel()
    private let composeBar = CommentsInputBar()

    private var mediaAspectConstraint: NSLayoutConstraint?
    private var composeBottomDefault: NSLayoutConstraint?
    private var composeBottomEngaged: [NSLayoutConstraint] = []
    private var scrollBottomDefault: NSLayoutConstraint?
    private var scrollBottomEngaged: NSLayoutConstraint?
    /// The engaged footer's wall-to-wall frost (replaced the gradient
    /// scrim): rows gliding under the input band stay visible but
    /// dissolve into the blur — the bottom half of the frame the header
    /// frost opens at the top, same material family. PROGRESSIVE: clear
    /// at the band's top edge, solid from `footerFrostSolidFraction`
    /// down to the window's bottom, so rows blend into the blur with no
    /// geometric seam (the mask re-frames itself when the keyboard grows
    /// the band). HIT-INERT (the frost type disables interaction): the
    /// band must never eat the bar's taps, the ✕, or the swipe pan.
    /// Effect nil until the engaged entrance IN A WINDOW (headless-CI
    /// doctrine); it rides the master spring via
    /// `setComposerEntranceState`, the one seam that already runs inside
    /// that animation block in both directions.
    private let composerBackdrop = ProgressiveFrostView(
        maskColors: [.clear, .black, .black],
        maskLocations: [0, NSNumber(value: Double(SnapCommentsLayout.footerFrostSolidFraction)), 1]
    )
    private var imageTasks: [Task<Void, Never>] = []
    /// The threaded stream as last loaded — kept so expansion re-renders
    /// without a refetch.
    private var latestComments: [CommentDisplayModel] = []
    /// Parents whose full reply pool is shown (the "view more" seam's
    /// state). Per-screen, like scroll position.
    private var expandedReplyParents: Set<String> = []
    /// The armed reply target: the THREAD PARENT's id (replying to a reply
    /// binds to its top-level parent — comment.v1's two-depth contract)
    /// plus the tapped author's name for the placeholder.
    private var replyTarget: (parentID: String, name: String)?

    init(viewModel: PostDetailViewModel, imagePipeline: ImagePipeline, mode: PostDetailMode = .full) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for task in imageTasks { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .commentsOnly ? "Comments" : "Post"
        view.backgroundColor = .systemBackground
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        viewModel.onCommentsChange = { [weak self] state in self?.renderComments(state) }
        viewModel.onComposingChange = { [weak self] composing in self?.renderComposing(composing) }
        render(.loading)
        viewModel.viewDidLoad()
    }

    @objc private func handleStreamTap() {
        view.endEditing(true)
    }

    // MARK: - Setup

    private func configureViews() {
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        // A bare tap on the stream retires the keyboard (the drag path
        // above already does; taps should match). Non-cancelling, so row
        // interactions and the cell-side arbitration see every touch
        // unchanged — and a no-op when nothing is editing.
        let keyboardDismissTap = UITapGestureRecognizer(target: self, action: #selector(handleStreamTap))
        keyboardDismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(keyboardDismissTap)
        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        configureStreamDataSource()
        configureComposeBar()
        // Scroll view fills above the compose bar, which tracks the keyboard.
        // The default bottom stops at the compose bar; the engaged context
        // swaps it for a full-bleed bottom (stored constraint) so the
        // stream glides BEHIND the footer.
        let scrollBottom = collectionView.bottomAnchor.constraint(equalTo: composeBar.topAnchor)
        scrollBottomDefault = scrollBottom
        collectionView.constrain(in: view) { parent in
            collectionView.topAnchor.constraint(equalTo: parent.topAnchor)
            collectionView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            collectionView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrollBottom
        }

        // Author row: avatar + name/handle, tappable → profile.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2
        avatarView.clipsToBounds = true
        monogramLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.pin(to: avatarView) // overlays the monogram once loaded

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel

        let nameStack = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        nameStack.axis = .vertical
        nameStack.spacing = 2
        let authorRow = UIStackView(arrangedSubviews: [avatarView, nameStack])
        authorRow.axis = .horizontal
        authorRow.alignment = .center
        authorRow.spacing = Spacing.md
        authorRow.isUserInteractionEnabled = true
        authorRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0

        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.backgroundColor = .tertiarySystemFill
        mediaView.contentMode = .scaleAspectFill

        timestampLabel.font = .preferredFont(forTextStyle: .footnote)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = .secondaryLabel

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.contentInsets = .zero
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in self?.viewModel.toggleLike() }, for: .primaryActionTriggered)
        likeCountLabel.font = .preferredFont(forTextStyle: .subheadline)
        likeCountLabel.textColor = .secondaryLabel
        let likeRow = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, UIView()])
        likeRow.axis = .horizontal
        likeRow.alignment = .center
        likeRow.spacing = Spacing.xs

        commentsHeaderLabel.text = "Comments"
        commentsHeaderLabel.font = .preferredFont(forTextStyle: .headline)
        commentsHeaderLabel.adjustsFontForContentSizeCategory = true
        commentsHeaderLabel.textColor = .label
        commentsHeaderLabel.isHidden = true

        // The post section (header/media/engagement + the inline comments
        // title), built once into the retained host — the stream's leading
        // cell adopts it in full mode; comments-only never lists the item.
        let postSectionStack = UIStackView(
            arrangedSubviews: [authorRow, captionLabel, mediaView, timestampLabel, likeRow, commentsHeaderLabel]
        )
        postSectionStack.axis = .vertical
        postSectionStack.spacing = Spacing.md
        postSectionStack.setCustomSpacing(Spacing.lg, after: likeRow)
        postSectionStack.translatesAutoresizingMaskIntoConstraints = false
        postSectionHost.addSubview(postSectionStack)
        NSLayoutConstraint.activate([
            postSectionStack.topAnchor.constraint(equalTo: postSectionHost.topAnchor),
            postSectionStack.leadingAnchor.constraint(equalTo: postSectionHost.leadingAnchor),
            postSectionStack.trailingAnchor.constraint(equalTo: postSectionHost.trailingAnchor),
            postSectionStack.bottomAnchor.constraint(equalTo: postSectionHost.bottomAnchor, constant: -Spacing.sm),
        ])

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])

        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @objc private func authorTapped() {
        viewModel.didTapAuthor()
    }

    private func configureComposeBar() {
        // The Liquid Glass composer (Private Messages' recipe): a floating
        // capsule field, no opaque bar, no separator — the glass carries
        // its own boundary against whatever is behind it.
        composeBar.onSend = { [weak self] text in
            guard let self else { return }
            // A sent reply must be visible where it lands: expand its
            // thread before the reload-driven re-render.
            if let target = self.replyTarget {
                self.expandedReplyParents.insert(target.parentID)
            }
            self.viewModel.submitComment(text, parentID: self.replyTarget?.parentID)
            self.clearReplyState()
        }
        // The reply state's natural exit: keyboard retired over an empty
        // field — later compositions start top-level again.
        composeBar.onIdleDismiss = { [weak self] in self?.clearReplyState() }
        // The engaged footer frost (hidden outside the engagement): below
        // the bar, above the stream.
        composerBackdrop.isHidden = true
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBackdrop)
        view.addSubview(composeBar)
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        // Tracks the keyboard; sits at the safe-area bottom when dismissed.
        // Stored: the engaged context replaces it (`setEngagedInsets`) —
        // there the composer must occupy the NATIVE FOOTER'S band, which
        // the safe area deliberately still contains.
        let bottom = composeBar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm
        )
        composeBottomDefault = bottom
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
            bottom,
            composerBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerBackdrop.topAnchor.constraint(
                equalTo: composeBar.topAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
        ])
    }

    /// Shapes the scrolling content for the snap feed's engaged layout:
    /// `top` is the frosted media strip's height — the scroll view itself
    /// spans the full cell (comments glide UNDER the strip), so the content
    /// rests below it via inset, not via frame; `trailing` reserves the
    /// action rail's exclusive column (zero overlap). The composer
    /// deliberately stays full-width: the rail's territory ends well above
    /// the footer.
    /// Wires the composer's close affordance (the engaged context's exit in
    /// the send slot while the field is empty). Also the switch that turns
    /// the close/send toggle ON — unwired (the pushed comments screen),
    /// the bar keeps a permanent send button.
    func setEngagedCloseHandler(_ handler: @escaping () -> Void) {
        composeBar.onClose = handler
    }

    /// Wires the composer's vertical swipe exit (+1 up / -1 down) — the
    /// engaged context's page-away from the footer band.
    func setEngagedSwipeHandler(_ handler: @escaping (Int) -> Void) {
        composeBar.onSwipeExit = handler
    }

    /// The composer's entrance state for the engaged footer handoff:
    /// offstage = invisible with a slight downward offset, so the unified
    /// spring doesn't just ghost it in — it physically slides into place
    /// (alpha + micro-translation together are what keep the crossfade
    /// against the fading native bar from reading as a double-exposure).
    /// Set offstage BEFORE the spring; animate to onstage INSIDE it.
    func setComposerEntranceState(offstage: Bool) {
        composeBar.alpha = offstage ? 0 : 1
        composeBar.transform = offstage
            ? CGAffineTransform(translationX: 0, y: SnapCommentsLayout.composerEntranceOffset)
            : .identity
        // The footer frost rides the same seam — this method already runs
        // inside the master spring in both directions, and the `effect`
        // property is the one supported animatable path for blur. Window-
        // guarded (real blurs contact the render server; headless CI test
        // hosts must never pay), and gated on the engaged context (the
        // backdrop stays hidden — and frost-free — on the pushed screen).
        if offstage {
            composerBackdrop.effect = nil
        } else if view.window != nil, !composerBackdrop.isHidden, composerBackdrop.effect == nil {
            composerBackdrop.effect = UIBlurEffect(style: .systemThinMaterialDark)
        }
    }

    func setEngagedInsets(top: CGFloat, trailing: CGFloat, bottomInset: CGFloat) {
        // The strip inset is the ONLY top authority in the engaged context:
        // the full-cell scroll view would otherwise also inherit the safe
        // area's automatic adjustment and double-inset the resting position.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = max(0, top)
        collectionView.verticalScrollIndicatorInsets.top = max(0, top)
        collectionView.contentOffset = CGPoint(x: 0, y: -max(0, top))
        // A clean minimal stream: no indicator (engaged context only — the
        // pushed comments screen keeps its native affordance).
        collectionView.showsVerticalScrollIndicator = false
        // TOTAL immersion: the stream spans the full height and glides
        // BEHIND the footer too — the scroll's bottom swaps from the
        // compose bar's top to the view's bottom, with a bottom inset so
        // resting content still clears the footer band. The frost keeps
        // the bar legible over the moving rows.
        scrollBottomDefault?.isActive = false
        if scrollBottomEngaged == nil {
            scrollBottomEngaged = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        scrollBottomEngaged?.isActive = true
        collectionView.contentInset.bottom = max(0, bottomInset) + 62
        composerBackdrop.isHidden = false
        // Z-ORDER, load-bearing: the scroll view is added AFTER the compose
        // bar at build time (harmless while it ended at the bar's top), so
        // at full height it would sit ABOVE the footer and swallow every
        // touch in the band — taps, the ✕, the swipe pan (found via hit
        // logging: bar frame contained the point, a CommentRowView won).
        // The footer must cap the stack in the engaged context.
        view.bringSubviewToFront(composerBackdrop)
        view.bringSubviewToFront(composeBar)
        // The rail exclusion feeds the list layout's section insets — the
        // stream's rows end where the action rail's column begins.
        railExclusion = max(0, trailing)
        collectionView.collectionViewLayout.invalidateLayout()

        // The composer OCCUPIES THE NATIVE FOOTER'S BAND: the feed keeps
        // its toolbar structurally present for the whole engagement (the
        // safe area must never move — that's the zero-churn contract), so
        // the resting position anchors to the WINDOW's home-indicator
        // inset (`bottomInset`, toolbar-independent) instead of the safe
        // area. The keyboard keeps priority through the inequality: when
        // it rises, the required constraint lifts the bar above it.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        composeBottomDefault?.isActive = false
        NSLayoutConstraint.deactivate(composeBottomEngaged)
        let keyboard = composeBar.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm
        )
        let rest = composeBar.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -(max(0, bottomInset) + Spacing.sm)
        )
        rest.priority = .defaultHigh
        composeBottomEngaged = [keyboard, rest]
        NSLayoutConstraint.activate(composeBottomEngaged)
    }

    // MARK: - Render

    private func render(_ phase: PostDetailViewModel.Phase) {
        switch phase {
        case .loading:
            statusLabel.isHidden = true
            if mode == .commentsOnly {
                // The skeleton stream IS the loading state (the messages
                // doctrine) — no spinner, no hidden surface.
                spinner.stopAnimating()
                collectionView.isHidden = false
                if !hasAppliedStream { applyStream(animated: false) }
            } else {
                if !refreshControl.isRefreshing { spinner.startAnimating() }
                collectionView.isHidden = true
            }
        case .content(let model):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            collectionView.isHidden = false
            configure(model)
        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            collectionView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }

    private func configure(_ model: PostDetailDisplayModel) {
        monogramLabel.text = model.avatarMonogram
        nameLabel.text = model.authorName
        handleLabel.text = model.handle
        captionLabel.text = model.caption
        captionLabel.isHidden = !model.hasCaption
        timestampLabel.text = model.timestampText

        mediaView.isHidden = !model.hasMedia
        mediaAspectConstraint?.isActive = false
        if model.hasMedia {
            let constraint = mediaView.heightAnchor.constraint(
                equalTo: mediaView.widthAnchor,
                multiplier: 1 / max(0.5, model.mediaAspectRatio)
            )
            constraint.isActive = true
            mediaAspectConstraint = constraint
        }

        loadAvatar(model.avatarURL)
        loadMedia(model.mediaURL)
    }

    private func renderEngagement(_ state: PostDetailViewModel.EngagementState) {
        likeCountLabel.text = state.likeCount > 0 ? "\(state.likeCount)" : ""
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .secondaryLabel
        likeButton.configuration = config
    }

    private func renderComments(_ state: PostDetailViewModel.CommentsState) {
        // Comments-only contexts already carry a "Comments" title (the nav
        // bar when pushed, the panel header when sheeted) — the inline
        // section header would duplicate it.
        commentsHeaderLabel.isHidden = mode == .commentsOnly
        guard case .loaded(let models) = state else { return }
        latestComments = models
        streamModels = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commentsLoaded = true
        // The first apply lands cold (nothing to animate FROM); reloads,
        // sort re-ranks, and submissions animate as native diffs — moves,
        // insertions, deletions, all UIKit's own.
        applyStream(animated: hasAppliedStream)
    }

    // MARK: - Stream data source

    private func configureStreamDataSource() {
        let postCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            self.postSectionHost.removeFromSuperview()
            self.postSectionHost.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(self.postSectionHost)
            NSLayoutConstraint.activate([
                self.postSectionHost.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                self.postSectionHost.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                self.postSectionHost.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                self.postSectionHost.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
        }
        let commentCell = UICollectionView.CellRegistration<UICollectionViewCell, String> {
            [weak self] cell, _, commentID in
            guard let self else { return }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            guard let model = self.streamModels[commentID] else { return }
            let row = self.makeCommentRow(model)
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                // The old stack's inter-row breathing, as cell padding.
                row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        let seamCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> {
            [weak self] cell, _, item in
            guard let self, case .seam(let kind, let parentID) = item else { return }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let seam = self.makeSeamRow(kind: kind, parentID: parentID)
            seam.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(seam)
            NSLayoutConstraint.activate([
                seam.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                seam.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                seam.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                seam.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, index in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let row = CommentSkeletonRowView(index: index)
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> { cell, _, _ in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let empty = UILabel()
            empty.text = "No comments yet. Be the first."
            empty.font = .preferredFont(forTextStyle: .subheadline)
            empty.adjustsFontForContentSizeCategory = true
            empty.textColor = .secondaryLabel
            empty.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                empty.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: cell.contentView.trailingAnchor),
                empty.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
        }
        streamDataSource = UICollectionViewDiffableDataSource<StreamSection, StreamItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .postSection:
                return collectionView.dequeueConfiguredReusableCell(using: postCell, for: indexPath, item: item)
            case .emptyState:
                return collectionView.dequeueConfiguredReusableCell(using: emptyCell, for: indexPath, item: item)
            case .skeletonPlaceholder(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonCell, for: indexPath, item: index)
            case .comment(let id):
                return collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: id)
            case .seam:
                return collectionView.dequeueConfiguredReusableCell(using: seamCell, for: indexPath, item: item)
            }
        }
    }

    private func streamItems() -> [StreamItem] {
        var items: [StreamItem] = []
        if mode == .full { items.append(.postSection) }
        guard commentsLoaded else {
            // The initial fetch renders as a skeleton stream (the
            // messages screens' doctrine — shimmering placeholder rows,
            // never a spinner); hydration cross-dissolves into the same
            // row geometry via the diffable apply. The count is VIEWPORT
            // MATH, not a constant: enough rows to cover this device's
            // height down to the input bar (the list clips the excess),
            // so no form factor — SE, Pro Max, iPad — strands blank
            // space under a too-short shimmer block.
            let viewport = collectionView.bounds.height > 0
                ? collectionView.bounds.height
                : view.bounds.height
            let count = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: viewport)
            items.append(contentsOf: (0..<count).map(StreamItem.skeletonPlaceholder))
            return items
        }
        guard !latestComments.isEmpty else {
            items.append(.emptyState)
            return items
        }
        for item in CommentThreadPresentation.items(from: latestComments, expanded: expandedReplyParents) {
            switch item {
            case .comment(let model):
                items.append(.comment(model.id))
            case .viewMoreReplies(let parentID, let hiddenCount):
                items.append(.seam(.expand(hidden: hiddenCount), parentID: parentID))
            case .collapseReplies(let parentID):
                items.append(.seam(.collapse, parentID: parentID))
            }
        }
        return items
    }

    private func applyStream(animated: Bool, completion: (() -> Void)? = nil) {
        var snapshot = NSDiffableDataSourceSnapshot<StreamSection, StreamItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(streamItems())
        hasAppliedStream = true
        streamDataSource.apply(snapshot, animatingDifferences: animated) { completion?() }
    }

    /// The engaged toolbar's sort selector lands here — the view model
    /// re-ranks the data and the diffable apply animates the moves.
    func setCommentSortOrder(_ order: SnapCommentSortButton.Order) {
        viewModel.setCommentSort(order == .trending ? .trending : .recent)
    }

    /// The fold opening: one snapshot apply — UIKit animates the row
    /// insertions natively.
    private func expandThread(_ parentID: String) {
        expandedReplyParents.insert(parentID)
        applyStream(animated: true)
    }

    /// The fold's inverse: the deletions animate natively, then the
    /// surviving view-more seam is scrolled back into the viewport if the
    /// fold pulled it out (keep-place).
    private func collapseThread(_ parentID: String) {
        expandedReplyParents.remove(parentID)
        applyStream(animated: true) { [weak self] in
            guard let self else { return }
            let items = self.streamDataSource.snapshot().itemIdentifiers
            guard let index = items.firstIndex(where: { item in
                if case .seam(_, let id) = item { return id == parentID }
                return false
            }) else { return }
            let indexPath = IndexPath(item: index, section: 0)
            if let attributes = self.collectionView.layoutAttributesForItem(at: indexPath) {
                self.collectionView.scrollRectToVisible(
                    attributes.frame.insetBy(dx: 0, dy: -60), animated: true
                )
            }
        }
    }

    private func makeCommentRow(_ model: CommentDisplayModel) -> CommentRowView {
        let row = CommentRowView(model: model)
        row.onAvatarTap = { [weak self] in
            self?.viewModel.didTapCommentAuthor(commentID: model.id)
        }
        row.onReplyTap = { [weak self] in self?.enterReplyState(for: model) }
        row.onShare = { [weak self] in self?.presentCommentShare(model) }
        // Moderation seams: the menu is the honest affordance; the
        // block/report mutations wait on a moderation backend (the
        // repost/save posture).
        row.onBlock = nil
        row.onReport = nil
        // Like truth lives in the VIEW MODEL (Trending weighs it); the
        // row updates in place — re-ranking waits for the next sort or
        // reload, never yanking the row from under the finger.
        let liked = viewModel.isCommentLiked(model.id)
        row.setLiked(liked, count: liked ? 1 : 0)
        row.onLikeTap = { [weak self, weak row] in
            guard let self else { return }
            let nowLiked = self.viewModel.toggleCommentLike(commentID: model.id)
            row?.setLiked(nowLiked, count: nowLiked ? 1 : 0)
        }
        return row
    }

    private func makeSeamRow(kind: CommentThreadToggleRow.Kind, parentID: String) -> CommentThreadToggleRow {
        let seam = CommentThreadToggleRow(kind: kind, parentID: parentID)
        switch kind {
        case .expand:
            seam.onTap = { [weak self] in self?.expandThread(parentID) }
        case .collapse:
            seam.onTap = { [weak self] in self?.collapseThread(parentID) }
        }
        return seam
    }

    /// Row tapped: the composer arms its reply state — placeholder names
    /// the tapped author, the payload binds to the THREAD parent, and the
    /// keyboard rises into the field.
    private func enterReplyState(for model: CommentDisplayModel) {
        replyTarget = (parentID: model.parentID ?? model.id, name: model.authorName)
        composeBar.setReplyPlaceholder(name: model.authorName)
        composeBar.focusComposer()
    }

    private func clearReplyState() {
        replyTarget = nil
        composeBar.setReplyPlaceholder(name: nil)
    }

    private func presentCommentShare(_ model: CommentDisplayModel) {
        let sheet = UIActivityViewController(
            activityItems: ["\(model.authorName): \(model.body)"],
            applicationActivities: nil
        )
        present(sheet, animated: true)
    }

    private var didCascadeComments = false

    private func renderComposing(_ composing: Bool) {
        composeBar.isSending = composing
    }

    // MARK: - Images

    private func loadAvatar(_ url: URL?) {
        avatarImageView.image = nil
        guard let url else { return }
        let pipeline = imagePipeline
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            self?.avatarImageView.image = image
        })
    }

    private func loadMedia(_ url: URL?) {
        guard let url else { return }
        let pipeline = imagePipeline
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            self?.mediaView.image = image
        })
    }
}

