import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// The "+" menu's Text Post: a text post's own page, born empty, in a sheet.
///
/// It hosts the text page's REAL panel — a `PostDetailViewController` over a
/// DRAFT view model — between the page's frost bands, and wears two sets of
/// bars:
///
/// ```
///  writing     [Cancel] ———————————————————— [Drafts]
///              [+ Add a sound] ——————— [🔖 ⇄] [⋯]
///
///  published   [✕] [⇅ sort] ——————— [◎ balance] [author]
///              [attribution] ————————— [🔖 ⇄] [⋯]
/// ```
///
/// The first message sent is published as the post, and the page becomes it:
/// the text is its caption row, the composer comments, the bars are the post's.
///
/// ⚠️ THE PANEL STAYS HERE for the life of the sheet, draft and post alike —
/// publishing only turns its view model into the post's. An earlier version
/// handed it to a snap feed page, and a composer re-parented after its
/// keyboard guide was made stops following the keyboard.
final class TextPostComposerViewController: UIViewController {
    private let panel: PostDetailViewController
    private let drafts: PostDraftStore
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    private let wallet: WalletStore?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    private let headerFrost = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.headerFrostMaskColors,
        maskLocations: SnapCommentsLayout.headerFrostMaskLocations
    )
    private var headerFrostHeight: NSLayoutConstraint?
    /// What the panel was last placed against, so an unchanged safe area never
    /// re-places it (placing scrolls the stream back to its top).
    private var appliedInsets: (top: CGFloat, bottom: CGFloat)?

    /// The draft being edited, when one was opened from the list: saving writes
    /// over it, and publishing deletes it.
    private(set) var editingDraftID: String?
    private var composerText = ""
    /// Whether the sheet grew to make room for the keyboard — so it shrinks
    /// back when the keyboard goes, and only then.
    private var expandedForKeyboard = false
    private let keyboardObservers = NotificationObserverTokenBag()
    private let draftObservers = NotificationObserverTokenBag()

    // MARK: The writing chrome

    private var draftsItem: UIBarButtonItem?
    /// The sound pill's two homes — see `placeSoundPill`. Two instances,
    /// because a view lives in one bar at a time.
    private let topSoundItem = UIBarButtonItem(customView: TextPostSoundPill())
    private var footerSoundItem: UIBarButtonItem?
    /// The writing footer without its leading pill: [🔖 ⇄] [⋯], right-aligned.
    private var writingFooterTrailing: [UIBarButtonItem] = []
    private var isSoundPillOnTop = false

    // MARK: The published post's chrome

    private var publishedModel: FeedItemDisplayModel?
    private var publishedEntry: FeedEntry?
    private let authorPill = SnapAuthorIdentityView()
    private let attribution = SnapMediaAttributionView()
    private let sortButton = SnapCommentSortButton()
    private var closeItem: UIBarButtonItem?
    private var sortItem: UIBarButtonItem?
    /// The sort waits for a thread worth ranking — see `CommentSortPolicy`.
    private var isSortAvailable = false
    private let walletBadge = WalletBadgeButton()
    private var walletBadgeItem: UIBarButtonItem?
    private let walletObservers = NotificationObserverTokenBag()
    private let bookmarks = PostBookmarkStore()
    private let bookmarkButton = SnapFooterToolbar.makeSaveButton()

    init(
        panel: PostDetailViewController,
        drafts: PostDraftStore,
        imagePipeline: ImagePipeline,
        router: (any Router)?,
        wallet: WalletStore?,
        makeWalletSheet: (@MainActor () -> UIViewController)?
    ) {
        self.panel = panel
        self.drafts = drafts
        self.imagePipeline = imagePipeline
        self.router = router
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        embedPanel()
        configureHeaderFrost()
        configureNavigationAppearance()
        showWritingBars()
        panel.setVisibilityMenu(Self.makeVisibilityMenu())
        panel.onComposerTextChange = { [weak self] text in self?.composerTextDidChange(text) }
        panel.onPostPublished = { [weak self] entry in self?.becomePublished(entry) }
        panel.onCommentCountChange = { [weak self] count in self?.commentCountDidChange(count) }
        // A post on its way holds the sheet: it belongs to the draft it came
        // from until it lands, and a failure hands its text back here.
        panel.onComposingChange = { [weak self] _ in self?.refreshSwipeGuard() }
        // …and so does a store change: deleting the draft that is open turns
        // its text back into writing that nothing else keeps.
        draftObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: PostDraftStore.didChangeNotification, object: drafts, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSwipeGuard() }
            },
        ]
        bookmarkButton.addAction(UIAction { [weak self] _ in self?.toggleBookmark() }, for: .primaryActionTriggered)
        observeKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The footer is this page's alone: the drafts list above it has none.
        navigationController?.setToolbarHidden(false, animated: animated)
        // A swipe down ASKS, rather than throwing a draft away — see
        // `presentationControllerDidAttemptToDismiss`.
        navigationController?.presentationController?.delegate = self
        applyPanelInsets()
        fitTrailingRun()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Materials in a window only — built in init they stall headless CI.
        if headerFrost.effect == nil {
            headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
        applyPanelInsets()
        panel.setComposerEntranceState(offstage: false)
        #if DEBUG
        runDebugHooks()
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyPanelInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitTrailingRun()
    }

    // MARK: - Setup

    private func embedPanel() {
        addChild(panel)
        panel.view.backgroundColor = .clear
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel.view)
        NSLayoutConstraint.activate([
            panel.view.topAnchor.constraint(equalTo: view.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panel.didMove(toParent: self)
    }

    /// The band the text page's cell owns at rest, over the panel's stream.
    private func configureHeaderFrost() {
        headerFrost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        headerFrost.isUserInteractionEnabled = false
        headerFrost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerFrost)
        let height = headerFrost.heightAnchor.constraint(
            equalToConstant: SnapCommentsLayout.commentsTopInset(topInset: view.safeAreaInsets.top)
        )
        headerFrostHeight = height
        NSLayoutConstraint.activate([
            headerFrost.topAnchor.constraint(equalTo: view.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])
    }

    /// The text page's bar: transparent, so the frost is the only band.
    private func configureNavigationAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.titleView = UIView()
    }

    /// The panel's stream runs under both bars, resting below the frost and
    /// above the footer — the text page's own geometry, measured from THIS
    /// view, whose height is the sheet's current detent.
    private func applyPanelInsets() {
        let top = SnapCommentsLayout.commentsTopInset(topInset: view.safeAreaInsets.top)
        headerFrostHeight?.constant = top
        let bottom = view.safeAreaInsets.bottom
        if let applied = appliedInsets, applied.top == top, applied.bottom == bottom { return }
        appliedInsets = (top, bottom)
        panel.setEngagedInsets(top: top, bottomInset: bottom)
    }

    // MARK: - Writing

    private func showWritingBars() {
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in self?.cancelTapped() }),
        ]
        let drafts = UIBarButtonItem(title: "Drafts", primaryAction: UIAction { [weak self] _ in self?.showDrafts() })
        draftsItem = drafts
        navigationItem.rightBarButtonItems = [drafts]
        // Drawn as they will be once the post exists, and quiet until then:
        // there is nothing to save, pass on or report yet.
        bookmarkButton.isEnabled = false
        let more = SnapFooterToolbar.makeMoreButton(menu: UIMenu(children: []))
        more.isEnabled = false
        let footer = SnapFooterToolbar.items(
            leading: TextPostSoundPill(),
            bookmark: bookmarkButton,
            repost: SnapFooterToolbar.makeRepostButton(),
            more: more
        )
        footerSoundItem = footer.first
        writingFooterTrailing = Array(footer.dropFirst())
        toolbarItems = footer
    }

    /// ⚠️ THE SOUND PILL FOLLOWS THE KEYBOARD. Its home is the footer's leading
    /// slot, which the keyboard covers while the viewer writes — so while the
    /// keyboard is up it rides in the top bar, just inboard of Drafts, where it
    /// can still be reached, and it goes home when the keyboard does. Writing
    /// only: the published post's footer leads with its own attribution.
    private func placeSoundPill(onTop: Bool) {
        guard publishedModel == nil, onTop != isSoundPillOnTop,
              let draftsItem, let footerSoundItem else { return }
        isSoundPillOnTop = onTop
        // RIGHT TO LEFT: Drafts keeps the edge, the pill sits inboard of it,
        // and the fixed space keeps them two bubbles rather than one platter.
        navigationItem.setRightBarButtonItems(
            onTop ? [draftsItem, .fixedSpace(Spacing.sm), topSoundItem] : [draftsItem],
            animated: true
        )
        setToolbarItems(
            onTop ? writingFooterTrailing : [footerSoundItem] + writingFooterTrailing,
            animated: true
        )
    }

    /// Who will see the post. Only "Everyone" can be chosen: post.v1 carries
    /// no audience (dev/BACKEND_GAPS.md #20), and a checkmark the server
    /// ignores would be the lie — so the others are shown, and say why not.
    static func makeVisibilityMenu() -> UIMenu {
        UIMenu(title: "Who can see this post", children: [
            UIAction(
                title: "Everyone", subtitle: "Anyone can see it",
                image: UIImage(systemName: "globe"), state: .on
            ) { _ in },
            UIAction(
                title: "Followers", subtitle: "Coming soon",
                image: UIImage(systemName: "person.2"), attributes: .disabled
            ) { _ in },
            UIAction(
                title: "Friends", subtitle: "Coming soon",
                image: UIImage(systemName: "person.2.circle"), attributes: .disabled
            ) { _ in },
        ])
    }

    private func composerTextDidChange(_ text: String) {
        composerText = text
        refreshSwipeGuard()
    }

    /// A swipe asks first while there is writing to lose — or a post on its
    /// way, which closing would cut off from the draft it came from.
    private func refreshSwipeGuard() {
        navigationController?.isModalInPresentation = hasUnsavedChanges || panel.isPublishing
    }

    /// Whether leaving now would lose writing: text that is neither published,
    /// on its way, nor already the saved draft it came from.
    var hasUnsavedChanges: Bool {
        guard publishedModel == nil, !panel.isPublishing else { return false }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return text != editingDraftID.flatMap { drafts.draft($0) }?.text
    }

    private func cancelTapped() {
        // Nothing to cancel while the post is on its way: it has already gone.
        guard !panel.isPublishing else { return }
        guard hasUnsavedChanges else { return close() }
        confirmLeaving(from: navigationItem.leftBarButtonItems?.first)
    }

    /// Save or delete — the question every compose sheet asks on the way out.
    private func confirmLeaving(from item: UIBarButtonItem?) {
        let host = navigationController ?? self
        guard host.presentedViewController == nil else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Save Draft", style: .default) { [weak self] _ in
            self?.saveDraftAndClose()
        })
        sheet.addAction(UIAlertAction(title: "Delete Draft", style: .destructive) { [weak self] _ in
            self?.deleteDraftAndClose()
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        if let item {
            sheet.popoverPresentationController?.sourceItem = item
        } else {
            sheet.popoverPresentationController?.sourceView = view
        }
        host.present(sheet, animated: true)
    }

    /// Internal for tests: the alert's actions cannot be tapped from one.
    func saveDraftAndClose() {
        drafts.save(composerText, replacing: editingDraftID)
        close()
    }

    func deleteDraftAndClose() {
        if let editingDraftID { drafts.delete(editingDraftID) }
        close()
    }

    private func close() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    // MARK: - Drafts

    private func showDrafts() {
        // A post on its way still belongs to the draft it came from.
        guard publishedModel == nil, !panel.isPublishing else { return }
        let list = TextPostDraftsViewController(store: drafts)
        list.onSelect = { [weak self] draft in self?.open(draft) }
        navigationController?.pushViewController(list, animated: true)
    }

    /// Opens `draft` in the composer. What was being written is not lost: it
    /// is kept as a draft of its own before the other takes its place.
    /// Internal for tests.
    func open(_ draft: PostDraft) {
        // Never into a post on its way, or into the published post's comment
        // composer: either would lose the draft or post it as a comment.
        guard publishedModel == nil, !panel.isPublishing else { return }
        // The draft already open keeps the edits on screen — its row was read
        // before they were made.
        if draft.id != editingDraftID {
            if hasUnsavedChanges { drafts.save(composerText, replacing: editingDraftID) }
            editingDraftID = draft.id
            panel.composerText = draft.text
        }
        if navigationController?.topViewController !== self {
            navigationController?.popToViewController(self, animated: true)
        }
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        keyboardObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWillShow() }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWillHide() }
            },
        ]
    }

    /// ⚠️ THE SHEET GROWS WITH THE KEYBOARD. At its medium height the keyboard
    /// takes most of what is left, and the page shrinks to a composer and a
    /// sliver of stream; the large detent gives back the room the keys take.
    /// It goes back down with the keyboard — if, and only if, it grew for it.
    private func keyboardWillShow() {
        guard view.window != nil, navigationController?.topViewController === self else { return }
        placeSoundPill(onTop: true)
        guard let sheet = navigationController?.sheetPresentationController,
              sheet.selectedDetentIdentifier != .large else { return }
        expandedForKeyboard = true
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
    }

    private func keyboardWillHide() {
        // Not for an alert or menu raised over the sheet: it takes the keyboard
        // for a moment, and the sheet — and the pill — would move and come
        // back behind it.
        guard (navigationController ?? self).presentedViewController == nil else { return }
        placeSoundPill(onTop: false)
        guard expandedForKeyboard, let sheet = navigationController?.sheetPresentationController else { return }
        expandedForKeyboard = false
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
    }

    // MARK: - Published

    /// The first message went out: the page is the post's now. The panel did
    /// its own half (caption row, "No comments yet", a composer that
    /// comments); these are the bars.
    private func becomePublished(_ entry: FeedEntry) {
        if let editingDraftID { drafts.delete(editingDraftID) }
        editingDraftID = nil
        let model = FeedDisplayModelBuilder().build(entry, now: Date())
        publishedEntry = entry
        publishedModel = model
        navigationController?.isModalInPresentation = false
        // The post is shown whole: the keyboard goes down with what it wrote.
        view.endEditing(true)
        showPublishedBars(model, author: entry.author)
        #if DEBUG
        if let text = Self.debugArgument("-text-post-comment") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.panel.debugSend(text) }
        }
        #endif
    }

    private func showPublishedBars(_ model: FeedItemDisplayModel, author: AuthorSummary) {
        let close = SnapNavControls.makeNavActionButton(systemName: "xmark")
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        closeItem = UIBarButtonItem(customView: close)
        sortButton.reset()
        sortButton.onOrderChange = { [weak panel] order in panel?.setCommentSortOrder(order) }
        sortItem = UIBarButtonItem(customView: sortButton)
        applyLeadingItems(animated: true)

        // Your own post: there is nobody to follow.
        authorPill.setFollowHidden(true)
        authorPill.setOverMedia(false)
        authorPill.setAuthor(model, pipeline: imagePipeline)
        authorPill.onAuthorTapped = { [weak self] id in
            self?.router?.route(to: .profile(
                id, stub: ProfileIdentityStub(handle: author.handle, displayName: author.displayName)
            ))
        }
        var trailing = [UIBarButtonItem(customView: authorPill)]
        if let walletItem = makeWalletItem() {
            trailing += [.fixedSpace(Spacing.sm), walletItem]
        }
        navigationItem.setRightBarButtonItems(trailing, animated: true)

        attribution.setOverMedia(false)
        attribution.setPost(model, pipeline: imagePipeline)
        bookmarkButton.isEnabled = true
        refreshBookmarkGlyph()
        let more = SnapFooterToolbar.makeMoreButton(menu: UIMenu(children: [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.sharePost()
            },
        ]))
        setToolbarItems(SnapFooterToolbar.items(
            leading: attribution,
            bookmark: bookmarkButton,
            repost: SnapFooterToolbar.makeRepostButton(),
            more: more
        ), animated: true)
        fitTrailingRun()
    }

    /// [✕], and the sort beside it once the thread is worth sorting — the
    /// text page's leading group, with the fixed space that keeps two pills.
    private func applyLeadingItems(animated: Bool) {
        guard let closeItem else { return }
        var items = [closeItem]
        if isSortAvailable, let sortItem { items += [.fixedSpace(Spacing.sm), sortItem] }
        guard navigationItem.leftBarButtonItems ?? [] != items else { return }
        navigationItem.setLeftBarButtonItems(items, animated: animated)
    }

    private func commentCountDidChange(_ count: Int) {
        let available = CommentSortPolicy.isAvailable(commentCount: count)
        guard available != isSortAvailable else { return }
        isSortAvailable = available
        applyLeadingItems(animated: true)
        fitTrailingRun()
    }

    /// The author pill's share of the bar: the bar less its margins, the ✕,
    /// the sort when it is there and the balance — the text page's arithmetic
    /// (see `SnapFeedViewController.applyEngagedTrailingRunFit`). Applied
    /// before the bar lays the run out, or the whole item collapses to `•••`.
    private func fitTrailingRun() {
        guard publishedModel != nil else { return }
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        let pad: CGFloat = 18
        var budget = bar - 16 * 2 - (36 + pad) - pad
        if isSortAvailable {
            budget -= sortButton.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + pad + Spacing.sm
        }
        if walletBadgeItem != nil {
            budget -= walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + pad + Spacing.sm
        }
        authorPill.setWidthBudget(budget)
    }

    private func makeWalletItem() -> UIBarButtonItem? {
        guard let wallet else { return nil }
        walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
        if makeWalletSheet != nil {
            walletBadge.addAction(UIAction { [weak self] _ in self?.presentWalletSheet() }, for: .primaryActionTriggered)
        }
        let item = UIBarButtonItem(customView: walletBadge)
        walletBadgeItem = item
        // A grown count needs a FRESH item — re-adding the same one hands the
        // bar the same frozen wrapper (the feed's measured finding).
        walletBadge.onFittedWidthChange = { [weak self] in self?.refreshWalletItem() }
        refreshWalletBadge()
        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWalletBadge() }
            },
        ]
        return item
    }

    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    private func refreshWalletItem() {
        guard let old = walletBadgeItem,
              var items = navigationItem.rightBarButtonItems,
              let index = items.firstIndex(of: old) else { return }
        let fresh = UIBarButtonItem(customView: walletBadge)
        walletBadgeItem = fresh
        items[index] = fresh
        navigationItem.rightBarButtonItems = items
        fitTrailingRun()
    }

    private func presentWalletSheet() {
        guard let makeWalletSheet, presentedViewController == nil else { return }
        present(makeWalletSheet(), animated: true)
    }

    private func toggleBookmark() {
        guard let id = publishedModel?.id else { return }
        bookmarks.toggle(id.rawValue)
        refreshBookmarkGlyph()
    }

    private func refreshBookmarkGlyph() {
        guard let id = publishedModel?.id else { return }
        let saved = bookmarks.isSaved(id.rawValue)
        bookmarkButton.accessibilityLabel = saved ? "Saved" : "Save"
        var config = bookmarkButton.configuration
        config?.image = UIImage(systemName: saved ? "bookmark.fill" : "bookmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        bookmarkButton.configuration = config
    }

    private func sharePost() {
        guard let caption = publishedEntry?.post.caption else { return }
        let activity = UIActivityViewController(activityItems: [caption], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        present(activity, animated: true)
    }

    // MARK: - Debug

    #if DEBUG
    var debugIsPublished: Bool { publishedModel != nil }

    private var didRunDebugHooks = false

    /// `-text-post-type <text>`: the draft starts with this in the composer —
    /// for the Cancel sheet and the swipe guard, which need writing to guard.
    /// `-text-post-send <text>`: sends the first message shortly after the
    /// sheet appears. `-text-post-comment <text>`: then a comment on the post
    /// it became. The simulator cannot type into a field.
    private func runDebugHooks() {
        guard !didRunDebugHooks else { return }
        didRunDebugHooks = true
        if let text = Self.debugArgument("-text-post-type") {
            panel.composerText = text
        }
        if let text = Self.debugArgument("-text-post-send") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.panel.debugSend(text) }
        }
    }

    private static func debugArgument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
    #endif
}

