import CoreNetworking
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// Settings → Privacy, for the active profile: Private Account (server-side,
/// `profile.v1.SetVisibility`, #388), follow requests (#396), who can see the
/// relationship lists (server-side, #403), and what is still coming.
final class PrivacySectionViewController: UIViewController {
    private enum Section: Hashable {
        case visibility, profileTabs, lists, comingSoon
    }

    private enum Item: Hashable {
        case privateAccount
        case followRequests
        case postWindow
        case commentAudience
        case mentionAudience
        case messageAudience
        case downloads
        case loading
        case failed
        /// A side setting that couldn't be read: tapped, it reads only
        /// that one again (#799).
        case sideFailed(PrivacySectionViewModel.SideSetting)
        case hideLists
        case activityDiscovery
        case locationSharing
        case dataTransparency
        case planned(String)
        /// A tab others see or not (#411).
        case tab(ProfileTabVisibility.Tab)
    }

    private var planned: [String] {
        (viewModel.comments == nil ? ["Who can comment on your posts"] : [])
            + (viewModel.audiences == nil ? ["Who can mention and message you"] : [])
            + (viewModel.sharing == nil ? ["Downloads of your posts and who sees your likes"] : [])
            + (makeLocationSharing == nil ? ["Location sharing"] : [])
            + (viewModel.tabs == nil ? ["Hide profile tabs from others"] : [])
    }

    /// The failed row of a side setting, in the wording every Settings
    /// screen uses — or "You’re offline…" when that is why it failed (#794).
    static func failedText(_ side: PrivacySectionViewModel.SideSetting, failure: NetworkFailure? = nil) -> String {
        let what = switch side {
        case .postWindow: "who sees your older posts"
        case .commentAudience: "who can comment"
        case .interactionAudiences: "who can mention and message you"
        case .postSharing: "your like count and download settings"
        case .tabVisibility: "which tabs others see"
        }
        return FailureCopy.row(for: failure, fallback: "Couldn't load \(what). Tap to try again.")
    }

