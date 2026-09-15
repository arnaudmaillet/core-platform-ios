// `AVURLAsset` — the trim is resolved against the FILE's length, not the item's
// declared one. See the note in `post()`.
import AVFoundation
import CoreModels
import DesignSystem
import UIKit

/// The last step of posting media: what was chosen, what it is called, and how
/// the author wants it to behave once it is out.
///
/// ```
/// ┌──────────────────────────┐
/// │ ‹ Save draft        Post │
/// │  ▣▣▣  the chosen media   │  ← full width, no card
/// │  ⧉ Change cover          │
/// ├──────────────────────────┤
/// │ Add a title              │
/// │ Write a caption…         │
/// ├──────────────────────────┤
/// │ Disclose as AI      [ ]  │
/// │ Comments          On ⌄   │
/// │ Hide points         [ ]  │
/// │ Hide reposts        [ ]  │
/// │ Hide bookmarks      [ ]  │
/// │ Allow downloads     [x]  │
/// └──────────────────────────┘
/// ```
///
/// ## ⚠️ What this screen can and cannot do
///
/// **The media and the caption are real. Nearly everything else is local.**
/// `post.v1.CreatePostRequest` carries `profileID`, `kind`, `caption`,
/// `attachments`, `parentID`, `rootID`, `audioRef` and `location` — and nothing
/// else. So:
///
/// - **The cover WORKS.** There is no cover field, but the FIRST attachment is
///   what every grid and feed shows a post by, and array order is carousel
///   order — so choosing a cover reorders what is published. This is the one
///   control here that genuinely reaches the server.
/// - **The title is drawn and NOT sent** (`dev/BACKEND_GAPS.md` §21). Folding it
///   into the caption was rejected: it would publish a composite string no
///   reader could split apart again.
/// - **The six settings are honoured by this screen and by nothing else**
///   (§22). They are operable, they hold their state for the length of the
///   compose, and they are deliberately NOT persisted anywhere — a preference
///   that outlived this screen would imply a setting the fleet has never heard
///   of. The footer says so in plain words, which is the privacy screen's rule
///   (§13a): a local honour-system control is acceptable only while it admits it.
///
/// ⚠️ **VIDEOS PUBLISH, BUT THEY ARE NOT EDITABLE YET.** `MediaLibraryReading`
/// grew `videoFile(for:)` and a chosen clip now uploads, leads the carousel if
/// it is the cover, and carries a poster frame. What it does NOT carry is any of
/// this flow's edits: crop, straighten, mirror and filters are `UIImage`-to-
/// `UIImage` by signature, so the editor still shows a notice on a video page
/// (`dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4). A video is published exactly as it
/// was picked.
final class NewPostViewController: UIViewController {
    /// ⚠️ **THE SETTINGS ARE THREE SECTIONS, NOT ONE LIST.** Six switches in a
    /// single card is a wall: nothing in it tells the reader that hiding a
    /// count and disclosing AI are different kinds of decision. Grouped, each
    /// card asks one question — what the post says about itself, how people may
    /// engage with it, and what they may take away.
    private enum Section: Int, CaseIterable {
        case media
        case text
        case engagement
        case sharing
        case disclosure
    }

    private enum Row: Hashable {
        case media
        case cover
        case title
        case caption
        case aiDisclosure
        case comments
        case points
        case reposts
        case bookmarks
        case downloads
    }

    /// Everything the author decides about the post, beyond its content.
    ///
    /// ⚠️ **A PLAIN VALUE OWNED BY THE SCREEN, WITH NO STORE BEHIND IT.** Not
    /// `UserDefaults`, not `CoreStorage`, nothing app-wide: none of these
    /// choices can be transmitted (§22), so persisting one would turn a known
    /// gap into a setting the viewer believes they have.
    struct Settings: Equatable {
        enum Comments: CaseIterable {
            case enabled, hidden, disabled

            var name: String {
                switch self {
                case .enabled: "On"
                case .hidden: "Hidden"
                case .disabled: "Off"
                }
            }

            var explanation: String {
                switch self {
                case .enabled: "Anyone can reply to this post."
                case .hidden: "Replies are collected but not shown."
                case .disabled: "Nobody can reply to this post."
                }
            }
        }