extension TextPostComposerViewController: UIAdaptivePresentationControllerDelegate {
    /// A swipe on a sheet holding unsaved writing (`isModalInPresentation`)
    /// asks the same question Cancel does.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        // A post on its way just holds: there is nothing to save or delete.
        guard !panel.isPublishing else { return }
        confirmLeaving(from: nil)
    }
}

/// The footer's leading item while writing: where the post's sound — and its
/// cover — will be chosen. The attribution pill's shape, so the footer keeps
/// its outline when the post is published and the pill becomes the post's own.
///
/// ⚠️ NO ACTION YET: the screen that picks a sound does not exist. It is drawn
/// because it is part of the page, and a tap on it does nothing.
private final class TextPostSoundPill: UIControl {
    private static let height: CGFloat = 36
    /// The attribution pill's cap, which this pill stands in for.
    private static let maxWidth: CGFloat = 240

    /// ⚠️ ITS TEXT DOES NOT GROW WITH DYNAMIC TYPE, in either bar — pinned at the
    /// default size. In the top bar it shares a run with Cancel and Drafts,
    /// whose titles do not grow either, and a pill that did would outgrow the
    /// bar at large sizes and fold the run into `•••`. In the footer its two
    /// lines live in a bubble of fixed height: measured at accessibility XL,
    /// the second line spilled out underneath it.
    init() {
        super.init(frame: .zero)
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let disc = UIView()
        disc.backgroundColor = .tertiarySystemFill
        disc.layer.cornerRadius = AvatarImageView.barDiameter / 2
        disc.isUserInteractionEnabled = false
        disc.widthAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        disc.heightAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        let plus = UIImageView(image: UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        ))
        plus.tintColor = .label
        plus.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])

        let title = UILabel()
        title.text = "Add a sound"
        title.font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).withWeight(.semibold)
        title.textColor = .label
        let subtitle = UILabel()
        subtitle.text = "and a cover"
        subtitle.font = .preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        subtitle.textColor = .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.alignment = .leading
        // The words give way first — the attribution's rule — so the cap
        // truncates them rather than squeezing the disc.
        labels.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        let row = UIStackView(arrangedSubviews: [disc, labels])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.isUserInteractionEnabled = false
        let breathing = (Self.height - AvatarImageView.barDiameter) / 2
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: breathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.sm)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, never required: the bar pins its item wrapper with autoresizing
        // constraints, and anything required loses to that with a console break.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true

        isAccessibilityElement = true
        accessibilityLabel = "Add a sound and a cover"
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
