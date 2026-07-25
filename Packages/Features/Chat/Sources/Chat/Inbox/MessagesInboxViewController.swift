import ChatInterface
import CoreNavigation
import UIKit

/// The Messages tab's root: a fixed navigation bar over a glass category
/// header over three horizontally paged surfaces.
///
/// The container owns exactly three things — the pager, the header, and the
/// navigation bar's contents — and drives all of them from one signal, the
/// pager's fractional page position. It holds no inbox data and knows nothing
/// about how a page renders; every surface arrives as an `InboxSurface` and is
/// otherwise opaque.
///
/// Layout: the pager fills the whole view and the header floats above it, with
/// `additionalSafeAreaInsets.top` reserving the header's height. Each page's
/// list therefore insets itself below the header through the standard safe
/// area — content scrolls *under* the glass rather than starting after it, and
/// no page needs a single line of header-aware layout code.
final class MessagesInboxViewController: UIViewController, MessagesInboxCategorySelecting {
    private let surfaces: [any InboxSurface]
    private let categoryBar: InboxCategoryBar
    /// Where the pager starts. A `.messages(...)` route can land before this
    /// tab's view has ever loaded, so it moves rather than paging a pager that
    /// doesn't exist yet.
    private var initialIndex: Int
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Built in `viewDidLoad`, once the surfaces are children — reading a
    /// child's `view` before containment would load it outside its parent.
    private var pagerView: InboxPagerView!
    private var didSubordinatePagerToPop = false
    private var hasActivatedInitialSurface = false

    private lazy var categoryBarTop = categoryBar.topAnchor.constraint(equalTo: view.topAnchor)

    /// Compose belongs to the inbox, not to a page: it starts a new message
    /// regardless of which surface is showing, and rides the same route seam
    /// as row selection so the contact-selection flow lands resolver-side.
    private lazy var composeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.onCompose?() }
        )
        item.accessibilityLabel = "New Message"
        return item
    }()

    /// Wired by the feature builder to the router, so this view controller
    /// never navigates.
    var onCompose: (() -> Void)?

    init(surfaces: [any InboxSurface], initialCategory: MessagesCategory = .all) {
        precondition(!surfaces.isEmpty, "The inbox needs at least one surface")
        self.surfaces = surfaces
        categoryBar = InboxCategoryBar(categories: surfaces.map(\.category))
        initialIndex = surfaces.firstIndex { $0.category == initialCategory } ?? 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        view.backgroundColor = .systemBackground

        for surface in surfaces { addChild(surface) }
        pagerView = InboxPagerView(pages: surfaces.map(\.view), initialIndex: initialIndex)
        pagerView.pin(to: view)
        for surface in surfaces { surface.didMove(toParent: self) }

        // The header's height is reserved as safe area, so every page's list
        // insets under it automatically.
        additionalSafeAreaInsets.top = InboxCategoryBar.height
        view.addSubview(categoryBar)
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            categoryBarTop,
            categoryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: InboxCategoryBar.height)
        ])

        categoryBar.onSelect = { [weak self] index in self?.select(index: index, animated: true) }
        pagerView.onProgress = { [weak self] progress in self?.categoryBar.setProgress(progress) }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }

        for index in surfaces.indices {
            apply(surfaces[index].chrome, from: index)
            surfaces[index].onChromeChange = { [weak self] chrome in self?.apply(chrome, from: index) }
        }

        categoryBar.setProgress(CGFloat(initialIndex))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // `view.safeAreaInsets.top` already contains the header height added
        // above; removing it again lands the bar exactly on the navigation
        // bar's bottom edge, whatever chrome is present.
        categoryBarTop.constant = view.safeAreaInsets.top - additionalSafeAreaInsets.top
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The pager's horizontal pan yields to the stack's edge-swipe pop, so
        // a back gesture is never stolen by a page change. Wired once the view
        // is in a window — the recognizer doesn't exist before then.
        if !didSubordinatePagerToPop, let pop = navigationController?.interactivePopGestureRecognizer {
            didSubordinatePagerToPop = true
            pagerView.horizontalPan.require(toFail: pop)
        }
        // The initial page still needs waking (a deep link can land straight
        // on a lazy surface); later pages wake on settle.
        if !hasActivatedInitialSurface {
            hasActivatedInitialSurface = true
            surfaces[pagerView.activeIndex].surfaceDidBecomeActive()
        }
    }

    // MARK: - Category selection

    /// Pages to a category, from a header tap or an `AppRoute`.
    public func setCategory(_ category: MessagesCategory, animated: Bool) {
        guard let index = surfaces.firstIndex(where: { $0.category == category }) else { return }
        // A launch-time route reaches the tab root before anything is built:
        // fold it into where the pager will START rather than paging.
        guard isViewLoaded else {
            initialIndex = index
            return
        }
        select(index: index, animated: animated)
    }

    private func select(index: Int, animated: Bool) {
        guard index != pagerView.activeIndex else { return }
        pagerView.setActivePage(index, animated: animated)
    }

    private func didSettle(on index: Int) {
        selectionFeedback.selectionChanged()
        categoryBar.setProgress(CGFloat(index))
        apply(surfaces[index].chrome, from: index)
        surfaces[index].surfaceDidBecomeActive()
    }

    // MARK: - Chrome

    /// Applies one surface's published chrome. Badges land whoever sent them;
    /// bar items and the paging lock apply only for the ACTIVE surface, and
    /// only on settle — swapping navigation-bar items mid-drag would flicker
    /// the bar every time a finger crossed the halfway point.
    private func apply(_ chrome: InboxSurfaceChrome, from index: Int) {
        categoryBar.setBadge(chrome.badgeCount, for: surfaces[index].category)
        guard index == pagerView?.activeIndex ?? initialIndex else { return }
        navigationItem.leftBarButtonItem = chrome.leadingBarItem
        navigationItem.rightBarButtonItems = chrome.trailingBarItems.isEmpty
            ? [composeItem]
            : chrome.trailingBarItems
        // Editing freezes paging: a half-made selection has no good outcome if
        // the page slides away under it, and the batch actions on screen
        // belong to the surface being edited.
        pagerView?.isPagingEnabled = !chrome.locksPaging
        categoryBar.isUserInteractionEnabled = !chrome.locksPaging
    }
}