        var comments: Comments = .enabled
        // ⚠️ **SHOW, NOT HIDE — AND ON BY DEFAULT.** Phrased as "Hide points"
        // these read as opt-in restrictions and default OFF, which means the
        // switch's resting position is the opposite of the behaviour: nothing
        // is hidden, yet every switch sits dark. Stated positively, the resting
        // position IS the behaviour, and a viewer skimming the section sees the
        // post's actual state rather than a list of things not done.
        var showsPoints = true
        var showsReposts = true
        var showsBookmarks = true
        var allowsDownloads = true
        // ⚠️ DELIBERATELY NOT DEFAULTED ON. This one lives in Disclosure, not
        // Engagement: switching it on by default would have every post claim it
        // was made with AI, which is a false statement rather than a permissive
        // default.
        var disclosesAI = false
    }

    /// The size a full-bleed thumbnail is asked for. Generous, because the
    /// published image comes from this same seam.
    private static let publishPixels = CGSize(width: 1080, height: 1080)

    /// Names this screen's own keyboard-dismiss tap, so it can be found among
    /// the recognisers the collection view installs for itself.
    static let dismissTapName = "newPost.dismissKeyboard"

    private let items: [MediaLibraryItem]
    /// How the author left each picture in the editor — see `MediaEdits`. Absent
    /// means untouched. The crop and the look are baked into what is uploaded
    /// (see `post()`); the fit is honoured by the screens that draw the picture.
    private let edits: [String: MediaEdits]
    private let library: any MediaLibraryReading
    private let composer: any PostComposing
    /// Where a published post hands back to — the flow's own dismissal.
    private let onPublished: (FeedEntry) -> Void

    /// What the author has already written, carried across a step back to the
    /// editor and forward again. Owned by the flow, not by this screen — this one
    /// is rebuilt on every "Next".
    private let draft: PostDraft

    private var postTitle = ""
    private var caption = ""
    private var settings = Settings()
    private var isPublishing = false

    /// Which chosen item leads the carousel — a photo or a video.
    private var coverID: String?

    private var list: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    private lazy var postItem = UIBarButtonItem(
        title: "Post",
        primaryAction: UIAction { [weak self] _ in self?.post() }
    )

    /// ⚠️ DRAWN AND INERT, like the editor's. Media drafts do not exist —
    /// `MediaDraftsViewController` is an empty list waiting for the notion — and
    /// `PostDraftStore` holds text only.
    private lazy var saveDraftItem = UIBarButtonItem(
        title: "Save draft", style: .plain, target: nil, action: nil
    )


    /// What will actually be published, in order: the cover first, then the rest
    /// as they were chosen. The strip shows this, so changing the cover visibly
    /// moves it to the front.
    private var publishOrder: [MediaLibraryItem] {
        guard let coverID, let cover = items.first(where: { $0.id == coverID }) else { return items }
        return [cover] + items.filter { $0.id != coverID }
    }

    init(
        items: [MediaLibraryItem],
        edits: [String: MediaEdits] = [:],
        library: any MediaLibraryReading,
        composer: any PostComposing,
        draft: PostDraft = PostDraft(),
        onPublished: @escaping (FeedEntry) -> Void
    ) {
        self.items = items
        self.edits = edits
        self.library = library
        self.composer = composer
        self.draft = draft
        self.onPublished = onPublished
        // ⚠️ **RESTORED BEFORE THE FIRST LAYOUT, NOT AFTER.** This screen is
        // rebuilt from scratch every time "Next" is pressed, so stepping back to
        // the editor and forward again used to hand the author an empty form.
        self.postTitle = draft.title
        self.caption = draft.caption
        self.settings = draft.settings
        // ⚠️ AN EXPLICIT PICK WINS OVER THE DEFAULT; NOTHING PICKED FALLS BACK.
        // The default below is computed, so storing it in the draft would make a
        // real choice indistinguishable from never having chosen.
        // ⚠️ **THE FIRST ITEM, NOT THE FIRST PHOTO.** This skipped videos while
        // they could not be published; keeping that would silently reorder a
        // selection that leads with a clip, handing the post a face its author
        // did not put first.
        self.coverID = draft.coverID ?? items.first?.id
        super.init(nibName: nil, bundle: nil)
        // ⚠️ THE TOP BAR BELONGS TO THE SCREEN, NOT TO ITS VIEW — a navigation
        // controller reads `navigationItem` on the way in. The picker and the
        // editor carry the same note.
        configureBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ NO TITLE, DELIBERATELY. The bar is `[‹][Save draft] ——— [Post]` and
        // nothing else: a centred title here competes with the two words either
        // side of it on a phone, and the screen's subject is the media directly
        // underneath.
        view.backgroundColor = .systemGroupedBackground
        configureList()
        applyRows()
    }