    /// "3", or nothing while unread or when none are pending.
    static func requestCountText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return String(count)
    }

    private let viewModel: PrivacySectionViewModel
    /// The settings on their way to the server (#1775).
    private lazy var saves: SettingSaves<Setting, Change> = {
        let saves = SettingSaves<Setting, Change>()
        saves.onChange = { [weak self] in self?.applySnapshot() }
        return saves
    }()
    /// Who can see the followers and following lists; nil hides the row.
    private let makeListPrivacy: (() -> UIViewController)?
    /// Activity status, read receipts and search (#406, #412); nil hides the row.
    private let makeActivityDiscovery: (() -> UIViewController)?
    /// Ghost mode and precision (#398); nil keeps it under Coming Soon.
    private let makeLocationSharing: (() -> UIViewController)?
    /// "Your Data and Permissions" (#414); nil hides the row.
    private let makeDataTransparency: (() -> UIViewController)?
    private let imagePipeline: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        viewModel: PrivacySectionViewModel,
        makeListPrivacy: (() -> UIViewController)?,
        makeDataTransparency: (() -> UIViewController)? = nil,
        makeActivityDiscovery: (() -> UIViewController)? = nil,
        makeLocationSharing: (() -> UIViewController)? = nil,
        imagePipeline: ImagePipeline? = nil
    ) {
        self.viewModel = viewModel
        self.makeListPrivacy = makeListPrivacy
        self.makeDataTransparency = makeDataTransparency
        self.makeActivityDiscovery = makeActivityDiscovery
        self.makeLocationSharing = makeLocationSharing
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.privacy.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await viewModel.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from the inbox: the count may have dropped.
        if isMovingToParent == false { Task { await viewModel.refreshRequestCount() } }
    }

    private static func footerText(_ section: Section) -> String? {
        switch section {
        case .visibility:
            "When your profile is private, only your followers can see your posts and your lists. Older posts outside the window you choose are hidden from others, not deleted; you always see them. Comments and mentions from anyone outside the audience you choose are refused; their messages arrive as requests, and with No One they're refused. Applies to this profile only."
        case .profileTabs:
            "Others see only the tabs you turn on here. You always see all of them. Applies to this profile only."
        case .lists:
            nil
        case .comingSoon:
            "These need a server update and aren't available yet."
        }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .comingSoon: "Coming Soon"
            case .profileTabs: "Profile Tabs"
            default: nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.footerText)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.cell()
        cell.accessories = []
        // Only a failed row is tapped to retry: VoiceOver says so (#799).
        cell.accessibilityTraits.remove(.button)
        switch item {
        case .privateAccount:
            content.text = "Private Account"
            content.image = UIImage(systemName: "lock")
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            if case .loaded(let isPrivate) = viewModel.phase { toggle.isOn = flag(.privateAccount) ?? isPrivate }
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setPrivate(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = accessories(toggle, for: .privateAccount)
        case .loading:
            content.text = "Private Account"
            content.secondaryText = nil
            cell.accessories = [.busy()]
        case .failed:
            content.text = FailureCopy.row(
                for: viewModel.visibilityFailure, fallback: "Couldn't load your privacy setting. Tap to try again."
            )
            content.textProperties.color = .secondaryLabel
            cell.accessibilityTraits.insert(.button)
        case .sideFailed(let side):
            content.text = Self.failedText(side, failure: viewModel.sideFailures[side])
            content.textProperties.color = .secondaryLabel
            cell.accessibilityTraits.insert(.button)
        case .followRequests:
            content = .valueCell()
            content.text = "Follow Requests"
            content.secondaryText = Self.requestCountText(viewModel.pendingRequestCount)
            content.image = UIImage(systemName: "person.badge.clock")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .commentAudience:
            content = .valueCell()
            content.text = "Who Can Comment"
            let current = audience(.comments) ?? viewModel.commentAudience
            content.secondaryText = current?.title
            content.image = UIImage(systemName: "bubble.left")
            content.imageProperties.tintColor = .label
            cell.accessories = accessories(.popUpMenu(UIMenu(children: CommentAudience.allCases.map { audience in
                UIAction(title: audience.title, state: audience == current ? .on : .off) { [weak self] _ in
                    self?.setCommentAudience(audience)
                }
            }), displayed: .always), for: .comments)
        case .mentionAudience, .messageAudience:
            let kind: InteractionKind = item == .mentionAudience ? .mentions : .messages
            content = .valueCell()
            content.text = kind == .mentions ? "Who Can Mention" : "Who Can Message"
            let setting = Self.setting(for: kind)
            let current = audience(setting) ?? (kind == .mentions ? viewModel.mentionAudience : viewModel.messageAudience)
            content.secondaryText = current?.title
            content.image = UIImage(systemName: kind == .mentions ? "at" : "paperplane")
            content.imageProperties.tintColor = .label
            cell.accessories = accessories(.popUpMenu(UIMenu(children: InteractionAudience.allCases.map { audience in
                UIAction(title: audience.title, state: audience == current ? .on : .off) { [weak self] _ in
                    self?.setAudience(audience, for: kind)
                }
            }), displayed: .always), for: setting)
        case .downloads:
            // No "Show Like Counts" (#1713, the owner): likes always show.
            content.text = "Allow Downloads"
            content.secondaryText = "Others can save your photos and videos."
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage.symbol(named: "arrow.down.circle")
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            if let sharing = viewModel.postSharing {
                toggle.isOn = flag(.downloads) ?? sharing.allowsDownloads
            }
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setDownloads(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = accessories(toggle, for: .downloads)
        case .tab(let tab):
            content.text = tab.title
            let symbol = switch tab {
            case .likes: AppSymbol.like.rawValue
            case .saved: AppSymbol.save.rawValue
            case .reposts: PostActionSymbol.repost
            }
            content.image = UIImage.symbol(named: symbol)
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            toggle.isOn = flag(.tab(tab)) ?? viewModel.tabVisibility?[tab] ?? false
            toggle.accessibilityLabel = "Show \(tab.title) to others"
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setTab(tab, visible: toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = accessories(toggle, for: .tab(tab))
        case .postWindow:
            content = .valueCell()
            content.text = "Posts Visible to Others"
            let current: PostWindow?
            if case .window(let window)? = saves.value(for: .postWindow) { current = window } else { current = viewModel.postWindow }
            content.secondaryText = current?.title
            content.image = UIImage(systemName: "calendar")
            content.imageProperties.tintColor = .label
            cell.accessories = accessories(.popUpMenu(UIMenu(children: PostWindow.allCases.map { window in
                UIAction(title: window.title, state: window == current ? .on : .off) { [weak self] _ in
                    self?.setPostWindow(window)
                }
            }), displayed: .always), for: .postWindow)
        case .hideLists:
            content.text = "Followers and Following Lists"
            content.image = UIImage(systemName: "person.2")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .locationSharing:
            content.text = "Location Sharing"
            content.image = UIImage(systemName: "location")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .activityDiscovery:
            content.text = "Activity and Discovery"
            content.image = UIImage(systemName: "eye")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .dataTransparency:
            content.text = "Your Data and Permissions"
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            content.imageProperties.tintColor = .label
            cell.accessories = [.disclosureIndicator()]
        case .planned(let title):
            content.text = title
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.visibility, .profileTabs, .lists, .comingSoon])
        switch viewModel.phase {
        case .loading: snapshot.appendItems([.loading], toSection: .visibility)
        case .loaded: snapshot.appendItems([.privateAccount], toSection: .visibility)
        case .failed: snapshot.appendItems([.failed], toSection: .visibility)
        }
        // Pending requests stay answerable after going public (backend #655
        // doesn't auto-approve them), so the row shows whenever there's an inbox.
        if viewModel.requests != nil { snapshot.appendItems([.followRequests], toSection: .visibility) }
        if viewModel.windows != nil, viewModel.postWindow != nil {
            snapshot.appendItems([.postWindow], toSection: .visibility)
            snapshot.reconfigureItems([.postWindow])
        } else if viewModel.failedSides.contains(.postWindow) {
            snapshot.appendItems([.sideFailed(.postWindow)], toSection: .visibility)
        }
        if viewModel.comments != nil, viewModel.commentAudience != nil {
            snapshot.appendItems([.commentAudience], toSection: .visibility)
            snapshot.reconfigureItems([.commentAudience])
        } else if viewModel.failedSides.contains(.commentAudience) {
            snapshot.appendItems([.sideFailed(.commentAudience)], toSection: .visibility)
        }
        if viewModel.audiences != nil, viewModel.mentionAudience != nil, viewModel.messageAudience != nil {
            snapshot.appendItems([.mentionAudience, .messageAudience], toSection: .visibility)
            snapshot.reconfigureItems([.mentionAudience, .messageAudience])
        } else if viewModel.failedSides.contains(.interactionAudiences) {
            snapshot.appendItems([.sideFailed(.interactionAudiences)], toSection: .visibility)
        }
        if viewModel.sharing != nil, viewModel.postSharing != nil {
            snapshot.appendItems([.downloads], toSection: .visibility)
            snapshot.reconfigureItems([.downloads])
        } else if viewModel.failedSides.contains(.postSharing) {
            snapshot.appendItems([.sideFailed(.postSharing)], toSection: .visibility)
        }
        if viewModel.tabs != nil, viewModel.tabVisibility != nil {
            let rows = ProfileTabVisibility.Tab.allCases.map(Item.tab)
            snapshot.appendItems(rows, toSection: .profileTabs)
            snapshot.reconfigureItems(rows)
        } else if viewModel.failedSides.contains(.tabVisibility) {
            snapshot.appendItems([.sideFailed(.tabVisibility)], toSection: .profileTabs)
        }
        snapshot.appendItems(
            (makeListPrivacy == nil ? [] : [.hideLists])
                + (makeActivityDiscovery == nil ? [] : [.activityDiscovery])
                + (makeLocationSharing == nil ? [] : [.locationSharing])
                + (makeDataTransparency == nil ? [] : [.dataTransparency]),
            toSection: .lists
        )
        snapshot.appendItems(planned.map(Item.planned), toSection: .comingSoon)
        // The switch reads the phase and the saving flag at configuration.
        if case .loaded = viewModel.phase { snapshot.reconfigureItems([.privateAccount]) }
        if viewModel.requests != nil { snapshot.reconfigureItems([.followRequests]) }
        // A failed row reads why at configuration (#794): a retry that fails
        // for another reason rewords it in place.
        let failedRows = snapshot.itemIdentifiers.filter {
            if case .sideFailed = $0 { return true }
            return $0 == .failed
        }
        snapshot.reconfigureItems(failedRows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Changes (#1775)

    /// A setting a row saves.
    private enum Setting: Hashable, Sendable {
        case privateAccount, downloads, tab(ProfileTabVisibility.Tab)
        case comments, mentions, messages, postWindow
    }

    /// A change on its way.
    private enum Change: Sendable {
        case flag(Bool)
        case audience(CommentAudience)
        case window(PostWindow)
    }

    private static func setting(for kind: InteractionKind) -> Setting {
        kind == .mentions ? .mentions : .messages
    }

    /// The switch value on its way for `setting`, nil when none.
    private func flag(_ setting: Setting) -> Bool? {
        if case .flag(let isOn)? = saves.value(for: setting) { return isOn }
        return nil
    }

    /// The audience on its way for `setting`, nil when none.
    private func audience(_ setting: Setting) -> CommentAudience? {
        if case .audience(let audience)? = saves.value(for: setting) { return audience }
        return nil
    }

    /// `toggle` for `setting`: on its way, it waits with the loader beside it.
    private func accessories(_ toggle: UISwitch, for setting: Setting) -> [UICellAccessory] {
        toggle.isEnabled = !saves.isSaving(setting)
        return accessories(.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always))), for: setting)
    }

    private func accessories(_ control: UICellAccessory, for setting: Setting) -> [UICellAccessory] {
        saves.isSaving(setting) ? [.busy(), control] : [control]
    }

    /// Shows `change` at once and saves it through the model in turn; on
    /// failure the row goes back to the server's value, then says why.
    private func save(
        _ change: Change, for setting: Setting,
        _ work: @escaping @MainActor (PrivacySectionViewModel) async throws -> Void,
        message: @escaping @MainActor (Error) -> String
    ) {
        let viewModel = viewModel
        saves.save(change, for: setting, { _ in try await work(viewModel) }, failed: { [weak self] error in
            let alert = UIAlertController(title: nil, message: message(error), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        })
    }

    private func setCommentAudience(_ audience: CommentAudience) {
        guard (self.audience(.comments) ?? viewModel.commentAudience) != audience else { return }
        save(.audience(audience), for: .comments, { try await $0.setCommentAudience(audience) }, message: { error in
            // A supervisor's floor holds it (PRF-5006, #417): say who.
            SupervisionLock.message(for: error, fallback: "Couldn't change who can comment. Try again.")
        })
    }

    private func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) {
        let setting = Self.setting(for: kind)
        let current = self.audience(setting) ?? (kind == .mentions ? viewModel.mentionAudience : viewModel.messageAudience)
        guard current != audience else { return }
        save(.audience(audience), for: setting, { try await $0.setAudience(audience, for: kind) }, message: { error in
            let what = kind == .mentions ? "who can mention you" : "who can message you"
            return SupervisionLock.message(for: error, fallback: "Couldn't change \(what). Try again.")
        })
    }

    /// The downloads switch, over the sharing record as the save before it
    /// left it.
    private func setDownloads(_ allowed: Bool) {
        guard viewModel.postSharing != nil else { return }
        save(.flag(allowed), for: .downloads, { viewModel in
            guard var next = viewModel.postSharing else { return }
            next.allowsDownloads = allowed
            try await viewModel.setPostSharing(next)
        }, message: { _ in "Couldn't change this setting. Try again." })
    }

    private func setTab(_ tab: ProfileTabVisibility.Tab, visible: Bool) {
        save(.flag(visible), for: .tab(tab), { try await $0.setTab(tab, visible: visible) }, message: { _ in
            "Couldn't change who sees your \(tab.title) tab. Try again."
        })
    }

    private func setPostWindow(_ window: PostWindow) {
        save(.window(window), for: .postWindow, { try await $0.setPostWindow(window) }, message: { _ in
            "Couldn't change who sees your older posts. Try again."
        })
    }

    /// The failed row's retry: only that setting is read again. A retry that
    /// fails again leaves the row and says so.
    private func retry(_ side: PrivacySectionViewModel.SideSetting) {
        Task { [weak self] in
            guard let self, await viewModel.reload(side) == false else { return }
            // The failed row’s words: "You’re offline" when that is why (#794).
            Feedback.failure(
                FailureCopy.title(for: viewModel.sideFailures[side], fallback: "Couldn't load this setting"), from: self
            )
        }
    }

    /// Not optimistic: the switch stays where the tap put it, with the
    /// loader beside it, until the server holds it, or snaps back.
    private func setPrivate(_ isPrivate: Bool) {
        save(.flag(isPrivate), for: .privateAccount, { try await $0.setPrivate(isPrivate) }, message: { error in
            SupervisionLock.message(for: error, fallback: "Couldn't change your privacy setting. Try again.")
        })
    }
}

extension PrivacySectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .followRequests, .hideLists, .activityDiscovery, .locationSharing, .dataTransparency, .failed, .sideFailed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .followRequests:
            guard let requests = viewModel.requests else { return }
            navigationController?.pushViewController(
                FollowRequestsViewController(viewModel: FollowRequestsViewModel(requests: requests), imagePipeline: imagePipeline),
                animated: true
            )
        case .hideLists:
            if let screen = makeListPrivacy?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        case .locationSharing:
            if let screen = makeLocationSharing?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        case .activityDiscovery:
            if let screen = makeActivityDiscovery?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        case .dataTransparency:
            if let screen = makeDataTransparency?() {
                navigationController?.pushViewController(screen, animated: true)
            }
        case .failed:
            Task { await viewModel.load() }
        case .sideFailed(let side):
            retry(side)
        default:
            break
        }
    }
}

// MARK: - How it is left (#1144)

extension PrivacySectionViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
