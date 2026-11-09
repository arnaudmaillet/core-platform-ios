import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import UIKit

/// The inbox's Channels surface (#2215, `-channels`): the channels the
/// viewer runs or follows, each a conversation's row — photo, name, the
/// last post's first line, its time, unread and mute — with a small badge on
/// the ones the viewer runs. Pending join requests for those wait at the
/// top in ONE row; "Create a Channel" follows it. With no channel, the page
/// says what a channel is, and offers to make one.
final class ChannelsViewController: UIViewController {
    private enum Section: Hashable { case main }

    private let viewModel: ChannelsViewModel
    private let imagePipeline: ImagePipeline?

    /// "Create a Channel": the host presents the creation sheet.
    var onCreate: ((_ presenter: UIViewController) -> Void)?
    /// The requests row: the host pushes the requests list.
    var onOpenRequests: ((_ presenter: UIViewController, _ channels: [ChannelsViewModel.RunChannel]) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ChannelsViewModel.Item>!
    private let skeletonView = PersonListSkeletonView(trailing: .timeBone, lines: .preview)
    private let statusView = InboxStatusView()
    private lazy var loading: ScreenLoadingHost = {
        let host = ScreenLoadingHost(container: view, skeleton: skeletonView, content: collectionView, status: statusView)
        host.onTakingLonger = { [weak self] in
            guard let self else { return }
            statusView.configure(
                symbol: TakingLongerCopy.symbol, title: TakingLongerCopy.title,
                message: "Your channels are still on their way.",
                actionTitle: TakingLongerCopy.action, action: { [weak self] in self?.viewModel.retry() }
            )
            loading.showStatus()
        }
        return host
    }()
    private let refreshControl = AppRefreshControl()
    private var hasRenderedContent = false
    private var renderedRows: [ConversationID: ConversationDisplayModel] = [:]

    private(set) var chrome = InboxSurfaceChrome()
    var onChromeChange: ((InboxSurfaceChrome) -> Void)?

    init(viewModel: ChannelsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        // The badge is a fact about the session, landing before the page is
        // ever shown (as the other tabs').
        viewModel.onNewCountChange = { [weak self] count in
            guard let self else { return }
            self.chrome.badgeCount = count
            self.onChromeChange?(self.chrome)
        }
        chrome.badgeCount = viewModel.newCount
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureList()
        configureStatusViews()
        refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        render(viewModel.phase)
    }

    private func pullToRefresh() {
        viewModel.refresh()
        viewModel.refreshRequests()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshControl.endRefreshing() }
    }

