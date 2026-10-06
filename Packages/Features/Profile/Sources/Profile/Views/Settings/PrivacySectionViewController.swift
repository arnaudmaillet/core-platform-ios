import DesignSystem
import MediaCore
import UIKit

/// Settings → Privacy, for the active profile: Private Account (server-side,
/// `profile.v1.SetVisibility`, #388), follow requests (#396), who can see the
/// relationship lists (server-side, #403), and what is still coming.
final class PrivacySectionViewController: UIViewController {
    private enum Section: Hashable {
        case visibility, lists, comingSoon
    }

    private enum Item: Hashable {
        case privateAccount
        case followRequests
        case postWindow
        case commentAudience
        case mentionAudience
        case messageAudience
        case likeCounts
        case downloads
        case loading
        case failed
        case hideLists
        case activityDiscovery
        case locationSharing
        case dataTransparency
        case planned(String)
    }

    private var planned: [String] {
        (viewModel.comments == nil ? ["Who can comment on your posts"] : [])
            + (viewModel.audiences == nil ? ["Who can mention and message you"] : [])
            + (viewModel.sharing == nil ? ["Downloads of your posts and who sees your likes"] : [])
            + (makeLocationSharing == nil ? ["Location sharing"] : [])
            + ["Hide profile tabs from others"]
    }

    /// "3", or nothing while unread or when none are pending.
    static func requestCountText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return String(count)
    }

    private let viewModel: PrivacySectionViewModel
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .comingSoon ? "Coming Soon" : nil
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
        switch item {
        case .privateAccount:
            content.text = "Private Account"
            content.image = UIImage(systemName: "lock")
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            if case .loaded(let isPrivate) = viewModel.phase { toggle.isOn = isPrivate }
            toggle.isEnabled = !viewModel.isSaving
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.setPrivate(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
        case .loading:
            content.text = "Private Account"
            content.secondaryText = nil
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        case .failed:
            content.text = "Couldn't load your privacy setting. Tap to try again."
            content.textProperties.color = .secondaryLabel
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
            content.secondaryText = viewModel.commentAudience?.title
            content.image = UIImage(systemName: "bubble.left")
            content.imageProperties.tintColor = .label
            let current = viewModel.commentAudience
            cell.accessories = [.popUpMenu(UIMenu(children: CommentAudience.allCases.map { audience in
                UIAction(title: audience.title, state: audience == current ? .on : .off) { [weak self] _ in
                    self?.setCommentAudience(audience)
                }
            }), displayed: .always)]
        case .mentionAudience, .messageAudience:
            let kind: InteractionKind = item == .mentionAudience ? .mentions : .messages
            content = .valueCell()
            content.text = kind == .mentions ? "Who Can Mention" : "Who Can Message"
            let current = kind == .mentions ? viewModel.mentionAudience : viewModel.messageAudience
            content.secondaryText = current?.title
            content.image = UIImage(systemName: kind == .mentions ? "at" : "paperplane")
            content.imageProperties.tintColor = .label
            cell.accessories = [.popUpMenu(UIMenu(children: InteractionAudience.allCases.map { audience in
                UIAction(title: audience.title, state: audience == current ? .on : .off) { [weak self] _ in
                    self?.setAudience(audience, for: kind)
                }
            }), displayed: .always)]
        case .likeCounts, .downloads:
            let isLikes = item == .likeCounts
            content.text = isLikes ? "Show Like Counts" : "Allow Downloads"
            content.secondaryText = isLikes
                ? "Others see how many likes your posts get. You always do."
                : "Others can save your photos and videos."
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: isLikes ? "heart" : "arrow.down.circle")
            content.imageProperties.tintColor = .label
            let toggle = UISwitch()
            if let sharing = viewModel.postSharing {
                toggle.isOn = isLikes ? sharing.showsLikeCounts : sharing.allowsDownloads
            }
            toggle.accessibilityLabel = content.text
            toggle.addAction(UIAction { [weak self] action in
                guard let self, let toggle = action.sender as? UISwitch, var next = viewModel.postSharing else { return }
                if isLikes { next.showsLikeCounts = toggle.isOn } else { next.allowsDownloads = toggle.isOn }
                setPostSharing(next)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
        case .postWindow:
            content = .valueCell()
            content.text = "Posts Visible to Others"
            content.secondaryText = viewModel.postWindow?.title
            content.image = UIImage(systemName: "calendar")
            content.imageProperties.tintColor = .label
            let current = viewModel.postWindow
            cell.accessories = [.popUpMenu(UIMenu(children: PostWindow.allCases.map { window in
                UIAction(title: window.title, state: window == current ? .on : .off) { [weak self] _ in
                    self?.setPostWindow(window)
                }
            }), displayed: .always)]
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
        snapshot.appendSections([.visibility, .lists, .comingSoon])
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
        }
        if viewModel.comments != nil, viewModel.commentAudience != nil {
            snapshot.appendItems([.commentAudience], toSection: .visibility)
            snapshot.reconfigureItems([.commentAudience])
        }
        if viewModel.audiences != nil, viewModel.mentionAudience != nil, viewModel.messageAudience != nil {
            snapshot.appendItems([.mentionAudience, .messageAudience], toSection: .visibility)
            snapshot.reconfigureItems([.mentionAudience, .messageAudience])
        }
        if viewModel.sharing != nil, viewModel.postSharing != nil {
            snapshot.appendItems([.likeCounts, .downloads], toSection: .visibility)
            snapshot.reconfigureItems([.likeCounts, .downloads])
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
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func setCommentAudience(_ audience: CommentAudience) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setCommentAudience(audience)
            } catch {
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change who can comment. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setAudience(audience, for: kind)
            } catch {
                applySnapshot()
                let what = kind == .mentions ? "who can mention you" : "who can message you"
                let alert = UIAlertController(title: nil, message: "Couldn't change \(what). Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setPostSharing(_ next: PostSharing) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setPostSharing(next)
            } catch {
                // Snap the switch back to what the server holds.
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change this setting. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setPostWindow(_ window: PostWindow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setPostWindow(window)
            } catch {
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change who sees your older posts. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setPrivate(_ isPrivate: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.setPrivate(isPrivate)
            } catch {
                // Snap the switch back to what the server holds.
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change your privacy setting. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension PrivacySectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .followRequests, .hideLists, .activityDiscovery, .locationSharing, .dataTransparency, .failed: true
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
        default:
            break
        }
    }
}