    // MARK: - Bars

    private func configureBars() {
        // ⚠️ **UIKit'S OWN BACK BUTTON, BECAUSE THE BACK-SWIPE COMES WITH IT** —
        // see the editor's note for the measurement. A custom leading item
        // replaces the back button and silently takes the interactive pop with
        // it; `leftItemsSupplementBackButton` is what makes the item sit BESIDE
        // the chevron instead of in its place.
        navigationItem.leftBarButtonItems = [saveDraftItem]
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.rightBarButtonItems = [postItem]
        postItem.style = .done
    }

    // MARK: - The list

    /// ⚠️ **TWO APPEARANCES IN ONE LAYOUT, AND THAT IS THE POINT.** The media is
    /// the subject of this screen, not a row in a settings list: its section is
    /// drawn PLAIN with a clear background so the strip runs the full width with
    /// no white card behind it. Everything below is `.insetGrouped`, the shape
    /// every settings surface in this app already wears.
    private func configureList() {
        list = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        list.backgroundColor = .clear
        list.keyboardDismissMode = .interactive
        // ⚠️ **DISMISSING A KEYBOARD IS NOT THE SAME AS MAKING ROOM FOR ONE.**
        // This screen had the dismiss mode and a dismiss tap and nothing else,
        // so the field being typed into simply sat under the keyboard.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        // ⚠️ NOTHING ON THIS SCREEN IS SELECTABLE. Every control is a switch, a
        // menu button or a text field — so a row that greys itself under a
        // finger is announcing a selection that does not exist.
        list.allowsSelection = false
        list.pin(to: view)

        // ⚠️ NON-CANCELLING, OR IT EATS THE CONTROLS. The switches, the
        // Comments menu and "Change cover" must see every touch unchanged; this
        // only retires the keyboard, and is a no-op when nothing is editing.
        // PostDetail's stream tap sets the precedent.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        // ⚠️ NAMED, so a test can ask about THIS tap. A collection view installs
        // tap recognisers of its own and those DO cancel touches — an assertion
        // over "every tap on the list" fails on UIKit's rather than on ours, as
        // the first version of that test duly did.
        dismissTap.name = Self.dismissTapName
        list.addGestureRecognizer(dismissTap)

        let media = UICollectionView.CellRegistration<NewPostMediaCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.show(publishOrder, coverID: coverID, edits: edits) { [weak self] id, size in
                await self?.library.thumbnail(for: id, size: size)
            }
        }
        let cover = UICollectionView.CellRegistration<NewPostButtonCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.backgroundConfiguration = .clear()
            cell.configure(
                title: "Change cover",
                symbolName: "square.on.square",
                menu: coverMenu(),
                // One photo is no choice, and none at all is not a cover.
                isEnabled: items.count > 1
            )
        }
        let title = UICollectionView.CellRegistration<NewPostTitleCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            // ⚠️ WRITTEN TO BOTH, AT THE SAME MOMENT. The draft is not a snapshot
            // taken on the way out — this screen can be torn down without a clean
            // transition, which is exactly the path that used to lose the text.
            cell.configure(text: postTitle) { [weak self] text in
                self?.postTitle = text
                self?.draft.title = text
            }
        }
        let caption = UICollectionView.CellRegistration<NewPostCaptionCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(text: self.caption) { [weak self] text in
                self?.caption = text
                self?.draft.caption = text
            }
        }
        let comments = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Comments"
            content.secondaryText = settings.comments.explanation
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            var configuration = UIButton.Configuration.gray()
            configuration.title = settings.comments.name
            configuration.image = UIImage(systemName: "chevron.up.chevron.down")
            configuration.imagePlacement = .trailing
            configuration.imagePadding = Spacing.xs
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            let button = UIButton(configuration: configuration)
            button.showsMenuAsPrimaryAction = true
            button.menu = self.commentsMenu()
            button.accessibilityLabel = "Comments, \(settings.comments.name)"
            cell.accessories = [.customView(configuration: .init(
                customView: button, placement: .trailing(displayed: .always)
            ))]
        }
        // ⚠️ A `UISwitch` IN THE ACCESSORY, so the whole row is not selectable —
        // the switch is the only control, and a row-wide tap target that toggles
        // nothing reads as broken. Profile's privacy screen sets this precedent.
        let toggle = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self, let spec = toggleSpec(for: row) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = spec.title
            content.secondaryText = spec.subtitle
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            let control = UISwitch()
            control.isOn = spec.isOn
            control.addAction(
                UIAction { [weak self] action in
                    guard let control = action.sender as? UISwitch else { return }
                    self?.setToggle(control.isOn, for: row)
                },
                for: .valueChanged
            )
            cell.accessories = [.customView(configuration: .init(
                customView: control, placement: .trailing(displayed: .always)
            ))]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { view, indexPath, row in
            switch row {
            case .media: view.dequeueConfiguredReusableCell(using: media, for: indexPath, item: row)
            case .cover: view.dequeueConfiguredReusableCell(using: cover, for: indexPath, item: row)
            case .title: view.dequeueConfiguredReusableCell(using: title, for: indexPath, item: row)
            case .caption: view.dequeueConfiguredReusableCell(using: caption, for: indexPath, item: row)
            case .comments: view.dequeueConfiguredReusableCell(using: comments, for: indexPath, item: row)
            case .aiDisclosure, .points, .reposts, .bookmarks, .downloads:
                view.dequeueConfiguredReusableCell(using: toggle, for: indexPath, item: row)
            }
        }

        // The footer is where the screen admits what it cannot do.
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, indexPath in
            guard let self, let section = Section(rawValue: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedFooter()
            content.text = footerText(for: section)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            guard let self, let section = Section(rawValue: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = headerText(for: section)
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : view.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = Section(rawValue: index) else { return nil }
            var configuration: UICollectionLayoutListConfiguration
            switch section {
            case .media:
                configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.backgroundColor = .clear
                configuration.showsSeparators = false
            case .text, .disclosure, .engagement, .sharing:
                configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            }
            // Asked for only where there is something to say: an empty header or
            // footer still takes a band of space.
            configuration.headerMode = headerText(for: section) == nil ? .none : .supplementary
            configuration.footerMode = footerText(for: section) == nil ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func headerText(for section: Section) -> String? {
        switch section {
        case .media, .text: nil
        case .disclosure: "Disclosure"
        case .engagement: "Engagement"
        case .sharing: "Sharing"
        }
    }

    private func footerText(for section: Section) -> String? {
        switch section {
        case .media:
            nil
        case .text:
            "Titles aren't carried by the server yet, so only the caption is published."
        case .engagement, .sharing:
            nil
        case .disclosure:
            // ⚠️ ONE ADMISSION, ON THE LAST OF THE THREE CARDS — which is now
            // Disclosure. Repeating it under every settings section would nag;
            // leaving it out entirely would let six working controls imply a
            // promise the server never made.
            """
            These choices apply while you're composing. They aren't sent with the \
            post yet — comments stay on, counts stay visible, and every post is \
            public.
            """
        }
    }

    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.media, .cover], toSection: .media)
        snapshot.appendItems([.title, .caption], toSection: .text)
        snapshot.appendItems([.comments, .points, .reposts, .bookmarks], toSection: .engagement)
        snapshot.appendItems([.downloads], toSection: .sharing)
        snapshot.appendItems([.aiDisclosure], toSection: .disclosure)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Re-runs the registration for rows whose value changed under them.
    private func reconfigure(_ rows: [Row]) {
        var snapshot = dataSource.snapshot()
        let present = rows.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Gives the list up exactly as much room as the keyboard takes, and brings
    /// whatever is being edited into what is left.
    ///
    /// ⚠️ **THE FRAME IS CONVERTED, NEVER USED RAW.** The notification carries
    /// the keyboard in SCREEN coordinates, and this screen is a sheet — its view
    /// and the screen do not share an origin, so a raw frame over-insets by the
    /// sheet's own offset and pushes the content further than the keyboard ever
    /// covered.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let inView = view.convert(end, from: nil)
        // The safe-area inset is already room the list was never using, so it is
        // taken off — otherwise the home-indicator band is paid for twice.
        let overlap = max(0, view.bounds.maxY - inView.minY - view.safeAreaInsets.bottom)
        list.contentInset.bottom = overlap
        list.verticalScrollIndicatorInsets.bottom = overlap
        // Only on the way IN. On dismissal the overlap is zero and scrolling
        // then would jerk the list for no reason.
        guard overlap > 0 else { return }
        revealEditingField()
    }

    private func revealEditingField() {
        guard let editing = firstResponder(in: view) else { return }
        let frame = list.convert(editing.bounds, from: editing)
        // A little air above and below, so the caret never sits on the seam
        // between the field and the keyboard.
        list.scrollRectToVisible(frame.insetBy(dx: 0, dy: -12), animated: true)
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = firstResponder(in: sub) { return found }
        }
        return nil
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - The cover

    /// ⚠️ **EVERY ITEM, PHOTOS AND VIDEOS ALIKE — AND THE OLD REASON FOR
    /// EXCLUDING VIDEOS HAS EXPIRED.** This read "photos only", because a video
    /// could not be published and offering one would have promised a face the
    /// post never wore. A video now publishes and carries a poster frame, so it
    /// can lead the carousel like anything else.
    ///
    /// The number is the item's place in the selection, not its place among its
    /// own kind: "Video 2" is the second thing chosen, so the label answers
    /// "which one" rather than "which video".
    private func coverMenu() -> UIMenu {
        UIMenu(children: items.enumerated().map { index, item in
            UIAction(
                title: "\(item.isVideo ? "Video" : "Photo") \(index + 1)",
                state: item.id == coverID ? .on : .off
            ) { [weak self] _ in
                self?.setCover(item.id)
            }
        })
    }

    private func setCover(_ id: String) {
        guard coverID != id else { return }
        coverID = id
        // ⚠️ ONLY AN EXPLICIT PICK IS RECORDED. The initialiser computes a default
        // cover, so storing that would make "the author chose the first photo"
        // and "the author chose nothing" the same state on the way back.
        draft.coverID = id
        reconfigure([.media, .cover])
    }

    // MARK: - The settings

    private func toggleSpec(for row: Row) -> (title: String, subtitle: String, isOn: Bool)? {
        switch row {
        case .aiDisclosure:
            ("Disclose as AI-generated", "Tell viewers this post was made with AI.", settings.disclosesAI)
        case .points:
            ("Show points", "Anyone can see how many points this post has.", settings.showsPoints)
        case .reposts:
            ("Show reposts", "Anyone can see how often it has been reposted.", settings.showsReposts)
        case .bookmarks:
            ("Show bookmarks", "Anyone can see how often it has been saved.", settings.showsBookmarks)
        case .downloads:
            ("Allow downloads", "Let anyone save this post to their device.", settings.allowsDownloads)
        default:
            nil
        }
    }

    /// Written through immediately rather than behind a Save button: these are
    /// switches, and a switch that needs confirming is one the viewer will
    /// assume already took effect.
    private func setToggle(_ isOn: Bool, for row: Row) {
        switch row {
        case .aiDisclosure: settings.disclosesAI = isOn
        case .points: settings.showsPoints = isOn
        case .reposts: settings.showsReposts = isOn
        case .bookmarks: settings.showsBookmarks = isOn
        case .downloads: settings.allowsDownloads = isOn
        // ⚠️ `Row` CARRIES TEN CASES AND ONLY FIVE ARE SWITCHES. The rest —
        // media, cover, title, caption, comments — never reach here, so leaving
        // early is both the exhaustiveness the compiler wants and a refusal to
        // rewrite the draft for a row that changed nothing.
        default: return
        }
        // ⚠️ THE SETTINGS TRAVEL TOO. The request was the creation PROCESS, not
        // the text field: a switch flipped before stepping back to the editor
        // would otherwise come back to its default.
        draft.settings = settings
    }

    private func commentsMenu() -> UIMenu {
        UIMenu(children: Settings.Comments.allCases.map { choice in
            UIAction(
                title: choice.name,
                state: settings.comments == choice ? .on : .off
            ) { [weak self] _ in
                self?.setComments(choice)
            }
        })
    }

    private func setComments(_ choice: Settings.Comments) {
        guard settings.comments != choice else { return }
        settings.comments = choice
        // The comments choice has its own write site, separate from the toggles —
        // missing it would carry four settings across the step back and drop one.
        draft.settings = settings
        reconfigure([.comments])
    }

    // MARK: - Publishing

    /// ⚠️ **IN THE ORDER THEY WILL APPEAR.** The array's order is the carousel's
    /// order — `post.v1` has no per-attachment index — so the media are fetched
    /// one at a time rather than through a task group that would return them in
    /// whatever order the library answered. The cover leads because
    /// `publishOrder` puts it there.
    ///
    /// Photos and videos take different routes out of the library and meet again
    /// as `ComposeMedia`: a photo is read at publish size and baked with its
    /// edits, a video is read as a file and handed over with the part of it the
    /// author kept. Both consult `edits`; they use different fields of it, and a
    /// video uses only `trim` — crop and filters are still `UIImage`-to-`UIImage`
    /// by signature (`dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4).
    ///
    /// The title and the six settings are NOT sent: nothing in the contract
    /// carries them (§21, §22).
    private func post() {
        guard !isPublishing else { return }
        isPublishing = true
        postItem.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            do {
                var media: [ComposeMedia] = []
                for item in publishOrder {
                    if item.isVideo {
                        // ⚠️ **A VIDEO THAT CANNOT BE READ STOPS THE POST; A
                        // PHOTO THAT CANNOT BE READ IS SKIPPED. THE ASYMMETRY IS
                        // DELIBERATE.** The grid has already drawn every photo,
                        // so `thumbnail` here is a second successful read of
                        // something that was on screen a moment ago. This is the
                        // FIRST time a video's actual bytes are touched — the
                        // grid only ever had its poster — and the usual reason
                        // it fails is an iCloud download that did not finish.
                        // That is worth telling the author about; publishing a
                        // shorter carousel than they assembled is not. Dropping
                        // videos in silence is the whole defect this screen is
                        // being fixed of.
                        guard let file = await library.videoFile(for: item.id) else {
                            throw ComposeError.media(
                                "Couldn't read one of the videos. It may still be downloading from iCloud."
                            )
                        }
                        // ⚠️ **RESOLVED HERE, AGAINST THE DECLARED DURATION.**
                        // A stored trim is two numbers that can outlive the clip
                        // they were made for; what crosses to the composer is
                        // the answer, already brought inside a real length.
                        // `cuts` rather than `!isWhole`: a range covering the
                        // whole clip is the same instruction as no range at all,
                        // and only nil takes the exporter's passthrough.
                        // ⚠️ **AGAINST THE FILE'S OWN LENGTH, NOT THE ITEM'S
                        // DECLARED ONE.** The declaration is whatever vended the
                        // item said, and it can disagree with the bytes — under
                        // `-rich-media` a fixture whose download failed falls
                        // back to a synthetic clip, so an item can truthfully
                        // say 52 seconds over a file of two and a half.
                        // Resolving against the declaration would hand the
                        // exporter a range past the end and publish nothing.
                        // The editor's strip asks the same question of the same
                        // asset, so the two cannot drift apart.
                        var kept: ClosedRange<Double>?
                        let declared: Double
                        if case .video(let seconds) = item.kind { declared = seconds } else { declared = 0 }
                        let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? declared
                        let length = real.isFinite && real > 0 ? real : declared
                        let trim = (edits[item.id] ?? .untouched).trim
                        if MediaTrimming.cuts(trim, within: length) {
                            kept = MediaTrimming.resolved(trim, within: length)
                        }
                        media.append(
                            .video(PickedVideo(sourceURL: file, keptSeconds: kept))
                        )
                        continue
                    }
                    guard let image = await library.thumbnail(for: item.id, size: Self.publishPixels) else {
                        continue
                    }
                    // ⚠️ **BAKED HERE, ON THE FULL-RESOLUTION PICTURE.** The editor
                    // showed the crop and the look on a canvas-sized render and on a
                    // 56pt chip; neither of those is what gets uploaded. Both are
                    // applied to the publish-sized image and BEFORE `MediaEncoder`,
                    // which downscales and compresses — rendering after that would
                    // work on pixels the viewer never approved.
                    //
                    // ⚠️ THE ORDER IS CUT THEN DRESS, and it lives in one place:
                    // `MediaEdits.applied(to:)`, which four render paths share so
                    // they cannot drift apart.
                    //
                    // ⚠️ A FAILED RENDER PUBLISHES THE ORIGINAL RATHER THAN NOTHING.
                    // Dropping the picture because a crop or a filter could not be
                    // rasterised would lose the author's photograph over a
                    // decoration. `applied(to:)` carries that rule.
                    let baked = (edits[item.id] ?? .untouched).applied(to: image)
                    media.append(.image(PickedImage(baked)))
                }
                let entry = try await composer.publish(media: media, caption: caption, as: nil)
                onPublished(entry)
                // The flow ends here: the whole sheet goes, not just this screen.
                dismiss(animated: true)
            } catch {
                isPublishing = false
                postItem.isEnabled = true
                present(Self.failureAlert(error), animated: true)
            }
        }
    }

    private static func failureAlert(_ error: Error) -> UIAlertController {
        let alert = UIAlertController(
            title: "Couldn't post",
            message: (error as? ComposeError).map(message(for:)) ?? "Something went wrong. Try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    private static func message(for error: ComposeError) -> String {
        switch error {
        case .emptyPost: "Add a photo or write something first."
        case .notAuthenticated, .noViewerProfile: "Sign in again to post."
        case .media(let why): why
        case .transport(let why): why
        }
    }
}

