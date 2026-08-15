import MediaCore
import DesignSystem
import FeedInterface
import ProfileInterface
import UIKit

/// The stream's diffable identity space. Content is looked up at cell-
/// configure time (`streamModels`); identity is what animates.
private enum StreamSection: Hashable { case main }
private enum StreamItem: Hashable {
    case postSection
    /// The post's caption, as the list's first row — a message bubble in
    /// the thread rather than a fixed header above it.
    case caption
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
    /// Builds the composer avatar's profile switcher menu. Nil on the pushed
    /// comments screen and wherever the app wires none — the face is then a
    /// plain, inert identity.
    private let profileSwitcher: (any ProfileSwitcherPresenting)?
    /// Watches for profile switches made ANYWHERE — this composer's menu, or
    /// the profile header while the comments sit open underneath.
    private let activeProfileObservers = NotificationObserverTokenBag()

    /// The stream surface: a compositional-list collection view driven by
    /// a diffable data source — thread folds and sort re-ranks land as
    /// NATIVE animated snapshot applies (insertions, deletions, moves),
    /// never manual view surgery. Still a UIScrollView underneath, so the
    /// engaged inset/keyboard machinery operates on it unchanged.
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            // Symmetric margins: the stream owns the full width. (The
            // trailing inset used to carry an exclusion for the shortcut
            // rail's column; the engagement fades the rail now, so there is
            // no column to leave clear.)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.lg,
                leading: Spacing.lg,
                bottom: Spacing.lg,
                trailing: Spacing.lg
            )
            return section
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.allowsSelection = false
        return view
    }()
    private var streamDataSource: UICollectionViewDiffableDataSource<StreamSection, StreamItem>!
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
    /// The engaged footer's frost: rows gliding behind the composer stay
    /// visible but dissolve into a LIGHT blur, so the bar reads over them
    /// without the band reading as an overlay on the post. Clear at the
    /// band's top edge, full material by the composer's top, solid to the
    /// screen's bottom; the mask re-frames itself when the keyboard grows
    /// the band. HIT-INERT: it must never eat the bar's taps or the swipe
    /// pan. Effect nil until the engaged entrance IN A WINDOW; it rides the
    /// master spring via `setComposerEntranceState`.
    private let composerBackdrop = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: [0, 0.5, 1],
        topRampLength: SnapCommentsLayout.footerFrostLead
    )
    private var imageTasks: [Task<Void, Never>] = []
    /// The threaded stream as last loaded — kept so expansion re-renders
    /// without a refetch.
    private var latestComments: [CommentDisplayModel] = []
    /// The post as last rendered — the caption row's model, kept so a
    /// snapshot re-apply can rebuild item #0 without a refetch.
    private var latestPost: PostDetailDisplayModel?
    /// The caption the opener already had, used until this screen's own post
    /// load returns.
    ///
    /// The caption row is the stream's first item and it existed only once the
    /// POST had loaded — which is a network round trip after the panel mounts.
    /// For a hero flight that is far too late: the row the card is supposed to
    /// land its caption ON did not exist while the card was in the air, so the
    /// flight had no target and the caption appeared as a second one when the
    /// post arrived.
    private var seededCaption: (text: String, timestamp: String)?
    /// Parents whose full reply pool is shown (the "view more" seam's
    /// state). Per-screen, like scroll position.
    private var expandedReplyParents: Set<String> = []
    /// The armed reply target: the THREAD PARENT's id (replying to a reply
    /// binds to its top-level parent — comment.v1's two-depth contract)
    /// plus the tapped author's name for the placeholder.
    private var replyTarget: (parentID: String, name: String)?

    init(
        viewModel: PostDetailViewModel,
        imagePipeline: ImagePipeline,
        mode: PostDetailMode = .full,
        profileSwitcher: (any ProfileSwitcherPresenting)? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.mode = mode
        self.profileSwitcher = profileSwitcher
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for task in imageTasks { task.cancel() }
    }

    /// Rows re-measure on a genuine WIDTH change — rotation, iPad size
    /// classes. Nothing here touches the empty page's HEIGHT: that is
    /// resolved once at configuration time and deliberately never revisited
    /// per layout, because a height that changes after frame 0 is the jump.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        remeasureStreamOnWidthChange()
    }

    /// The width the stream's self-sizing rows were last measured against.
    private var lastMeasuredStreamWidth: CGFloat = 0

    /// Re-measures every row when the stream's width changes.
    ///
    /// Self-sizing rows are measured once, at whatever width the list has
    /// when they are configured — and on the feed's RESTING engagement that
    /// is a width the container has not finished resolving, because the
    /// comments are installed into a cell from `willDisplay` while the page
    /// is still arriving. The caption row got measured narrow, kept the
    /// height that came out of it, and its label — tail-truncating by
    /// default — ended a three-line caption in an ellipsis on line one. The
    /// same run measured 58pt one launch and 33.67pt the next, which is the
    /// tell: nothing was wrong with the text, only with WHEN it was asked.
    ///
    /// Nothing re-asked, because a compositional list does not re-measure
    /// self-sizing content on a bounds change by itself. This does, once per
    /// genuine width change — so rotation and the iPad's size classes are
    /// covered by the same line.
    private func remeasureStreamOnWidthChange() {
        let width = collectionView.bounds.width
        guard width > 0, abs(width - lastMeasuredStreamWidth) > 0.5 else { return }
        let isFirst = lastMeasuredStreamWidth == 0
        lastMeasuredStreamWidth = width
        // The very first width is not a CHANGE — the rows have not been
        // measured against anything yet, and re-applying inside the first
        // layout pass would fight the apply that is putting them there.
        guard !isFirst, hasAppliedStream else { return }
        remeasureStream()
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
        viewModel.onViewerIdentityChange = { [weak self] identity in
            guard let self else { return }
            composeBar.setViewerIdentity(identity, imagePipeline: imagePipeline)
        }
        configureProfileSwitcher()
        render(.loading)
        viewModel.viewDidLoad()
    }

    /// Arms the composer avatar's profile switcher.
    ///
    /// Two independent halves, and the observer is the one that matters:
    ///
    ///  • The MENU is built from the switcher's pre-formatted rows, which
    ///    need one async `reload()` first. `makeMenu` is then synchronous, so
    ///    the menu opens fully rendered on its first frame.
    ///  • The OBSERVER adopts whatever profile becomes active, whether the
    ///    switch came from this menu or from the profile header with the
    ///    comments still open. Listening to the broadcast rather than to the
    ///    menu's own callback is what keeps the composer's face and the
    ///    identity that posts the comment from drifting apart.
    private func configureProfileSwitcher() {
        activeProfileObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: .activeProfileDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                guard let id = ActiveProfileChange.profileID(from: notification) else { return }
                MainActor.assumeIsolated { self?.viewModel.adoptActiveViewer(id) }
            },
        ]

        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            composeBar.setProfileMenu(profileSwitcher.makeMenu(
                // Adding a profile is the Profile feature's flow and this
                // composer has no route to it, so the row is omitted rather
                // than shown inert.
                includesAddProfile: false,
                // The switch itself lands through the notification above;
                // rebuilding here only re-marks which row is active, so the
                // menu is correct the NEXT time it opens.
                onSwitch: { [weak self] in self?.refreshProfileMenu() },
                onAddProfile: {}
            ))
        }
    }

    private func refreshProfileMenu() {
        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            composeBar.setProfileMenu(profileSwitcher.makeMenu(
                includesAddProfile: false,
                onSwitch: { [weak self] in self?.refreshProfileMenu() },
                onAddProfile: {}
            ))
        }
    }

    @objc private func handleStreamTap() {
        view.endEditing(true)
    }

    // MARK: - Setup

    private func configureViews() {
        // The comment list BOUNCES, and the bounce is the transition's
        // driver: past the top, `contentOffset` IS the pull, rubber-banded
        // by UIKit's own curve, so the fade and the overscroll cannot drift
        // out of step — they are the same number. (Locking the offset and
        // reading the pan instead was the previous shape; it worked, but the
        // content sat frozen while the layer moved, which read as two
        // surfaces rather than one.)
        //
        // It keeps NO refresh control, though: that competed for the same
        // gesture outright. The PUSHED POST screen (`.full`, the `.post`
        // deep link) is a different surface with no layout to collapse to —
        // it keeps its refresh.
        let isCommentList = mode == .commentsOnly
        collectionView.alwaysBounceVertical = true
        collectionView.bounces = true
        collectionView.keyboardDismissMode = .interactive
        // A bare tap on the stream retires the keyboard (the drag path
        // above already does; taps should match). Non-cancelling, so row
        // interactions and the cell-side arbitration see every touch
        // unchanged — and a no-op when nothing is editing.
        let keyboardDismissTap = UITapGestureRecognizer(target: self, action: #selector(handleStreamTap))
        keyboardDismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(keyboardDismissTap)
        if !isCommentList {
            refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
        }
        // With bouncing back on, the overshoot itself is the signal — the
        // scroll delegate reports it continuously, during the drag AND
        // through the spring-back, which is what makes the cancel free.
        collectionView.delegate = self
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
        // The engaged footer band (hidden outside the engagement): below
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
            // The band starts ABOVE the composer by the lead, so its ramp
            // is finished — full material — by the time it reaches the
            // capsule's top edge. Anchored to the composer, so it rides the
            // keyboard with it.
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

    /// Wires the INTERACTIVE pull-down dismissal: dragging the list down
    /// from its top drives the collapse under the finger. The list forwards
    /// each phase with the raw downward translation and release velocity;
    /// the host renders the progress and decides, on release, whether to
    /// finish or spring back. Left unwired by text posts (whose engagement
    /// is permanent) and by the pushed comments screen — nil makes the
    /// gesture a plain scroll.
    func setPullDismissDriveHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, _ translation: CGFloat, _ velocity: CGFloat) -> Void
    ) {
        onPullDismissDrive = handler
    }
    private var onPullDismissDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?
    /// Set once a released pull has committed, so the spring-back that
    /// follows cannot drive the transition backwards over the dismissal
    /// already in flight.
    private var isCommittingPullDismiss = false
    /// Whether the gesture in flight is allowed to drive the dismissal —
    /// armed only when the drag PHYSICALLY BEGAN at the top.
    ///
    /// It outlives the drag on purpose: a released pull that fell short
    /// springs home, and the transition has to ride that bounce back to
    /// rest before disarming, or it would freeze mid-fade.
    private var isPullDismissArmed = false

    /// Wires the composer's INTERACTIVE page-swipe — the bar forwards each
    /// pan phase (began/changed/ended) with the raw vertical translation and
    /// velocity, and the host drives the feed pager's `contentOffset` in
    /// real time (finger-linked paging), settling on release.
    func setEngagedPageSwipeHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void
    ) {
        composeBar.onPageSwipe = handler
    }

    /// The STREAM's shrink for the engagement, 0 (engaged) → 1 (dismissed).
    ///
    /// It scales the list and nothing else. The composer and the footer's
    /// blur band are siblings of the list, not children, so they hold their
    /// size and position at the screen's edge while the content pulls away —
    /// which is the whole point: a band that scales stops being chrome and
    /// starts being part of the moving layer.
    func setStreamTransitionProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        let scale = 1 + (SnapCommentsLayout.streamEntranceScale - 1) * t
        collectionView.transform = CGAffineTransform(scaleX: scale, y: scale)
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
        // The footer band rides the same seam — this already runs inside the
        // master spring both ways, and `effect` is the one animatable path
        // for a material. Window-guarded (headless CI never pays for a real
        // blur) and gated on the engaged context (the pushed screen has no
        // band).
        if offstage {
            composerBackdrop.effect = nil
        } else if view.window != nil, !composerBackdrop.isHidden, composerBackdrop.effect == nil {
            composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    /// The stream's two moving parts, driven by Core Animation directly
    /// rather than inside a `UIView.animate` block. Symmetric: the exit runs
    /// the same three animations towards the offstage pose.
    ///
    /// Model values are set FIRST and unanimated (so the settled state is
    /// correct even if the animation is removed), then one explicit
    /// animation per property carries the eye from where it actually was.
    /// `presentation()` rather than the model value as the start, so an
    /// interrupted entrance continues from what is on screen instead of
    /// snapping back.
    func animateEngagedTransition(toEngaged engaged: Bool, duration: TimeInterval) {
        let stream = collectionView.layer
        let bar = composeBar.layer
        let fromStream = (stream.presentation() ?? stream).transform
        let fromBarOpacity = (bar.presentation() ?? bar).opacity
        let fromBarTransform = (bar.presentation() ?? bar).transform

        UIView.performWithoutAnimation {
            setStreamTransitionProgress(engaged ? 0 : 1)
            setComposerEntranceState(offstage: !engaged)
        }

        addEntranceAnimation(stream, "transform", from: fromStream, to: stream.transform, duration: duration)
        addEntranceAnimation(bar, "opacity", from: fromBarOpacity, to: bar.opacity, duration: duration)
        addEntranceAnimation(bar, "transform", from: fromBarTransform, to: bar.transform, duration: duration)
    }

    private func addEntranceAnimation(
        _ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: TimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "comments-engage-\(keyPath)")
    }

    /// Materializes the footer band's blur AHEAD of the engagement — the
    /// composer's half of `SnapFeedCell.prematerializeEngagedChrome`, and the
    /// same reasoning: build the material while nothing is moving.
    ///
    /// Called after the offstage pose, which nils the effect; the entrance
    /// then finds it already built and skips.
    func prematerializeComposerChrome() {
        guard view.window != nil, !composerBackdrop.isHidden,
              composerBackdrop.effect == nil else { return }
        composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
    }

    /// Extra bottom room so resting content clears the composer band.
    private static let engagedFooterClearance: CGFloat = 62

    /// Freezes the comment stream for the length of a gesture that owns the
    /// screen — a dismissal swipe.
    ///
    /// The stream is a `UIScrollView`, and a full-surface pan lives on the
    /// feed's view ABOVE it, so the two recognise simultaneously: a swipe with
    /// any vertical component scrolled the comments while the page slid away
    /// under the finger. Freezing here rather than vetoing in the pan's
    /// delegate because the stream's own pan may already have begun — a
    /// begin-time veto cannot stop a recognizer that is already running, but a
    /// disabled scroll view stops dead.
    ///
    /// Restores the value that was there rather than assuming `true`: the
    /// stream is also frozen by the resting engagement's settle lock, and a
    /// gesture that ended inside that window must not thaw it early.
    /// Whether the stream rests at its very top — the one place a downward
    /// drag has nothing left to scroll, which is where a RESTING page's
    /// vertical slide-to-dismiss may claim the touch instead (the sheet
    /// idiom; see `SnapFeedViewController.zoomVerticalDismissalPermitted`).
    /// Same top test the pull-dismiss arming uses.
    var streamIsAtTop: Bool {
        collectionView.contentOffset.y <= -collectionView.contentInset.top + 0.5
    }

    func setStreamScrollEnabled(_ enabled: Bool) {
        if enabled { streamLock.thaw(collectionView) } else { streamLock.freeze(collectionView) }
    }

    /// Held for the length of a dismissal gesture. See `ScrollLock` for why
    /// this restores rather than enables.
    private var streamLock = ScrollLock()

    func setEngagedInsets(top: CGFloat, bottomInset: CGFloat) {
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
        collectionView.contentInset.bottom = max(0, bottomInset) + Self.engagedFooterClearance
        // Recorded so the empty page can be sized against the SETTLED
        // geometry on frame 0 — the stream is still growing into these
        // numbers while the transition runs.
        engagedStreamInsets = (
            top: max(0, top),
            bottom: max(0, bottomInset) + Self.engagedFooterClearance
        )
        composerBackdrop.isHidden = false
        // Z-ORDER, load-bearing: the scroll view is added AFTER the compose
        // bar at build time (harmless while it ended at the bar's top), so
        // at full height it would sit ABOVE the footer and swallow every
        // touch in the band — taps, the ✕, the swipe pan (found via hit
        // logging: bar frame contained the point, a CommentRowView won).
        // The footer must cap the stack in the engaged context.
        view.bringSubviewToFront(composerBackdrop)
        view.bringSubviewToFront(composeBar)

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
        // Retained for the caption row: the stream's first item renders from
        // this, and a re-render must not have to go back to the view model.
        let hadCaption = latestPost?.hasCaption == true
        latestPost = model
        // The footer band's veil, from the post's own format — the model
        // already knows, so this needs no signal from the host.
        composerBackdrop.setVeilOpacity(
            SnapCommentsLayout.frostVeilOpacity(hasMedia: model.hasMedia)
        )
        if mode == .commentsOnly, model.hasCaption != hadCaption || hasAppliedStream {
            // The apply that FIRST introduces the caption row lands without
            // animation, even though the stream has been applied before.
            //
            // Diffable animates an insertion by fading the cell in, and the
            // caption cell is a `UIVisualEffectView` — alpha on an effect
            // view is unsupported and renders the material as a flat opaque
            // grey for the fade's duration. That is the "bubble loads dark
            // then flashes light" report: measured #8F8F8F → #A7A7A7 →
            // #AEAEAE → #FCFCFC, an alpha ramp, while the glass logged
            // `.light` at every step. The appearance was never wrong — the
            // row was being faded in.
            //
            // There is nothing to animate FROM in any case: the caption is
            // the post's own content arriving, exactly like the cold load
            // the first apply already lands unanimated.
            applyStream(animated: Self.animatesStreamApply(
                hasAppliedStream: hasAppliedStream,
                introducesCaption: model.hasCaption && !hadCaption
            ))
        }
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

    /// Renders the caption row NOW, from what the opener already knows.
    ///
    /// The row is the stream's first item and it existed only once the POST had
    /// loaded — a network round trip after the panel mounts — so a text page
    /// opened from the feed showed its comments before its own caption, and the
    /// caption dropped in afterwards. The feed already holds the caption and
    /// the timestamp, so it hands them over at mount and the real post replaces
    /// the row later with the same text, moving nothing.
    func seedCaption(_ text: String, timestamp: String) {
        guard mode == .commentsOnly, !text.isEmpty, latestPost == nil else { return }
        seededCaption = (text, timestamp)
        loadViewIfNeeded()
        applyStream(animated: false)
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
        // The cell owns its row for its whole life; this only re-points it.
        // No subview teardown, no view construction, no recognizer or
        // interaction allocation per dequeue — the scroll path does layout
        // and text, and nothing else.
        let commentCell = UICollectionView.CellRegistration<CommentCell, String> {
            [weak self] cell, _, commentID in
            guard let self, let model = self.streamModels[commentID] else { return }
            self.configureCommentRow(cell.row, with: model)
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
        // COMMENTS-ONLY gets the app's shared empty PAGE; the full post
        // detail keeps a one-line note. The difference is what the surface
        // is: with the post above it the comments are a SECTION, and a
        // centred illustration block inside a section reads as a broken
        // layout — but in comments-only the comments ARE the page, so its
        // emptiness is the page's emptiness, and that is exactly what
        // `EmptyStateView` is for.
        let mode = mode
        // COMMENTS-ONLY gets the app's shared empty PAGE; the full post
        // detail keeps a one-line note. The difference is what the surface
        // is: with the post above it the comments are a SECTION, and a
        // centred illustration block inside a section reads as a broken
        // layout — but in comments-only the comments ARE the page, so its
        // emptiness is the page's emptiness, and that is exactly what
        // `EmptyStateView` is for.
        let emptyNoteCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> { cell, _, _ in
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
        // The height is decided HERE, once, from geometry that is already
        // final on frame 0 — `CommentsEmptyPageCell` then returns it
        // unchanged for the life of the configuration. Nothing recomputes
        // it later, which is what stops the block moving at the end of the
        // presentation.
        let emptyPageCell = UICollectionView.CellRegistration<CommentsEmptyPageCell, StreamItem> {
            [weak self] cell, _, _ in
            cell.configure(
                symbolName: "bubble.left.and.bubble.right",
                title: SnapCommentEmptyStateView.promptText,
                subtitle: "Be the first to comment.",
                height: self?.emptyPageHeight() ?? SnapCommentsLayout.emptyPageMinimumHeight
            )
        }
        let captionCell = UICollectionView.CellRegistration<CaptionBubbleCell, StreamItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            if let post = self.latestPost {
                cell.configure(with: post, imagePipeline: self.imagePipeline)
            } else if let seed = self.seededCaption {
                cell.configureSeed(caption: seed.text, timestamp: seed.timestamp)
            } else {
                return
            }
            cell.onAvatarTap = { [weak self] in self?.viewModel.didTapAuthor() }
        }
        streamDataSource = UICollectionViewDiffableDataSource<StreamSection, StreamItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .postSection:
                return collectionView.dequeueConfiguredReusableCell(using: postCell, for: indexPath, item: item)
            case .caption:
                return collectionView.dequeueConfiguredReusableCell(using: captionCell, for: indexPath, item: item)
            case .emptyState:
                return mode == .commentsOnly
                    ? collectionView.dequeueConfiguredReusableCell(
                        using: emptyPageCell, for: indexPath, item: item
                    )
                    : collectionView.dequeueConfiguredReusableCell(
                        using: emptyNoteCell, for: indexPath, item: item
                    )
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
        // The caption leads the COMMENTS-ONLY stream — item #0, above the
        // skeletons as well as above the comments, so it is on screen from
        // the first frame and never pops in behind a shimmer. The full mode
        // already carries the caption inside its post section.
        if mode == .commentsOnly, latestPost?.hasCaption == true || seededCaption != nil {
            items.append(.caption)
        }
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

    /// Whether a stream apply may animate. A cold apply never does (nothing
    /// to animate from), and neither does the one that introduces the
    /// CAPTION row — see `configure` for why a faded-in glass bubble reads
    /// as a dark-mode flash. Pure, so the rule is testable on its own.
    static func animatesStreamApply(hasAppliedStream: Bool, introducesCaption: Bool) -> Bool {
        hasAppliedStream && !introducesCaption
    }

    private func applyStream(animated: Bool, completion: (() -> Void)? = nil) {
        var snapshot = NSDiffableDataSourceSnapshot<StreamSection, StreamItem>()
        snapshot.appendSections([.main])
        let items = streamItems()
        snapshot.appendItems(items)
        hasAppliedStream = true
        streamDataSource.apply(snapshot, animatingDifferences: animated) { completion?() }
    }

    /// Re-asks every row how tall it wants to be.
    ///
    /// `reconfigureItems`, not `invalidateLayout`: UIKit caches a
    /// self-sizing cell's preferred attributes, and invalidating the layout
    /// re-runs the layout against that same cached size. Reconfiguring is
    /// what actually re-asks the cell.
    ///
    /// This is for width CHANGES only. It used to also run once after the
    /// first apply, papering over rows that measured against an unsettled
    /// width; `CaptionBubbleCell.preferredLayoutAttributesFitting` measures
    /// against the authoritative width now, so there is nothing left to
    /// paper over.
    private func remeasureStream() {
        var snapshot = streamDataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        streamDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - The empty page's fit

    /// The room the stream will have WHEN IT HAS SETTLED — deliberately not
    /// the room it has right now.
    ///
    /// This is the crux of the jump. Engaging moves the stream's bottom to
    /// the view's bottom (`setEngagedInsets`), so during the transition the
    /// collection view is still GROWING: measured live, the available height
    /// is smaller mid-animation than it ends up, and anything sized from it
    /// has to move when the animation lands. The engaged numbers are known
    /// up front though — they were handed in — so the final geometry is
    /// computable on frame 0 and that is what the empty page is sized
    /// against.
    ///
    /// The view's own height is the stable term (it does not animate); the
    /// collection view's is not, and is used only in the un-engaged case,
    /// where nothing is in flight.
    private var availableStreamHeight: CGFloat {
        if let engaged = engagedStreamInsets {
            return view.bounds.height - engaged.top - engaged.bottom
        }
        let inset = collectionView.adjustedContentInset
        return collectionView.bounds.height - inset.top - inset.bottom
    }

    /// The engaged context's own insets, kept so the settled geometry can be
    /// computed before the transition has produced it. Nil until engaged.
    private var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)?

    /// The empty page's height, resolved SYNCHRONOUSLY: the room the stream
    /// has, less the section's own insets, less the caption row that sits
    /// above it.
    ///
    /// The caption row is measured here rather than waited for. It is the
    /// only other row in this stream, and a throwaway `CaptionBubbleCell`
    /// answers for it exactly — same cell class, same width, same sizing
    /// path the layout itself would take. Measuring costs one offscreen
    /// layout pass per empty-state configuration; NOT measuring costs a
    /// visible jump, because anything learned after frame 0 arrives as
    /// motion the presentation did not ask for.
    private func emptyPageHeight() -> CGFloat {
        // The view's width, when the stream has not been laid out yet: the
        // resting engagement configures rows before the container has run a
        // pass, and a zero width would measure the caption as zero-height
        // and hand the empty page the whole viewport.
        let streamWidth = collectionView.bounds.width > 0
            ? collectionView.bounds.width
            : view.bounds.width
        let rowWidth = streamWidth - Spacing.lg * 2
        let occupied = Spacing.lg * 2 + captionRowHeight(width: rowWidth)
        return SnapCommentsLayout.emptyPageHeight(
            availableHeight: availableStreamHeight - occupied
        )
    }

    /// The caption row's height at `width`, or 0 when this stream has no
    /// caption row. Sized through the real cell so the answer cannot drift
    /// from what the layout will produce.
    private func captionRowHeight(width: CGFloat) -> CGFloat {
        guard width > 0, mode == .commentsOnly,
              let post = latestPost, post.hasCaption else { return 0 }
        let sizingCell = captionSizingCell
        sizingCell.configure(with: post, imagePipeline: nil)
        sizingCell.bounds.size.width = width
        sizingCell.contentView.setNeedsLayout()
        sizingCell.contentView.layoutIfNeeded()
        return ceil(sizingCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    /// Offscreen, never in the hierarchy — it exists to be measured. Held
    /// rather than rebuilt so a re-fit costs a layout pass, not a view tree.
    private lazy var captionSizingCell = CaptionBubbleCell()

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

    /// Points an EXISTING row at a model and re-wires its seams — the whole
    /// per-dequeue cost of a comment. The image pipeline rides along so the
    /// row can hydrate its own avatar behind its monogram, guarded by the
    /// comment id against a recycled row catching someone else's face.
    private func configureCommentRow(_ row: CommentRowView, with model: CommentDisplayModel) {
        row.configure(with: model, imagePipeline: imagePipeline)
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

// MARK: - Interactive pull-down dismissal

extension PostDetailViewController: UICollectionViewDelegate {
    /// The list's OVERSHOOT past its top drives the collapse back to the
    /// media layout, continuously and in both directions.
    ///
    /// Reading `contentOffset` rather than the pan is what keeps the two
    /// surfaces welded: the rubber band and the fade are the same number, so
    /// the content cannot slide while the layer sits still. It also makes
    /// the cancel free — when a released pull springs back, UIKit animates
    /// the offset home and these callbacks walk the transition back to rest
    /// with it, no separate animation to write or to keep in sync.
    ///
    /// Arming is unconditional by construction: overshoot exists only at the
    /// top, so a drag anywhere else reports zero and drives nothing.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // INTENT, decided once per drag: only a gesture that starts at the
        // top is a dismissal. A drag that begins mid-list and scrolls up
        // into the top is someone reading — it still bounces, because that
        // is UIKit's own behaviour and the content genuinely ran out, but it
        // drives nothing. Arming continuously (which the overshoot alone
        // would do) made every read that reached the top start dissolving
        // the screen.
        isPullDismissArmed = overshoot(of: scrollView) >= 0
            && scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let onPullDismissDrive, isPullDismissArmed, !isCommittingPullDismiss else { return }
        onPullDismissDrive(.changed, overshoot(of: scrollView), 0)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard let onPullDismissDrive, isPullDismissArmed, !isCommittingPullDismiss else { return }
        let pull = overshoot(of: scrollView)
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y / 1000
        guard pull > 0, SnapCommentsLayout.shouldCompletePullDismiss(
            progress: SnapCommentsLayout.pullDismissProgress(translation: pull),
            velocity: velocity
        ) else {
            // Below the bar: the bounce springs home and the transition
            // rides it back through `scrollViewDidScroll`. Stay armed until
            // it settles, or the fade would stop wherever it was.
            if !willDecelerate { disarmPullDismiss(scrollView) }
            return
        }
        isCommittingPullDismiss = true
        onPullDismissDrive(.ended, pull, velocity)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        disarmPullDismiss(scrollView)
    }

    /// Ends the armed window, settling the transition at rest first so a
    /// disarm can never strand it part-way faded.
    private func disarmPullDismiss(_ scrollView: UIScrollView) {
        guard isPullDismissArmed, !isCommittingPullDismiss else { return }
        isPullDismissArmed = false
        onPullDismissDrive?(.changed, 0, 0)
    }

    /// How far past its resting top the list has been pulled, in points.
    /// Zero anywhere else — the resting offset is NEGATIVE here, since the
    /// engaged stream carries a top content inset.
    private func overshoot(of scrollView: UIScrollView) -> CGFloat {
        max(0, -(scrollView.contentOffset.y + scrollView.contentInset.top))
    }
}
