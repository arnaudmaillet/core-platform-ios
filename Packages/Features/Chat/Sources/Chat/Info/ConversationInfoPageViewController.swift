import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import UIKit

/// What a group's and a channel's info screens share (#2237): the profile's
/// and the place's page (`HeroPageViewController`) drawing a conversation.
///
/// - **The header** (`HeroHeaderView`): the photo or the initials in the
///   disc, the name, the subtitle, the description, the link, the counters,
///   the action row — from a `ConversationInfoHeader`.
/// - **The counters open the lists** (`PersonListsViewController`), on the
///   counter's tab, as a profile's Followers and Following do; the screen
///   is their source and hands each request to its subclass.
/// - **The bar**: the bell (`MuteMenu`, shared with the thread's) and the
///   "⋯", native items (#1679), never a control of our own.
/// - **The page under the header**: Posts, through the page factory the
///   profile and the place use (`FeedFeatureBuilding.makePostGridPage`).
///
/// Pushed from the thread's header, it closes with the native pop it came
/// with (`.nativeBack`). Every rule stays in the view models: a subclass
/// tells this what to show and does what it is asked.
class ConversationInfoPageViewController: HeroPageViewController<ConversationInfoTab> {
    let isChannel: Bool
    /// The header's counters, in order.
    let captions: [ConversationInfoList]
    let postsPage: any PostGridPage
    let imagePipeline: ImagePipeline?
    /// What the header shows now.
    private(set) var shownHeader: ConversationInfoHeader?
    /// The lists, while pushed.
    private(set) weak var listsScreen: PersonListsViewController?
    /// The action row's views, by action, as last built.
    private var actionViews: [(ConversationInfoAction, UIView)] = []
    /// The bell's state; nil: no bell (the viewer is not in).
    private(set) var bellMuted: Bool?

    init(channel: Bool, postsPage: any PostGridPage, imagePipeline: ImagePipeline?) {
        isChannel = channel
        captions = ConversationInfoList.counters(channel: channel)
        self.postsPage = postsPage
        self.imagePipeline = imagePipeline
        // The header needs a pipeline; a composition without one (a test)
        // draws placeholders.
        let pipeline = imagePipeline ?? ImagePipeline(fetcher: PlaceholderImageFetcher())
        let header = HeroHeaderView(imagePipeline: pipeline, counters: captions.map(\.caption), avatar: .person)
        // One page, so no selector is ever placed — and no docked slot: the
        // whole header climbs under the bar, as the place page's.
        super.init(
            header: header, pager: HeroPagePager(tabs: [ConversationInfoTab.posts], pages: [postsPage]),
            selectorBar: PagedTabBar(titles: ["Posts"], style: .navigationTitle), dockedSlot: 0
        )
        navigationItem.backButtonDisplayMode = .minimal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        for (stat, list) in zip(heroHeader.counters, captions) {
            stat.addAction(UIAction { [weak self] _ in self?.openLists(list) }, for: .touchUpInside)
        }
        heroHeader.onWebsiteTapped = { [weak self] url in self?.share(url, from: self?.heroHeader) }
        // The page's status action: the subclass says what it does.
        postsPage.onRefresh = { [weak self] in self?.postsActionTapped() }
        heroHeader.showsActionTray = false
        statusView.isHidden = true
    }

    // MARK: - What the subclass decides

    /// The lists the counters open, for the viewer now.
    func listTabs() -> [PersonListTab] { [] }
    /// The "⋯"'s entries, built when it opens.
    func moreMenuElements() -> [UIMenuElement] { [] }
    /// A view of the action row was tapped.
    func didTap(_ action: ConversationInfoAction, from view: UIView) {}
    /// The subtitle's owner was tapped.
    func openProfile(_ id: ProfileID, name: String) {}
    /// The Posts page's status action ("Share as a Post").
    func postsActionTapped() {}
    /// The bell: a tap, or a duration from its menu.
    func setMute(_ muted: Bool, until: Date?) {}
    /// A Try Again on a failed load.
    func reloadAll() {}

    // The lists' source (#2237): overridden by each kind.
    func listPage(of list: ConversationInfoList, after token: String?) async throws -> PersonListPage {
        PersonListPage(rows: [], nextPageToken: nil, total: 0)
    }
    func listRowAction(_ action: PersonListRowAction, on row: PersonListRow, in list: ConversationInfoList) {}
    func listAnswer(_ row: PersonListRow, approve: Bool) {}

    /// Whom an alert or a sheet is presented from: the screen on top — the
    /// lists, while pushed over this one, whose view has left the window.
    var presenter: UIViewController { navigationController?.topViewController ?? self }
    func listLeadingAction(in list: ConversationInfoList, from screen: PersonListsViewController) {}

    // MARK: - Drawing

