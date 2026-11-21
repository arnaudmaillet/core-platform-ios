import CoreModels
import DesignSystem
import UIKit

/// What the full-screen feed's loaders ask of their screen (#2514): its view,
/// which hosts both, the pages, and the readiness ceiling the paging footer
/// answers.
@MainActor
protocol SnapPageLoadersHost: UIViewController {
    var orderedIDs: [PostID] { get }
    func reachableCeiling() -> Int
}

/// The full-screen feed's two loaders (#2514): the centre one for a feed with
/// no post yet, after the page's grace (`LoaderGate`), and the paging footer
/// under the last reachable page while the viewer pulls against it.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: the render and the scroll callbacks call
/// it in their turn, where they called the screen before.
@MainActor
final class SnapPageLoaders {
    private unowned let host: any SnapPageLoadersHost

    init(host: any SnapPageLoadersHost) {
        self.host = host
    }

    /// The full-screen rule's loader (the owner, 2026-10-27) for a feed with no
    /// post yet: at the centre, after `SnapMediaWait.grace`, so a page the
    /// device already holds never flashes it.
    private lazy var firstPageLoader: AppLoaderView = {
        let spinner = AppLoaderView(size: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: host.view.centerYAnchor)
        ])
        return spinner
    }()
    /// The loader's timing — the kit's (`LoaderGate`, #1768) at the page's grace.
    private lazy var firstPageGate = LoaderGate(grace: SnapMediaWait.grace) { [weak self] showing in
        guard let self else { return }
        if showing {
            isFirstPageLoaderBuilt = true
            host.view.bringSubviewToFront(firstPageLoader)
            firstPageLoader.startAnimating()
        } else if isFirstPageLoaderBuilt {
            firstPageLoader.stopAnimating()
        }
    }

    func setFirstPageWaiting(_ waiting: Bool) {
        waiting ? firstPageGate.begin() : firstPageGate.end()
    }
    /// Built on first need: most feeds open on posts and never show it.
    private var isFirstPageLoaderBuilt = false

    #if DEBUG
    /// Whether the no-post loader is up.
    var debugShowsFirstPageLoader: Bool { isFirstPageLoaderBuilt && firstPageLoader.isAnimating }
    #endif

    /// The spinner shown under the last reachable page, exactly as the timeline
    /// shows one at the end of a loaded batch — because to the viewer it is the
    /// same situation: there IS more, and it is not here yet.
    private lazy var pagingFooter: AppLoaderView = {
        let spinner = AppLoaderView(size: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        return spinner
    }()

    /// Shows the spinner while the viewer is pulling against the readiness
    /// ceiling, and only then.
    ///
    /// Driven from the scroll rather than from the settle: the whole point is
    /// to answer the gesture that is happening now — a viewer who drags past
    /// the last ready page sees why they cannot go further while they are still
    /// pulling, and a settled feed shows nothing.
    func updatePagingFooter(for scrollView: UIScrollView) {
        let page = scrollView.bounds.height
        guard page > 0, !host.orderedIDs.isEmpty else { return }
        let ceiling = CGFloat(host.reachableCeiling()) * page
        let atCorpusEnd = host.reachableCeiling() >= host.orderedIDs.count - 1
        let pulling = scrollView.contentOffset.y > ceiling + 1
        if pulling, !atCorpusEnd {
            pagingFooter.startAnimating()
        } else {
            pagingFooter.stopAnimating()
        }
    }
}
