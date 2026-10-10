import CoreNavigation
import DesignSystem
import UIKit

/// One `#tag`'s posts (#524), on one page laid out like For You (#629):
///
///     navigation bar   [back]   #travel / 12 posts
///     Recent ›         a row of its newest posts, as cards
///     Top              its ranked posts: cards with slices of the media
///                      mosaic between them, "View all" on each slice
///
/// The tag is the title and its count the subtitle — the bar's own two
/// lines, so the header is UIKit's and rides a push like any other.
///
/// It is For You's page, not a copy of it: one opaque `SearchPostSurface` in
/// the `.discover` style, filled from Feed, so a card opens the post the way
/// For You's do, "View all" pushes For You's media gallery, and the row is
/// For You's Following row. "Recent ›" pushes the whole newest-first list
/// (`HashtagRecentViewController`), as "Following ›" does there.
///
/// It replaced a Top (media gallery) / Recent (cards) pager (#557), built on
/// the two post-set styles that existed before For You became one list.
@MainActor
final class HashtagViewController: UIViewController {
    private let viewModel: HashtagViewModel
    private let postSurfaces: (any SearchPostSurfaceProviding)?
    let page: any SearchPostSurface
    private var hasLoaded = false
    /// The whole Recent list while it is pushed, so later pages reach it.
    private weak var recentScreen: HashtagRecentViewController?

    init(viewModel: HashtagViewModel, postSurfaces: (any SearchPostSurfaceProviding)?) {
        self.viewModel = viewModel
        self.postSurfaces = postSurfaces
        page = postSurfaces?.makePostSurface(style: .discover)
            ?? SearchPendingSurfaceViewController(kind: .posts)
        super.init(nibName: nil, bundle: nil)
        // In the initialiser, as on the results screen: the navigation
        // controller reads it when the push BEGINS.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = viewModel.title
        navigationItem.largeTitleDisplayMode = .never
        configurePage()
        viewModel.onChange = { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasLoaded else { return }
        hasLoaded = true
        Task { [weak self] in await self?.viewModel.load() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        page.setPlaybackActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        page.setPlaybackActive(false)
    }

    private func configurePage() {
        let child = page.viewController
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        // To the top of the VIEW, under the translucent bar: the page's own
        // insets keep its first row clear.
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        page.setSectionTitles(row: HashtagViewModel.rowTitle, list: HashtagViewModel.listTitle)
        // The list asks for its next page as the viewer nears its end (#579).
        page.onNearEnd = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.loadMore(.top) }
        }
        page.onLeadRowTitleTapped = { [weak self] in self?.pushRecent() }
        // A pull, and the failed state's Try Again (#798) — without it the
        // pull snapped shut doing nothing and Try Again was dead.
        page.onRetry = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.refresh() }
        }
    }

    private func render() {
        navigationItem.subtitle = viewModel.countText
        page.show(viewModel.top)
        page.showLeadRow(viewModel.recentRow)
        page.setPaging(viewModel.isLoadingMore(.top))
        page.setHasMore(viewModel.hasMore(.top))
        recentScreen?.render()
    }

    /// "Recent ›": every post carrying the tag, newest first.
    private func pushRecent() {
        guard let navigationController, navigationController.topViewController === self,
              navigationController.transitionCoordinator == nil else { return }
        let screen = HashtagRecentViewController(viewModel: viewModel, postSurfaces: postSurfaces)
        recentScreen = screen
        navigationController.pushViewController(screen, animated: true)
    }
}

/// A tag's whole Recent list, newest first — what "Recent ›" opens on the
/// tag's page (#629), as "Following ›" opens For You's whole Following list.
/// Cards, page by page, on the same view model as the page under it.
@MainActor
final class HashtagRecentViewController: UIViewController {
    private let viewModel: HashtagViewModel
    let list: any SearchPostSurface

    init(viewModel: HashtagViewModel, postSurfaces: (any SearchPostSurfaceProviding)?) {
        self.viewModel = viewModel
        list = postSurfaces?.makePostSurface(style: .cards)
            ?? SearchPendingSurfaceViewController(kind: .posts)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = HashtagViewModel.rowTitle
        navigationItem.subtitle = viewModel.title
        navigationItem.largeTitleDisplayMode = .never
        let child = list.viewController
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        list.onNearEnd = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.loadMore(.recent) }
        }
        // See `HashtagViewController.configurePage` (#798).
        list.onRetry = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.refresh() }
        }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        list.setPlaybackActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        list.setPlaybackActive(false)
    }

    func render() {
        guard isViewLoaded else { return }
        list.show(viewModel.recent)
        list.setPaging(viewModel.isLoadingMore(.recent))
        list.setHasMore(viewModel.hasMore(.recent))
    }
}