    /// Draws `header`: the content, the counters a tap opens, the action
    /// row when it changed, and the lists' tab titles while pushed.
    func apply(_ header: ConversationInfoHeader) {
        let previous = shownHeader
        shownHeader = header
        heroHeader.configure(with: HeroHeaderContent(
            title: header.title, subtitle: header.subtitle, titleSymbol: header.titleSymbol, bio: header.bio,
            websiteText: header.linkText, websiteURL: header.linkURL,
            counterValues: header.counterValues(captions),
            avatarURL: header.photoURL, avatarMonogram: header.monogram
        ))
        for (stat, list) in zip(heroHeader.counters, captions) {
            stat.isTappable = header.openable.contains(list) && header.counters[list] != nil
        }
        if let owner = header.subtitleOwner {
            heroHeader.onSubtitleTapped = { [weak self] in self?.openProfile(owner, name: "") }
        } else {
            heroHeader.onSubtitleTapped = nil
        }
        if previous?.capsules != header.capsules || previous?.bubbles != header.bubbles {
            applyActions(capsules: header.capsules, bubbles: header.bubbles)
        }
        listsScreen?.setTabs(listTabs())
    }

    private func applyActions(capsules: [ConversationInfoAction], bubbles: [ConversationInfoAction]) {
        var row: [HeroHeaderAction] = []
        var views: [(ConversationInfoAction, UIView)] = []
        for action in capsules {
            // The way in is the row's one prominent capsule.
            let wayIn: Bool = action == .join || action == .requestToJoin
            let followOnly: Bool = action == .follow && !capsules.contains(.join)
            let prominent: Bool = wayIn || followOnly
            let button = AppButton(aspect: .pill(prominent ? .prominent : .quiet), size: .header, content: .title(action.title))
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                didTap(action, from: button)
            }, for: .primaryActionTriggered)
            row.append(.capsule(button))
            views.append((action, button))
        }
        for action in bubbles {
            let bubble = AppIconButton(style: .bubble(.quiet), content: .symbol(ConversationInfoAction.shareSymbol))
            bubble.accessibilityLabel = action.title
            bubble.addAction(UIAction { [weak self, weak bubble] _ in
                guard let self, let bubble else { return }
                didTap(action, from: bubble)
            }, for: .primaryActionTriggered)
            row.append(.bubble(bubble))
            views.append((action, bubble))
        }
        actionViews = views
        heroHeader.setActions(row)
        heroHeader.showsActionTray = !row.isEmpty
    }

    /// The Posts page's status for the viewer.
    func showPosts(_ status: PostGridPageStatus) {
        postsPage.show(.status(status))
    }

    /// A load that failed with nothing to show: the hero page's status
    /// block, with Try Again.
    func showFailure(_ message: String) {
        statusView.configure(
            symbolName: "exclamationmark.triangle", title: "Something went wrong", subtitle: message,
            actionTitle: "Try Again", actionHandler: { [weak self] in self?.reloadAll() }
        )
        statusView.isHidden = false
    }

    func hideFailure() { statusView.isHidden = true }

    // MARK: - The bar: the bell and the "⋯"

    static let bellID = "conversation-info.bell"
    static let moreID = "conversation-info.more"

    /// The "⋯": resolved when it opens, so it says the state then.
    private(set) lazy var moreItem: UIBarButtonItem = {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }])
        let item = BarItems.icon(id: Self.moreID, image: UIImage(systemName: "ellipsis"), label: "More", menu: menu)
        item.tintColor = .label
        return item
    }()

    /// The bell: a tap toggles the mute it shows, a long press offers how
    /// long — the thread's bell, the same menu (`MuteMenu`). Made once; its
    /// glyph and menu follow the mute (`applyBellLook`).
    private(set) lazy var bellItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: nil, image: UIImage(systemName: MuteMenu.symbol(muted: false)),
            primaryAction: UIAction { [weak self] _ in
                guard let self, let muted = bellMuted else { return }
                setMute(!muted, until: nil)
            },
            menu: nil
        )
        item.identifier = Self.bellID
        item.tintColor = .label
        item.accessibilityLabel = "Notifications"
        return item
    }()

    /// The trailing group for `muted` (nil: no bell): the "⋯" in the
    /// corner while it has something to offer, the bell inboard. A new set
    /// is written animated, never mid-push (an item added then lands
    /// unanimated at its end, #756); a changed mute redraws the glyph in
    /// place.
    func applyBar(muted: Bool?) {
        let had = bellMuted
        bellMuted = muted
        if let muted { applyBellLook(muted: muted, animated: had != nil && had != muted) }
        var items: [UIBarButtonItem] = []
        if !moreMenuElements().isEmpty { items.append(moreItem) }
        if muted != nil { items.append(bellItem) }
        guard !ownTrailingBarItems.elementsEqual(items, by: ===) else { return }
        if transitionCoordinator != nil, let navigationController {
            navigationController.whenAtRest { [weak self] in
                guard let self else { return }
                applyBar(muted: bellMuted)
            }
            return
        }
        setOwnTrailingBarItems(items, animated: view.window != nil)
    }

    private func applyBellLook(muted: Bool, animated: Bool) {
        let image = UIImage(systemName: MuteMenu.symbol(muted: muted))
        if animated, let image {
            bellItem.setSymbolImage(image, contentTransition: .replace)
        } else {
            bellItem.image = image
        }
        bellItem.accessibilityValue = MuteMenu.accessibilityValue(muted: muted)
        bellItem.menu = MuteMenu.make(muted: muted) { [weak self] duration in
            self?.setMute(true, until: duration.end())
        } onUnmute: { [weak self] in
            self?.setMute(false, until: nil)
        }
    }

    // MARK: - The lists behind the counters

    /// Pushes the lists on `list`'s tab — when the viewer may read it.
    func openLists(_ list: ConversationInfoList) {
        guard let header = shownHeader, header.openable.contains(list) else { return }
        let tabs = listTabs()
        guard tabs.contains(where: { $0.id == list.rawValue }) else { return }
        let screen = PersonListsViewController(
            title: header.title, tabs: tabs, initialTab: list.rawValue, source: self, imagePipeline: imagePipeline
        )
        listsScreen = screen
        navigationController?.pushViewController(screen, animated: true)
    }

    /// The lists read again after a write that changed them.
    func reloadLists() {
        listsScreen?.setTabs(listTabs())
        listsScreen?.reload()
    }

    // MARK: - Shared actions

    /// A link through the share sheet.
    func share(_ url: URL, from source: UIView?) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source ?? presenter.view
        presenter.present(share, animated: true)
    }

    /// A notice with OK.
    func presentNotice(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    /// The editing sheet: photo, name, description.
    func presentEditor(
        title: String, fields: ConversationEditViewController.Fields, photoURL: URL?, requiresName: Bool,
        namePlaceholder: String, save: @escaping (ConversationEditViewController.Fields) -> Void
    ) {
        let editor = ConversationEditViewController(
            title: title, fields: fields, photoURL: photoURL, imagePipeline: imagePipeline,
            requiresName: requiresName, namePlaceholder: namePlaceholder
        )
        editor.onSave = save
        presenter.present(UINavigationController(rootViewController: editor), animated: true)
    }

    #if DEBUG
    /// The action row's actions, in order. Tests.
    var debugActions: [ConversationInfoAction] { actionViews.map(\.0) }
    /// A tap on an action of the row, as a finger would. Tests.
    func debugTap(_ action: ConversationInfoAction) {
        guard let view = actionViews.first(where: { $0.0 == action })?.1 else { return }
        didTap(action, from: view)
    }
    /// The "⋯"'s entries' titles, in order. Tests.
    var debugMoreTitles: [String] {
        moreMenuElements().flatMap { element -> [String] in
            if let menu = element as? UIMenu, menu.options.contains(.displayInline) {
                return menu.children.compactMap { ($0 as? UIAction)?.title ?? ($0 as? UIMenu)?.title }
            }
            return [(element as? UIAction)?.title ?? (element as? UIMenu)?.title ?? ""]
        }
    }
    /// The bar's trailing items. Tests.
    var debugTrailingItemIDs: [String] { ownTrailingBarItems.compactMap(\.identifier) }
    /// The bell's menu. Tests.
    var debugBellMenu: UIMenu? { bellMuted == nil ? nil : bellItem.menu }
    #endif
}

// MARK: - The lists' source (#2237)

extension ConversationInfoPageViewController: PersonListsSource {
    func page(of tab: String, after token: String?) async throws -> PersonListPage {
        guard let list = ConversationInfoList(rawValue: tab) else {
            return PersonListPage(rows: [], nextPageToken: nil, total: 0)
        }
        return try await listPage(of: list, after: token)
    }

    func open(_ row: PersonListRow, in tab: String, from screen: PersonListsViewController) {
        openProfile(ProfileID(row.id), name: row.name)
    }

    func perform(_ action: PersonListRowAction, on row: PersonListRow, in tab: String, from screen: PersonListsViewController) {
        guard let list = ConversationInfoList(rawValue: tab) else { return }
        listRowAction(action, on: row, in: list)
    }

    func answer(_ row: PersonListRow, approve: Bool, in tab: String, from screen: PersonListsViewController) {
        listAnswer(row, approve: approve)
    }

    func performLeadingAction(in tab: String, from screen: PersonListsViewController) {
        guard let list = ConversationInfoList(rawValue: tab) else { return }
        listLeadingAction(in: list, from: screen)
    }
}

// MARK: - How it is left (#1144)

extension ConversationInfoPageViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
