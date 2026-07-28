import ChatInterface
import CoreNavigation
import UIKit

/// The Messages tab's root: a fixed navigation bar over a glass category
/// header over a set of horizontally paged surfaces.
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
    /// The inbox's surfaces, in paging order.
    private let surfaces: [any InboxSurface]
    private let categoryBar: InboxCategoryBar
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Built in `viewDidLoad`, once the surfaces are children — reading a
    /// child's `view` before containment would load it outside its parent.
    private var pagerView: InboxPagerView!
    private var didSubordinatePagerToPop = false
    private var hasActivatedInitialSurface = false
    /// Whose chrome the navigation bar is currently showing.
    ///
    /// This tracks the pager's DOMINANT page — the one a drag is more than
    /// half way onto — rather than the settled page. Bar items therefore hand
    /// over mid-drag, at the same moment the header's lens passes the halfway
    /// mark, instead of snapping into place after the page lands.
    private var barOwner: MessagesCategory?

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

    private let initialIndex: Int
    /// A category asked for before the view existed; folded into where the
    /// pager starts rather than paged to.
    private var pendingCategory: MessagesCategory?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        view.backgroundColor = .systemBackground

        // Loaded up front, not lazily: a surface has to be able to publish its
        // chrome — the All tab's unread count, the Requests badge — before it
        // has ever been paged to, or the header would start out blank.
        for surface in surfaces {
            addChild(surface)
            surface.loadViewIfNeeded()
        }
        // A route that arrived before this point decides the starting page.
        let startIndex = pendingCategory
            .flatMap { category in surfaces.firstIndex { $0.category == category } } ?? initialIndex
        pendingCategory = nil
        pagerView = InboxPagerView(pages: surfaces.map(\.view), initialIndex: startIndex)
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

        // Wired like any system control: the bar carries the chosen segment as
        // its value and announces it, rather than handing back a closure.
        categoryBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                // ONE animation drives both. The pager scrolls to the target
                // and reports fractional progress every frame; the lens
                // interpolates off that, so page and lens cannot disagree and
                // there is nothing to keep in sync. The bar runs no animation
                // of its own — a second one on the same frame would fight this.
                self.select(index: self.categoryBar.selectedIndex, animated: true)
            },
            for: .valueChanged
        )
        // Dragging the header IS dragging the pages. The bar reports a
        // fractional page position and the pager is scrubbed to it, so the same
        // `onProgress` loop that answers a content swipe answers this too — the
        // lens and the bar items need no separate path.
        categoryBar.onScrub = { [weak self] progress in self?.pagerView.scrub(to: progress) }
        categoryBar.onScrubEnd = { [weak self] velocity in
            self?.pagerView.settleAfterScrub(velocityInPages: velocity)
        }
        pagerView.onProgress = { [weak self] progress in
            self?.categoryBar.setProgress(progress)
            self?.updateBarOwner(forProgress: progress)
        }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }

        barOwner = surfaces[pagerView.activeIndex].category
        for surface in surfaces {
            apply(surface.chrome, from: surface)
            surface.onChromeChange = { [weak self] chrome in self?.apply(chrome, from: surface) }
        }

        categoryBar.setProgress(CGFloat(pagerView.activeIndex))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // `view.safeAreaInsets.top` already contains the header height added
        // above; removing it again lands the bar exactly on the navigation
        // bar's bottom edge, whatever chrome is present.
        categoryBarTop.constant = view.safeAreaInsets.top - additionalSafeAreaInsets.top
    }

    /// Fires at the START of a pop — including the interactive one, before any
    /// frame is drawn — so everything the transition reveals is already in
    /// agreement: the page shown, the lens over it, and the bar items above.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Claim ownership BEFORE re-asserting: that republishes progress, and
        // an owner change there would crossfade the bar in the middle of the
        // pop — motion the transition is already providing.
        barOwner = activeSurface?.category
        pagerView?.reassertActivePage()
        if let surface = activeSurface { apply(surface.chrome, from: surface) }
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
            activeSurface?.surfaceDidBecomeActive()
        }
        #if DEBUG
        // `-inbox-page-to <category>` animates to another tab ~2s in, through
        // the SAME path a segment tap takes (`setActivePage(animated:)`, which
        // reports fractional progress every frame). Taps can't be injected
        // headlessly, and this is the transition worth recording.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-inbox-page-to"),
           let name = arguments.dropFirst(index + 1).first,
           let category = MessagesCategory(rawValue: name),
           let target = surfaces.firstIndex(where: { $0.category == category }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.select(index: target, animated: true)
            }
        }
        #endif
    }

    // MARK: - Category selection

    private var activeSurface: (any InboxSurface)? {
        let index = pagerView?.activeIndex ?? initialIndex
        return surfaces.indices.contains(index) ? surfaces[index] : surfaces.first
    }

    /// Pages to a category, from a header tap or an `AppRoute`.
    public func setCategory(_ category: MessagesCategory, animated: Bool) {
        guard let index = surfaces.firstIndex(where: { $0.category == category }) else { return }
        // A launch-time route (`-open-messages requests`, a push payload)
        // reaches this tab root BEFORE its view exists — there is no pager to
        // page yet, so the request becomes where the pager starts.
        guard isViewLoaded else {
            pendingCategory = category
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
        if let surface = activeSurface {
            apply(surface.chrome, from: surface)
            surface.surfaceDidBecomeActive()
        }
    }

    // MARK: - Chrome

    /// Hands the navigation bar over to whichever page the drag is now more
    /// than half onto, crossfading as it goes.
    ///
    /// Driven by the pager's fractional position rather than its settle, so
    /// "Edit" and "Clear All" trade places at the same moment the header's
    /// lens crosses between their segments — and dragging back and forth
    /// crossfades back and forth with it, instead of holding the old items and
    /// snapping once the page lands.
    private func updateBarOwner(forProgress progress: CGFloat) {
        let index = Int(progress.rounded())
        guard surfaces.indices.contains(index) else { return }
        let surface = surfaces[index]
        guard surface.category != barOwner else { return }
        barOwner = surface.category
        applyChrome(surface.chrome, animated: true)
    }

    /// Applies one surface's published chrome. Badges land whoever sent them;
    /// bar items belong to whichever surface currently owns the bar.
    ///
    /// Not animated: this is the in-place path — a badge count arriving, or
    /// the selection counter ticking while editing. Animating those would
    /// crossfade the whole bar on every row tap.
    private func apply(_ chrome: InboxSurfaceChrome, from surface: any InboxSurface) {
        categoryBar.setBadge(chrome.badgeCount, for: surface.category)
        guard surface.category == barOwner else { return }
        applyChrome(chrome, animated: false)
    }

    private func applyChrome(_ chrome: InboxSurfaceChrome, animated: Bool) {
        let write = {
            self.title = chrome.title ?? "Messages"
            self.navigationItem.leftBarButtonItem = chrome.leadingBarItem
            self.navigationItem.rightBarButtonItems = chrome.trailingBarItems.isEmpty
                ? [self.composeItem]
                : chrome.trailingBarItems
        }
        // Editing freezes paging: a half-made selection has no good outcome if
        // the page slides away under it, and the batch actions on screen
        // belong to the surface being edited. Outside the crossfade — it is
        // state, not appearance.
        pagerView?.isPagingEnabled = !chrome.locksPaging
        categoryBar.isUserInteractionEnabled = !chrome.locksPaging

        // The bar is crossfaded as a whole rather than each item's alpha being
        // driven: a `UIBarButtonItem` has no alpha, and wrapping items in
        // custom views to get one would forfeit the system's Liquid Glass
        // capsules — the same double-material trap `GlassSegmentRow`
        // documents. `.allowUserInteraction` keeps the swipe under the
        // viewer's control while the fade runs.
        guard animated, view.window != nil, let bar = navigationController?.navigationBar else {
            write()
            return
        }
        UIView.transition(
            with: bar,
            duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: write
        )
    }
}