#if DEBUG
extension NewPostViewController {
    /// Internal for tests: the rows the screen is showing, in order.
    var debugRowCount: Int { dataSource.snapshot().numberOfItems }
    /// Internal for tests: what the caption holds.
    var debugCaption: String { caption }
    /// Internal for tests: what the title holds — which is never published.
    var debugTitle: String { postTitle }
    /// Internal for tests: the choices the author has made.
    var debugSettings: Settings { settings }
    /// Internal for tests: which photo leads the carousel.
    var debugCoverID: String? { coverID }
    /// Internal for tests: what would actually be published, in order.
    var debugPublishOrder: [String] { publishOrder.map(\.id) }
    /// Internal for tests: the footer a section is wearing, if any.
    func debugFooterText(forSection index: Int) -> String? {
        Section(rawValue: index).flatMap(footerText(for:))
    }
    /// Internal for tests: whether a row can be selected at all.
    ///
    /// ⚠️ PINNED AS A PROPERTY, NOT AS A SCREENSHOT. A selection highlight
    /// exists only while a finger is down and clears on release, so a capture
    /// taken after the tap shows the resting state whether selection is on or
    /// off — it cannot tell the two apart. This can.
    var debugAllowsSelection: Bool { list.allowsSelection }

    /// Internal for tests: whether THIS screen's dismiss tap swallows the touch.
    /// Nil when it is not installed at all.
    ///
    /// ⚠️ **ASKED OF OUR TAP BY NAME.** A `UICollectionView` installs tap
    /// recognisers of its own and they DO cancel touches, so "no tap on the list
    /// cancels" is false for reasons that have nothing to do with this screen.
    /// The first version of this accessor returned every tap and the test failed
    /// on UIKit's, not on ours.
    var debugDismissTapCancelsTouches: Bool? {
        (list.gestureRecognizers ?? [])
            .first { $0.name == Self.dismissTapName }?
            .cancelsTouchesInView
    }

