import CoreModels
import FeedInterface
import CoreNavigation
import CoreStorage
import DesignSystem
import EntityStore
import MediaCore
import UIKit
import VoiceKit
import VoiceKitUI

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
///  published   [✕] [Popular | Recent] ——— [◎ balance] [author]
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
    /// The thread's voice composer, on the text composer (#2209,
    /// `-voice-posts`): the first message can be a voice.
    private(set) var voiceComposer: VoiceComposer?
    /// The copy of the opened draft's voice handed to the bar (#2209): the
    /// draft's own file stays the store's, so publishing (which deletes the
    /// draft) never pulls the file from under the post that plays it. While
    /// the bar still holds this file, the draft's voice is unchanged.
    private var restoredVoiceURL: URL?
    /// The card the screen was opened with (#2216, "Share as a Post"): a
    /// channel's, attached above the composer until the author removes it.
    private let openingEmbed: PostEmbed?
    /// The attached card and its place, while there is one (#2216).
    private(set) var showcaseAttachment: ShowcaseAttachmentView?
    /// Whether the sheet grew to make room for the keyboard — so it shrinks
    /// back when the keyboard goes, and only then.
    private var expandedForKeyboard = false
    /// The least the sheet may rest at, as a detent value — see
    /// `makeRestingDetent`. Nil while the medium height is enough.
    private var restingFloor: CGFloat?
    private let keyboardObservers = NotificationTokens()
    private let draftObservers = NotificationTokens()

    // MARK: The writing chrome

    /// The bars' identities (#1679, `dev/BAR_CONTRACT.md`), by function.
    enum ItemID {
        static let cancel = "textpost.cancel"
        static let drafts = "textpost.drafts"
        static let close = "textpost.close"
        static let commentTabs = "textpost.commentTabs"
        static let authorPill = "textpost.author-pill"
        static let attribution = "textpost.attribution"
    }

    private var draftsItem: UIBarButtonItem?

    // MARK: The published post's chrome

    private var publishedModel: FeedItemDisplayModel?
    private var publishedEntry: FeedEntry?
    private let authorPill = SnapAuthorIdentityView()
    private let attribution = SnapMediaAttributionView()
    /// The comments' Popular | Recent selector (#2007), bound to the panel.
    private let commentTabs = CommentTabsSelector()
    private var closeItem: UIBarButtonItem?
    private var sortItem: UIBarButtonItem?
    /// The selector waits for a thread worth ranking — see `CommentSortPolicy`.
    private var isSortAvailable = false
    private let walletBadge = WalletBadgeButton()
    private var walletBadgeItem: UIBarButtonItem?
    private let walletObservers = NotificationTokens()
    /// The saved pile: the app's one (`shared`) outside tests.
    private let bookmarks: PostBookmarkStore
    private lazy var bookmarkItem = SnapFooterToolbar.makeSaveItem { [weak self] in self?.toggleBookmark() }
    /// The footer's repost and ⋯, and the leading run's space, kept from the
    /// draft's bars into the published post's (#2331): a new instance under
    /// the same identifier is redrawn by the bar — blurred out and back —
    /// though it says the same. The ⋯ takes its menu in place.
    private lazy var repostItem = SnapFooterToolbar.makeRepostItem()
    private lazy var moreItem = SnapFooterToolbar.makeMoreItem(menu: UIMenu(children: []))
    private let leadingSortSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// Keeps the published post's save glyph on its saved fact (#1067): a
    /// save or unsave made on another surface while the page shows the post
    /// draws at once — the feed page's and the cards' mechanism. Lives as
    /// long as the page, and draws nothing while it is still a draft.
    private var savedObservation: EntityObservation?

    /// - Parameter entities: where a save made elsewhere is heard. Nil: the
    ///   glyph reads the pile when the post is published and on a tap.
    init(
        panel: PostDetailViewController,
        drafts: PostDraftStore,
        imagePipeline: ImagePipeline,
        router: (any Router)?,
        wallet: WalletStore?,
        makeWalletSheet: (@MainActor () -> UIViewController)?,
        entities: EntityStore? = nil,
        bookmarks: PostBookmarkStore = .shared,
        attaching embed: PostEmbed? = nil
    ) {
        self.openingEmbed = embed
        self.panel = panel
        self.drafts = drafts
        self.imagePipeline = imagePipeline
        self.router = router
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.bookmarks = bookmarks
        super.init(nibName: nil, bundle: nil)
        savedObservation = entities?.observePosts { [weak self] change in
            guard let self, let id = self.publishedModel?.id, change.contains(id) else { return }
            // Its counts move here too: only a changed save re-draws.
            let saved = self.bookmarks.isSaved(id.rawValue)
            guard SnapFeedViewController.bookmarkSymbol(saved: saved) != self.drawnBookmarkSymbol else { return }
            self.refreshBookmarkGlyph()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Voice posts (#2209)

    /// The thread's hold-to-record on the text composer, with a voice post's
    /// minute: a first message can be a voice, a voice then words (the words
    /// typed so far go with it as its caption), or words alone as before.
    ///
    /// The composer's contract declares it (#2308): the draft's field records
    /// a voice post (a minute, in seconds) — the hold, the own bubble and the
    /// rest are every host's. Published, the page is a post's comments again,
    /// whose field does not record (`PostDetailViewController.becomePublished`).
    private func installVoiceComposer() {
        guard panel.viewModel.acceptsVoice, voiceComposer == nil else { return }
        panel.composeBar.configuration.voice = .post
        let composer = VoiceComposer(for: .post, draftKey: "text-post-voice")
        composer.onSend = { [weak self] take in
            guard let self else { return }
            panel.viewModel.publishVoice(
                TextPostVoice(fileURL: take.fileURL, duration: take.duration, waveform: take.waveform),
                text: composerText
            )
        }
        composer.onHint = { [weak self] hint in
            guard let self else { return }
            Feedback.info(hint, symbol: "mic", from: self)
        }
        composer.onPermissionDenied = { [weak self] in self?.offerMicrophoneSettings() }
        // A take recorded or thrown away changes what leaving would lose.
        composer.onPhaseChange = { [weak self] _ in self?.refreshSwipeGuard() }
        composer.attach(to: panel.composeBar, host: view)
        // A failed upload keeps the take and offers to try again, as a failed
        // chat send does.
        panel.viewModel.onVoicePublishFailed = { [weak self] voice, text in
            self?.offerVoiceRetry(voice, text: text)
        }
        voiceComposer = composer
    }

    /// The take that didn't go, offered again.
    private func offerVoiceRetry(_ voice: TextPostVoice, text: String) {
        let alert = UIAlertController(
            title: "Couldn\u{2019}t Post", message: "Your voice post wasn\u{2019}t sent.", preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.panel.viewModel.publishVoice(voice, text: text)
        })
        present(alert, animated: true)
    }

    /// Once refused, a hold offers Settings — the thread's (#2102).
    private func offerMicrophoneSettings() {
        let alert = UIAlertController(
            title: "Microphone Access", message: "Allow microphone access to record a voice post.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        present(alert, animated: true)
    }

    // MARK: - Showcases (#2216)

    /// A channel's "Share as a Post": its full card above the composer, the
    /// words the author writes going above it on the post, and an optional
    /// place. The invitation steps aside — the card is what is being posted.
    /// Only for a draft that publishes embeds (`-channels`).
    private func installShowcase() {
        guard let openingEmbed, panel.viewModel.acceptsShowcase, showcaseAttachment == nil else { return }
        let attachment = ShowcaseAttachmentView()
        attachment.show(openingEmbed, pipeline: imagePipeline)
        attachment.setPlace(nil)
        attachment.onRemove = { [weak self] in self?.removeShowcase() }
        attachment.onPickPlace = { [weak self] in self?.pickPlace() }
        attachment.onClearPlace = { [weak self] in self?.setShowcasePlace(nil) }
        attachment.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(attachment)
        // Above the composer's input row, riding it up with the keyboard; it
        // may slide under the header's frost on a short sheet rather than
        // squeeze the card.
        let top = attachment.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
        top.priority = .defaultHigh
        // ⚠️ AND OVER THE GLOBE. While the keyboard is down the page's
        // visibility globe floats over the input row's trailing end, and a
        // card resting on the row sat under it (seen on the simulator: the
        // globe over the card's corner and its place). The card rests on the
        // row when it can, and stands clear of the globe always; with the
        // keyboard up the row rises past the globe and the card rides it.
        let restsOnRow = attachment.bottomAnchor.constraint(equalTo: panel.composeBar.inputRowTopAnchor, constant: -Spacing.md)
        // Low, so it never lifts the row itself: the row's own resting place
        // outranks it, and so does clearing the globe.
        restsOnRow.priority = .defaultLow
        let composeBar = panel.composeBar
        NSLayoutConstraint.activate([
            attachment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            attachment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
            attachment.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.inputRowTopAnchor, constant: -Spacing.md),
            attachment.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.stakeStationTopAnchor, constant: -Spacing.sm),
            restsOnRow,
            top,
        ])
        panel.viewModel.draftShowcase = DraftShowcase(embed: openingEmbed, place: nil)
        panel.setDraftStreamHidden(true)
        showcaseAttachment = attachment
    }

    /// The card's ✕: the words publish as a plain text post, with no place.
    /// Internal for tests.
    func removeShowcase() {
        // A post on its way has already gone with its card.
        guard showcaseAttachment != nil, !panel.isPublishing, publishedModel == nil else { return }
        dropShowcaseAttachment()
        panel.viewModel.draftShowcase = nil
    }

    private func dropShowcaseAttachment() {
        showcaseAttachment?.removeFromSuperview()
        showcaseAttachment = nil
        panel.setDraftStreamHidden(false)
    }

    /// "Add a Place": the place search, on the sheet's stack.
    private func pickPlace() {
        guard publishedModel == nil, !panel.isPublishing else { return }
        let picker = ShowcasePlacePickerViewController()
        picker.onPick = { [weak self, weak picker] place in
            self?.setShowcasePlace(place)
            picker?.closeScreen()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    /// The place the showcase stands at on the map, or none. Internal for
    /// tests.
    func setShowcasePlace(_ place: TextPostPlace?) {
        guard showcaseAttachment != nil, panel.viewModel.draftShowcase != nil else { return }
        panel.viewModel.draftShowcase?.place = place
        showcaseAttachment?.setPlace(place)
    }

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
        draftObservers.replace(with: [
            NotificationCenter.default.addObserver(
                forName: PostDraftStore.didChangeNotification, object: drafts, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSwipeGuard() }
            },
        ])
        observeKeyboard()
        installVoiceComposer()
        installShowcase()
        // The invitation grows with the text size, and so may the least the
        // sheet rests at.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: TextPostComposerViewController, _: UITraitCollection) in
            controller.updateRestingFloor()
        }
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
        // In a window now: the bottom safe area the floor subtracts is known.
        updateRestingFloor()
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
        updateRestingFloor()
    }

    // MARK: - Writing

    private func showWritingBars() {
        navigationItem.leftBarButtonItems = [
            BarItems.title(id: ItemID.cancel, title: "Cancel") { [weak self] in self?.cancelTapped() },
        ]
        let drafts = BarItems.title(id: ItemID.drafts, title: "Drafts") { [weak self] in self?.showDrafts() }
        draftsItem = drafts
        navigationItem.rightBarButtonItems = [drafts]
        // Drawn as they will be once the post exists, and quiet until then:
        // there is nothing to save, pass on or report yet.
        bookmarkItem.isEnabled = false
        moreItem.isEnabled = false
        // ⚠️ NO SOUND PILL (#1999): a text post has no sound, so the footer
        // has nothing to lead with — its trailing run alone, [🔖 ⇄] [⋯]. It
        // used to lead with an inert pill that rode into the top bar while
        // the keyboard was up. The published post's footer leads with its
        // attribution, as before.
        toolbarItems = SnapFooterToolbar.trailingItems(
            actions: [bookmarkItem, repostItem],
            more: moreItem
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

    /// Whether leaving now would lose writing: text or a voice that is
    /// neither published, on its way, nor already the saved draft it came from.
    var hasUnsavedChanges: Bool {
        guard publishedModel == nil, !panel.isPublishing else { return false }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVoice = voiceComposer?.hasTake == true
        guard !text.isEmpty || hasVoice else { return false }
        let saved = editingDraftID.flatMap { drafts.draft($0) }
        return text != saved?.text || voiceDiffers(from: saved)
    }

    /// Whether the bar's voice is not the saved draft's (#2209): a take
    /// recorded, recorded on, or thrown away. Without the voice composer
    /// (`-voice-posts` off) a draft's voice is kept as it is.
    private func voiceDiffers(from saved: PostDraft?) -> Bool {
        guard let composer = voiceComposer else { return false }
        guard composer.hasTake else { return saved?.voice != nil }
        guard saved?.voice != nil, let restoredVoiceURL else { return true }
        return composer.closedTakeURL != restoredVoiceURL
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
        saveDraft { [weak self] in self?.close() }
    }

    /// Saves what is on screen — the words, and the bar's take when there is
    /// one (#2209) — over the draft being edited, then `done`. A take is
    /// closed first, which may take a moment when two parts are being joined.
    private func saveDraft(then done: @escaping () -> Void) {
        let text = composerText
        let id = editingDraftID
        guard let composer = voiceComposer else {
            // No bar to record on: a draft's voice is kept as it was.
            let kept = id.flatMap { drafts.draft($0) }?.voice.map {
                PostDraftVoiceTake(fileURL: drafts.voiceURL($0), duration: $0.duration, waveform: $0.waveform)
            }
            drafts.save(text, voice: kept, replacing: id)
            return done()
        }
        composer.takeForDraft { [weak self] take in
            guard let self else { return }
            let voice = take.map { PostDraftVoiceTake(fileURL: $0.fileURL, duration: $0.duration, waveform: $0.waveform) }
            drafts.save(text, voice: voice, replacing: id)
            // The store kept a copy: the take's own file was a temporary one.
            if let take { try? FileManager.default.removeItem(at: take.fileURL) }
            restoredVoiceURL = nil
            done()
        }
    }

    func deleteDraftAndClose() {
        if let editingDraftID { drafts.delete(editingDraftID) }
        close()
    }

    private func close() {
        view.endEditing(true)
        closePresentation()
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
            let switchTo = { [weak self] in
                guard let self else { return }
                editingDraftID = draft.id
                panel.composerText = draft.text
                restoreVoice(of: draft)
                refreshSwipeGuard()
            }
            if hasUnsavedChanges {
                saveDraft(then: switchTo)
            } else {
                voiceComposer?.clearTake()
                restoredVoiceURL = nil
                switchTo()
            }
        }
        if navigationController?.topViewController !== self {
            navigationController?.popToViewController(self, animated: true)
        }
    }

    /// A draft's voice back on the paused bar (#2209), from a copy of its
    /// file: listen back, record on, delete or send, as with a fresh take.
    private func restoreVoice(of draft: PostDraft) {
        guard let composer = voiceComposer, let voice = draft.voice else { return }
        let source = drafts.voiceURL(voice)
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-takes", directoryHint: .isDirectory)
        let copy = folder.appending(path: UUID().uuidString + "." + (source.pathExtension.isEmpty ? "m4a" : source.pathExtension))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            return
        }
        restoredVoiceURL = copy
        composer.restore(VoiceDraft(fileURL: copy, duration: voice.duration, waveform: voice.waveform))
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        keyboardObservers.replace(with: [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] note in
                let scope = KeyboardNotificationScope.window(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.view.hearsKeyboard(aimedAt: scope) else { return }
                    self.keyboardWillShow()
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] note in
                let scope = KeyboardNotificationScope.window(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.view.hearsKeyboard(aimedAt: scope) else { return }
                    self.keyboardWillHide()
                }
            },
        ])
    }

    /// ⚠️ THE SHEET GROWS WITH THE KEYBOARD. At its medium height the keyboard
    /// takes most of what is left, and the page shrinks to a composer and a
    /// sliver of stream; the large detent gives back the room the keys take.
    /// It goes back down with the keyboard — if, and only if, it grew for it.
    private func keyboardWillShow() {
        guard view.window != nil, navigationController?.topViewController === self else { return }
        guard let sheet = navigationController?.sheetPresentationController,
              sheet.selectedDetentIdentifier != .large else { return }
        expandedForKeyboard = true
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        coverChanged()
    }

    private func keyboardWillHide() {
        // Not for an alert or menu raised over the sheet: it takes the keyboard
        // for a moment, and the sheet would move and come
        // back behind it.
        guard (navigationController ?? self).presentedViewController == nil else { return }
        guard expandedForKeyboard, let sheet = navigationController?.sheetPresentationController else { return }
        expandedForKeyboard = false
        sheet.animateChanges { sheet.selectedDetentIdentifier = Self.restingDetentIdentifier }
        coverChanged()
    }

    // MARK: - Resting height

    static let restingDetentIdentifier = UISheetPresentationController.Detent.Identifier("textPost.resting")

    /// The sheet's resting detent: the system's medium height, unless the
    /// invitation cannot show whole there.
    ///
    /// ⚠️ ONLY WHEN CENTRING CANNOT WORK. At the default text size the medium
    /// height leaves the stream room enough, and the invitation is centred in
    /// it (`SnapCommentsLayout.emptyPageHeight`). At accessibility sizes on an
    /// iPhone SE the block is taller than that room, and its subtitle went
    /// under the composer. The sheet then rests just tall enough to show it
    /// whole, and never taller than its large height.
    func makeRestingDetent() -> UISheetPresentationController.Detent {
        .custom(identifier: Self.restingDetentIdentifier) { [weak self] context in
            // Medium is inactive in a compact height — an iPhone on its side —
            // and so is this: the sheet is full height there, as it was.
            guard let medium = UISheetPresentationController.Detent.medium().resolvedValue(in: context) else {
                return nil
            }
            return Self.restingHeight(
                medium: medium,
                maximum: context.maximumDetentValue,
                floor: MainActor.assumeIsolated { self?.restingFloor }
            )
        }
    }

    /// The medium height, raised to `floor` when there is one, and never past
    /// the sheet's largest height.
    nonisolated static func restingHeight(medium: CGFloat, maximum: CGFloat, floor: CGFloat?) -> CGFloat {
        guard let floor else { return medium }
        return min(maximum, max(medium, floor))
    }

    /// Re-reads how tall the sheet has to rest for the invitation to show
    /// whole, and re-resolves the detent only when that changed.
    private func updateRestingFloor() {
        // While writing only: a published post's page scrolls like any other.
        let needed = publishedEntry == nil
            ? panel.viewHeightShowingEmptyPage(contentSizeCategory: traitCollection.preferredContentSizeCategory)
            : nil
        // A detent's value leaves out the bottom safe area, which this view's
        // height includes.
        let floor = needed.map { $0 - (view.window?.safeAreaInsets.bottom ?? 0) }
        switch (floor, restingFloor) {
        case (nil, nil): return
        case let (new?, old?) where abs(new - old) < 0.5: return
        default: break
        }
        restingFloor = floor
        guard navigationController?.sheetPresentationController != nil, !detentInvalidationQueued else { return }
        // ⚠️ NEVER FROM INSIDE THE LAYOUT PASS. This runs from
        // `viewSafeAreaInsetsDidChange`, and invalidating the sheet's detents
        // there re-lays the sheet — its safe area again — within the same
        // pass: on an iPhone SE (no bottom inset) the nesting ran the main
        // thread's stack out inside the bar's layout and the app died on
        // opening the composer. One invalidation, on the next turn.
        detentInvalidationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            detentInvalidationQueued = false
            guard let sheet = navigationController?.sheetPresentationController else { return }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// A detent invalidation is on its way (`updateRestingFloor`).
    private var detentInvalidationQueued = false

    // MARK: - Published

    /// The first message went out: the page is the post's now. The panel did
    /// its own half (caption row, "No comments yet", a composer that
    /// comments); these are the bars.
    private func becomePublished(_ entry: FeedEntry) {
        if let editingDraftID { drafts.delete(editingDraftID) }
        editingDraftID = nil
        // The card is the post's now, drawn on its page (#2216).
        dropShowcaseAttachment()
        let model = FeedDisplayModelBuilder().build(entry, now: Date())
        publishedEntry = entry
        publishedModel = model
        updateRestingFloor()
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
        closeItem = BarItems.icon(id: ItemID.close, image: UIImage(systemName: "xmark"), label: "Close") { [weak self] in
            self?.close()
        }
        commentTabs.bind(to: panel)
        sortItem = BarItems.container(id: ItemID.commentTabs, view: commentTabs.tabBar)
        applyLeadingItems(animated: true)

        // Your own post: there is nobody to follow.
        authorPill.setFollowBadge(.none)
        authorPill.setOverMedia(false)
        authorPill.setAuthor(model, pipeline: imagePipeline)
        // The viewer's own pill (#2145): the card resolves to the profile,
        // so a tap and a hold both push it.
        let openOwnProfile: (ProfileID) -> Void = { [weak self] id in
            self?.router?.route(to: .profile(
                id, stub: ProfileIdentityStub(handle: author.handle, displayName: author.displayName)
            ))
        }
        authorPill.onAuthorTapped = openOwnProfile
        authorPill.onAuthorLongPressed = openOwnProfile
        var trailing = [BarItems.container(id: ItemID.authorPill, view: authorPill)]
        if let walletItem = makeWalletItem() {
            trailing += [.fixedSpace(Spacing.sm), walletItem]
        }
        setOwnTrailingBarItems(trailing, animated: true)

        attribution.setOverMedia(false)
        attribution.setPost(model, pipeline: imagePipeline)
        bookmarkItem.isEnabled = true
        refreshBookmarkGlyph()
        moreItem.menu = UIMenu(children: [
            UIAction(title: "Share", image: AppSymbol.share.image()) { [weak self] _ in
                self?.sharePost()
            },
        ])
        moreItem.isEnabled = true
        setToolbarItems(SnapFooterToolbar.items(
            leading: attribution,
            leadingID: ItemID.attribution,
            actions: [bookmarkItem, repostItem],
            more: moreItem
        ), animated: true)
        fitTrailingRun()
    }

    /// [✕], and the Popular | Recent selector beside it once the thread has its tabs — the
    /// text page's leading group, with the fixed space that keeps two pills.
    private func applyLeadingItems(animated: Bool) {
        guard let closeItem else { return }
        var items = [closeItem]
        if isSortAvailable, let sortItem { items += [leadingSortSpacer, sortItem] }
        guard navigationItem.leftBarButtonItems ?? [] != items else { return }
        navigationItem.setLeftBarButtonItems(items, animated: animated)
    }

    private func commentCountDidChange(_ count: Int) {
        let available = panel.showsPopular
        guard available != isSortAvailable else { return }
        isSortAvailable = available
        applyLeadingItems(animated: true)
        fitTrailingRun()
    }

    /// The author pill's share of the bar: the bar less its margins, the ✕,
    /// the sort when it is there and the balance — the text page's arithmetic
    /// (see `SnapBarPillWidths`, the feed's). Applied
    /// before the bar lays the run out, or the whole item collapses to `•••`.
    private func fitTrailingRun() {
        guard publishedModel != nil else { return }
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        let pad: CGFloat = 18
        // The ✕ is a stock item now (#1679): a bar bubble, 44 wide.
        var budget = bar - 16 * 2 - (44 + pad) - pad
        if isSortAvailable {
            budget -= commentTabs.width + pad + Spacing.sm
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
        let item = BarItems.container(id: BarItems.SharedID.walletBalance, view: walletBadge)
        walletBadgeItem = item
        // A grown count needs a FRESH item — re-adding the same one hands the
        // bar the same frozen wrapper (the feed's measured finding).
        walletBadge.onFittedWidthChange = { [weak self] in self?.refreshWalletItem() }
        refreshWalletBadge()
        walletObservers.replace(with: [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWalletBadge() }
            },
        ])
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
              case var items = ownTrailingBarItems,
              let index = items.firstIndex(of: old) else { return }
        let fresh = BarItems.container(id: BarItems.SharedID.walletBalance, view: walletBadge)
        walletBadgeItem = fresh
        items[index] = fresh
        setOwnTrailingBarItems(items, animated: false)
        fitTrailingRun()
    }

    private func presentWalletSheet() {
        guard let makeWalletSheet, presentedViewController == nil else { return }
        present(makeWalletSheet(), animated: true)
    }

    private func toggleBookmark() {
        guard let id = publishedModel?.id else { return }
        // The fill says it; the hand feels it, saving only (#803, #1881).
        Feedback.toggled(on: bookmarks.toggle(id.rawValue))
        refreshBookmarkGlyph()
    }

    /// The glyph's symbol as last drawn.
    private var drawnBookmarkSymbol = AppSymbol.save.rawValue

    /// Draws the published post's saved state — on publish, on a tap, and
    /// when its saved fact changes anywhere (`savedObservation`).
    private func refreshBookmarkGlyph() {
        guard let id = publishedModel?.id else { return }
        let saved = bookmarks.isSaved(id.rawValue)
        drawnBookmarkSymbol = SnapFeedViewController.bookmarkSymbol(saved: saved)
        bookmarkItem.accessibilityLabel = saved ? "Saved" : "Save"
        bookmarkItem.image = SnapFooterToolbar.saveImage(saved: saved)
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
    /// The showcase the draft will publish (#2216): its card and its place.
    var debugDraftShowcase: DraftShowcase? { panel.viewModel.draftShowcase }
    var debugRestingFloor: CGFloat? { restingFloor }
    /// The published post's id, once there is one.
    var debugPublishedPostID: PostID? { publishedModel?.id }
    /// The save glyph as drawn: its symbol and its spoken label.
    var debugBookmarkGlyph: (symbol: String, label: String?) {
        (drawnBookmarkSymbol, bookmarkItem.accessibilityLabel)
    }

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

/// A resting height, and large for a thread or the keyboard (#1970): it
/// covers the clips behind only at large. The default reads the detent; a
/// drag is heard through the presentation's delegate, which is this screen.
extension TextPostComposerViewController: ScreenCovering, UISheetPresentationControllerDelegate {
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheetPresentationController: UISheetPresentationController
    ) {
        coverChanged()
    }
}