    // MARK: - The list

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        // A channel's row: Mute / Unmute, the inbox's (#719).
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] path in
            guard let self, case .channel(let id) = self.dataSource.itemIdentifier(for: path),
                  let row = self.viewModel.rows[id] else { return nil }
            let mute = UIContextualAction(style: .normal, title: row.isMuted ? "Unmute" : "Mute") { [weak self] _, _, done in
                self?.viewModel.toggleMute(id)
                done(true)
            }
            mute.image = UIImage(systemName: row.isMuted ? "bell.fill" : "bell.slash.fill")
            return UISwipeActionsConfiguration(actions: [mute])
        }
        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = false
        // The rows run up under the bar untouched, as every inbox page's.
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        collectionView.pin(to: view)

        let channelCell = UICollectionView.CellRegistration<ConversationResultCell, ConversationID> { [weak self] cell, _, id in
            guard let self, let model = self.viewModel.rows[id] else { return }
            cell.configure(with: model, imagePipeline: self.imagePipeline)
        }
        let linkCell = UICollectionView.CellRegistration<UICollectionViewListCell, ChannelsViewModel.Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            let row = ChannelLinkRowView()
            switch item {
            case .joinRequests:
                row.configure(
                    symbol: "person.crop.circle.badge.questionmark", title: ChannelCopy.joinRequests(self.viewModel.requestCount),
                    message: "Approve or decline who asked to join", emphasised: true
                )
            default:
                row.configure(symbol: "plus", title: ChannelCopy.createTitle, message: "Post to everyone who follows it")
            }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            row.pin(to: cell.contentView)
            cell.accessibilityLabel = row.accessibilityLabel
            cell.accessibilityTraits = .button
            cell.isAccessibilityElement = true
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, item in
            switch item {
            case .channel(let id):
                collectionView.dequeueConfiguredReusableCell(using: channelCell, for: path, item: id)
            case .joinRequests, .create:
                collectionView.dequeueConfiguredReusableCell(using: linkCell, for: path, item: item)
            }
        }
    }

    private func configureStatusViews() {
        skeletonView.isHidden = true
        skeletonView.constrain(in: view) { parent in
            skeletonView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            skeletonView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            skeletonView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            skeletonView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        statusView.isHidden = true
        statusView.pin(to: view, relativeTo: .safeArea)
    }

    // MARK: - Render

    private func render(_ phase: ChannelsViewModel.Phase) {
        guard isViewLoaded else { return }
        if case .loading = phase {} else { refreshControl.endRefreshing() }
        switch phase {
        case .loading:
            loading.load()
        case .failed(let message):
            statusView.configure(
                symbol: "exclamationmark.triangle", title: "Something went wrong", message: message,
                actionTitle: "Try Again", action: { [weak self] in self?.viewModel.retry() }
            )
            loading.showStatus()
        case .empty:
            statusView.configure(
                symbol: "megaphone", title: ChannelCopy.emptyTitle, message: ChannelCopy.emptyMessage,
                actionTitle: ChannelCopy.createTitle, action: { [weak self] in
                    guard let self else { return }
                    self.onCreate?(self)
                }
            )
            loading.showStatus()
        case .content(let items):
            var snapshot = NSDiffableDataSourceSnapshot<Section, ChannelsViewModel.Item>()
            snapshot.appendSections([.main])
            snapshot.appendItems(items, toSection: .main)
            // Rows whose content changed redraw in place; the requests row
            // whenever its count may have.
            let rows = viewModel.rows
            var stale: [ChannelsViewModel.Item] = rows.keys
                .filter { renderedRows[$0] != nil && renderedRows[$0] != rows[$0] }
                .map(ChannelsViewModel.Item.channel)
            if items.contains(.joinRequests) { stale.append(.joinRequests) }
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(stale.filter { existing.contains($0) && items.contains($0) })
            renderedRows = rows
            dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
            hasRenderedContent = true
            loading.showContent()
        }
    }
}

extension ChannelsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .channel(let id):
            viewModel.didSelect(id)
        case .joinRequests:
            onOpenRequests?(self, viewModel.runChannels)
        case .create:
            onCreate?(self)
        case nil:
            break
        }
    }

    /// The next page as the end comes near.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard viewModel.hasMore, indexPath.item >= collectionView.numberOfItems(inSection: indexPath.section) - 3 else { return }
        viewModel.loadMore()
    }
}

// MARK: - InboxSurface

extension ChannelsViewController: InboxSurface {
    var category: MessagesCategory { .channels }
    var listScrollView: UIScrollView? { collectionView }

    /// The catalog loads with the inbox; coming back counts the requests
    /// again — an admin elsewhere may have answered some.
    func surfaceDidBecomeActive() {
        viewModel.refreshRequests()
    }
}

/// A row that leads somewhere rather than being a conversation (#2215): a
/// disc with a symbol where a face sits, a title and a line under it, and a
/// chevron — the requests row and "Create a Channel". Laid out like a
/// conversation row, so it reads as one of the list's entries.
final class ChannelLinkRowView: UIView {
    private let disc = UIView()
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        disc.layer.cornerRadius = MonogramAvatarView.rowDiameter / 2
        disc.layer.cornerCurve = .circular
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        symbolView.constrain(in: disc) { parent in
            symbolView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            symbolView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
            disc.heightAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
        ])
        titleLabel.font = .appFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        messageLabel.font = .appFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.forward"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [disc, text, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.isUserInteractionEnabled = false
        let inset = PersonRowMetrics.verticalInset(forContentHeight: MonogramAvatarView.rowDiameter)
        row.pin(to: self, insets: NSDirectionalEdgeInsets(top: inset, leading: Spacing.lg, bottom: inset, trailing: Spacing.lg))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `emphasised`: something waits — the disc in the tint, as a count would be.
    func configure(symbol: String, title: String, message: String, emphasised: Bool = false) {
        symbolView.image = UIImage(systemName: symbol)
        disc.backgroundColor = emphasised ? .tintColor : .secondarySystemFill
        symbolView.tintColor = emphasised ? .white : .label
        titleLabel.text = title
        messageLabel.text = message
        accessibilityLabel = "\(title). \(message)"
    }
}