    /// Internal for tests: the header a section is wearing, if any.
    func debugHeaderText(forSection index: Int) -> String? {
        Section(rawValue: index).flatMap(headerText(for:))
    }
    /// Internal for tests: how many sections the screen draws, and how many
    /// rows sit in each.
    var debugSectionCount: Int { dataSource.snapshot().numberOfSections }
    func debugRowCount(inSection index: Int) -> Int {
        guard let section = Section(rawValue: index) else { return 0 }
        return dataSource.snapshot().numberOfItems(inSection: section)
    }
    /// Internal for tests: the cover menu, without a button to press.
    func debugCoverMenu() -> UIMenu { coverMenu() }
    /// Internal for tests: choosing a cover, without a menu to open.
    func debugSetCover(_ id: String) { setCover(id) }
    /// Internal for tests: moving one switch, without a bar to reach it.
    func debugSetComments(_ choice: Settings.Comments) { setComments(choice) }
    /// Internal for tests: typing, without a keyboard. These write where the
    /// cells write, so what `post()` reads afterwards is what a viewer's typing
    /// would have left there.
    func debugType(title: String) { postTitle = title }
    func debugType(caption: String) { self.caption = caption }
    /// Internal for tests: the path "Post" takes, without a bar to tap.
    func debugTapPost() { post() }
}
#endif
