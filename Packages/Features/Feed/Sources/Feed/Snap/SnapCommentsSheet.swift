import CoreModels
import DesignSystem
import UIKit

/// A media post's comments as a NATIVE SHEET (#2087, behind `CommentsV2`) —
/// the TikTok arrangement the owner asked for on 2026-11-03:
///
///   ┌──────────────────────┐
///   │      [ media ]       │  ← the post's media, shrunk WHOLE into the top
///   │                      │    ~40 %, centred, still playing; the page's
///   ├──────────────────────┤    interface and bars gone
///   │ [Popular|Recent] [♥ 250] │  ← the sheet's own bar: the tabs, the balance
///   │  comment rows …      │  ← today's comments panel, in a UIKit sheet
///   │  [ compose bar ]     │    resting at 60 % of the screen
///   └──────────────────────┘
///
/// ONE MEASURE DRIVES THE PAGE: the sheet's top, read every frame from its
/// presentation layer, so the media and the page's interface follow the
/// sheet through its entrance, a drag down and its exit — never a second
/// animation trying to keep pace with UIKit's.
///
/// One height for now: the content's own, at most 60 % of the screen (the
/// owner, 2026-11-03) — a short thread takes a short sheet, with no room
/// above its first row; a full-screen detent waits for the owner's approval
/// of this one. The sheet is undimmed, so the media above it stays
/// lit; a tap there closes it, as a swipe down does.
@MainActor
final class SnapCommentsSheetSession: NSObject, UIAdaptivePresentationControllerDelegate {
    /// The sheet's tallest resting height, as a share of the screen.
    static let restingShare: CGFloat = 0.6
    static let detent = UISheetPresentationController.Detent.Identifier("feed.comments.v2")
    /// Between the shrunk media's bottom and the sheet's top.
    static let mediaGap: CGFloat = Spacing.md

    let postID: PostID
    /// What is presented: the content in a stack of its own, for its bar.
    let sheet: UINavigationController
    let content: SnapCommentsSheetViewController
    private weak var feed: UIViewController?
    private weak var cell: SnapFeedCell?
    private let onEnd: () -> Void
    /// Above the sheet, over the page: a tap closes the sheet, and nothing
    /// under it (the pager, the page's taps) can be reached meanwhile.
    private let catcher = UIView()
    private var link: CADisplayLink?
    /// The top bar's items the sheet hid, given back once it has gone, and
    /// whether it hid the back button.
    private var hiddenNavigationItems: [UIBarButtonItem] = []
    private var hidBackButton = false
    private var hasEnded = false
    /// The sheet is on its way out: its height holds still.
    private var isLeaving = false
    /// The content height the detent last resolved against.
    private var fittedHeight: CGFloat?
    /// Where the sheet's top rests, in the window: kept while it is not
    /// leaving (`follow`).
    private var restingTop: CGFloat?

    /// - Parameters:
    ///   - walletBadge: the balance for the sheet's bar, nil for none (a
    ///     guest, a feed that shows no balance); the feed keeps it current.
    ///   - onWalletTap: what a tap on it does, nil for display only.
    init(postID: PostID, panel: UIViewController, cell: SnapFeedCell, feed: UIViewController,
         walletBadge: WalletBadgeButton?, onWalletTap: (() -> Void)?,
         onEnd: @escaping () -> Void) {
        self.postID = postID
        content = SnapCommentsSheetViewController(panel: panel, walletBadge: walletBadge, onWalletTap: onWalletTap)
        sheet = UINavigationController(rootViewController: content)
        self.feed = feed
        self.cell = cell
        self.onEnd = onEnd
        super.init()
    }

    func present(animated: Bool) {
        guard let feed, let window = feed.view.window else { return end() }
        let screenHeight = window.bounds.height
        let share = Self.restingShare
        // A custom detent's height leaves out the bottom safe area, which the
        // content's own height includes.
        let bottomInset = window.safeAreaInsets.bottom
        sheet.modalPresentationStyle = .pageSheet
        sheet.presentationController?.delegate = self
        // Dark, the sheet's own material included: the panel is drawn for the
        // dark page it lived on, and a sheet the keyboard grows otherwise
        // turns to a light glass under its white text.
        sheet.overrideUserInterfaceStyle = .dark
        sheet.presentationController?.traitOverrides.userInterfaceStyle = .dark
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.custom(identifier: Self.detent) { [weak content] context in
                let cap = min(context.maximumDetentValue, screenHeight * share)
                let fitted = MainActor.assumeIsolated { content?.fittedHeight }
                return fitted.map { min(cap, $0 - bottomInset) } ?? cap
            }]
            controller.largestUndimmedDetentIdentifier = Self.detent
            controller.prefersGrabberVisible = true
            controller.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        content.onDismissed = { [weak self] in self?.end() }
        content.onClose = { [weak self] in self?.close() }

        // The page's top bar items leave with its interface.
        setTopBarItemsHidden(true, animated: animated)
        catcher.frame = feed.view.bounds
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        feed.view.addSubview(catcher)
        // Laid out at the sheet's width before it is presented, so the first
        // height it resolves is already its content's.
        sheet.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: screenHeight * share + bottomInset)
        content.composerBottomInset = bottomInset
        sheet.view.layoutIfNeeded()
        content.applyPanelInsets()
        content.view.layoutIfNeeded()
        fittedHeight = content.fittedHeight

        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        feed.present(sheet, animated: animated)
        follow()
    }

    /// Closes the sheet; the session ends when it has gone.
    @objc func close() {
        guard !hasEnded, sheet.presentingViewController != nil else { return }
        sheet.view.endEditing(true)
        isLeaving = true
        content.freeze()
        feed?.dismiss(presented: sheet)
    }

    /// The page's TOP BAR items: gone while the sheet is up, back once it
    /// has gone, as the sheet found them. Idempotent.
    ///
    /// ⚠️ THE ITEMS, NOT THE BAR (the owner, 2026-11-03): each item hidden
    /// the way UIKit provides (`UIBarButtonItem.isHidden`, the back button's
    /// `setHidesBackButton`), which the bar animates itself; hiding the bar
    /// slid it up and out.
    ///
    /// ⚠️ AND NEVER THE TOOLBAR (measured, 2026-11-03): a toolbar with no
    /// item left — or hidden — leaves the page's safe area, and the page's
    /// interface, anchored to it, dropped 52 pt the instant the sheet was
    /// asked for. The sheet covers the toolbar from its first frame and
    /// uncovers it on the way out: it is left alone.
    private func setTopBarItemsHidden(_ hidden: Bool, animated: Bool) {
        guard let screen = feed?.navigationController?.topViewController else { return }
        let item = screen.navigationItem
        if hidden {
            hiddenNavigationItems = ((item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []))
                .filter { !$0.isHidden }
            hiddenNavigationItems.forEach { $0.isHidden = true }
            if !item.hidesBackButton {
                hidBackButton = true
                item.setHidesBackButton(true, animated: animated)
            }
            return
        }
        hiddenNavigationItems.forEach { $0.isHidden = false }
        hiddenNavigationItems = []
        if hidBackButton {
            hidBackButton = false
            item.setHidesBackButton(false, animated: animated)
        }
    }

    /// The page as the sheet stands this frame.
    fileprivate func follow() {
        guard let cell, let window = cell.window,
              let container = sheet.presentationController?.containerView,
              let presented = sheet.presentationController?.presentedView else { return }
        let height = window.bounds.height
        // Where the sheet IS on screen, mid-animation or under a finger: its
        // presentation layer, carried up the presentation tree to the window.
        let top: CGFloat
        if let layer = presented.layer.presentation() {
            top = layer.convert(layer.bounds, to: nil).minY
        } else {
            top = container.convert(presented.frame, to: nil).minY
        }
        // …against where it RESTS. The model frame is the end of whatever is
        // animating — the rest on the way in and on a refit — but once the
        // sheet starts to leave it is the finger's, then the exit's, off the
        // screen. Read there (measured, 2026-11-03), the progress stayed at 1
        // under the finger and ran to 157 on the release: the media held its
        // shrunk size all the way down and jumped to full screen at the end.
        // So the rest is kept from before the sheet started to leave.
        if !isLeaving { restingTop = container.convert(presented.frame, to: nil).minY }
        guard let restingTop else { return }
        let progress = (height - top) / max(1, height - restingTop)
        // The room above the sheet, a breath short of its top: the media
        // never touches the sheet.
        let roomTop = window.safeAreaInsets.top
        let region = CGRect(
            x: 0, y: roomTop, width: window.bounds.width, height: max(1, top - Self.mediaGap - roomTop)
        )
        cell.setCommentsSheetLayout(progress: progress, mediaRegion: region)
        refit()
    }

    /// The detent again when the content's height has moved — rows landing,
    /// a thread's replies opening, the other tab — never on the way out.
    private func refit() {
        guard !isLeaving, let controller = sheet.sheetPresentationController else { return }
        let fitted = content.fittedHeight
        if let fitted, let last = fittedHeight, abs(fitted - last) < 1 { return }
        guard fitted != fittedHeight else { return }
        fittedHeight = fitted
        controller.animateChanges { controller.invalidateDetents() }
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        link?.invalidate()
        link = nil
        catcher.removeFromSuperview()
        cell?.clearCommentsSheetLayout()
        setTopBarItemsHidden(false, animated: true)
        onEnd()
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    /// A swipe down has begun: the sheet leaves from here, unless it is let
    /// go back to its rest.
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        isLeaving = true
        content.freeze()
        sheet.transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            guard context.isCancelled else { return }
            self?.isLeaving = false
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        end()
    }
}

/// The display link's target, holding the session weakly: a link retains its
/// target, and the session must not outlive its sheet through it.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var session: SnapCommentsSheetSession?

    init(_ session: SnapCommentsSheetSession) {
        self.session = session
    }

    @objc func tick() {
        session?.follow()
    }
}

/// The sheet's content: today's comments panel as it is in the page (#2087's
/// first step: the panel moves, its redesign comes after), under the sheet's
/// own bar — the Popular | Recent selector leading, the balance trailing (the
/// owner, 2026-11-03), the page's own balance gone with the page's bar.
final class SnapCommentsSheetViewController: UIViewController {
    static let tabsItemID = "feed.comments.sheet.tabs"
    static let closeItemID = "feed.comments.sheet.close"

    let panel: UIViewController
    private let tabs = CommentTabsSelector()
    let walletBadge: WalletBadgeButton?
    var onDismissed: (() -> Void)?
    /// The bar's ✕.
    var onClose: (() -> Void)?
    private lazy var closeItem = BarItems.icon(
        id: Self.closeItemID, image: UIImage(systemName: "xmark"), label: "Close comments"
    ) { [weak self] in self?.onClose?() }
    private let keyboardObservers = NotificationObserverBag()
    /// Over the list's top edge, as tall as the bar: what makes UIKit draw
    /// the soft edge under it (`viewWillAppear`).
    private let topPocket = UIView()
    private let topPocketElement = UILabel()
    private let topPocketInteraction = UIScrollEdgeElementContainerInteraction()

    init(panel: UIViewController, walletBadge: WalletBadgeButton?, onWalletTap: (() -> Void)?) {
        self.panel = panel
        self.walletBadge = walletBadge
        super.init(nibName: nil, bundle: nil)
        guard let walletBadge else { return }
        walletBadge.isUserInteractionEnabled = onWalletTap != nil
        if let onWalletTap {
            walletBadge.addAction(UIAction { _ in onWalletTap() }, for: .primaryActionTriggered)
        }
        // A grown count needs a FRESH item: the bar measured the old one once
        // (see `WalletBadgeButton`).
        walletBadge.onFittedWidthChange = { [weak self] in self?.installWalletItem() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = BarItems.container(id: Self.tabsItemID, view: tabs.tabBar)
        installWalletItem()

        addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        panel.view.backgroundColor = .clear
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
        NSLayoutConstraint.activate([
            // Under the bar: the rows pass behind it, its soft edge over them.
            panel.view.topAnchor.constraint(equalTo: view.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // ⚠️ AN UNTITLED BAR DRAWS NO EDGE IN A SHEET. UIKit resolves the
        // soft top effect under a bar of pills alone to the status band
        // (`StatusBarBlurView`), and a sheet has none — so the list passed
        // under the tabs with nothing between. `BottomEdgeBlurView`'s pocket,
        // at the top: a view over the edge, holding content (a clear label —
        // an empty view draws nothing), takes the bar's place.
        topPocket.isUserInteractionEnabled = false
        topPocket.accessibilityElementsHidden = true
        topPocket.translatesAutoresizingMaskIntoConstraints = false
        topPocketElement.text = " "
        topPocketElement.textColor = .clear
        topPocketElement.isAccessibilityElement = false
        topPocketElement.translatesAutoresizingMaskIntoConstraints = false
        topPocket.addSubview(topPocketElement)
        view.addSubview(topPocket)
        NSLayoutConstraint.activate([
            topPocket.topAnchor.constraint(equalTo: view.topAnchor),
            topPocket.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topPocket.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topPocket.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The whole pocket: the edge is drawn as tall as what it holds.
            topPocketElement.topAnchor.constraint(equalTo: topPocket.topAnchor),
            topPocketElement.bottomAnchor.constraint(equalTo: topPocket.bottomAnchor),
            topPocketElement.leadingAnchor.constraint(equalTo: topPocket.leadingAnchor),
            topPocketElement.trailingAnchor.constraint(equalTo: topPocket.trailingAnchor),
        ])
        tabs.bind(to: panel as? PostDetailViewController)
        // ⚠️ THE KEYBOARD'S GUIDE IS ANCHORED TO THE SCREEN: with no keyboard
        // up, the input row's ceiling is the screen's bottom, so a sheet
        // sliding in or out left the field pinned there while everything
        // else moved (the owner, 2026-11-03). The sheet moves as ONE frozen
        // piece: the row follows the keyboard only while one is coming up.
        let detail = panel as? PostDetailViewController
        detail?.setComposerTracksKeyboard(false)
        let center = NotificationCenter.default
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak detail] _ in MainActor.assumeIsolated { detail?.setComposerTracksKeyboard(true) } })
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak detail] _ in MainActor.assumeIsolated { detail?.setComposerTracksKeyboard(false) } })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let detail = panel as? PostDetailViewController else { return }
        // The app's soft edges, top and bottom; the bar follows the tab shown.
        detail.wearSheetEdges()
        if topPocketInteraction.view == nil {
            topPocketInteraction.edge = .top
            topPocket.addInteraction(topPocketInteraction)
        }
        follow(detail.stream.collectionView)
        detail.onVisibleStreamChange = { [weak self, weak detail] _ in
            guard let self, let detail else { return }
            follow(detail.stream.collectionView)
        }
    }

    /// The bar and the top pocket on the list shown.
    private func follow(_ list: UIScrollView) {
        setContentScrollView(list, for: .top)
        topPocketInteraction.scrollView = list
    }

    /// The panel's height for what it shows (`PostDetailViewController.fittedHeight`).
    var fittedHeight: CGFloat? { (panel as? PostDetailViewController)?.fittedHeight }

    /// The sheet is leaving: its content moves as one piece from here.
    func freeze() {
        (panel as? PostDetailViewController)?.setComposerTracksKeyboard(false)
    }

    /// The trailing run, right to left: the ✕ at the edge, the balance to its
    /// left (the owner, 2026-11-03) — a fixed space between, or iOS 26 groups
    /// the two adjacent items into one platter.
    private func installWalletItem() {
        guard let walletBadge else { return navigationItem.rightBarButtonItems = [closeItem] }
        navigationItem.rightBarButtonItems = [
            closeItem,
            .fixedSpace(Spacing.sm),
            BarItems.container(id: BarItems.SharedID.walletBalance, view: walletBadge),
        ]
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyPanelInsets()
    }

    /// The bottom inset the composer rests over: the WINDOW's, known before
    /// the sheet is presented and the same all the way in. The sheet's own
    /// safe area passes through 0, 34 and 23 pt as it rises (measured), and
    /// the composer rode each value — the sheet's content is frozen (#2087).
    var composerBottomInset: CGFloat = 0
    /// What the panel was last given, so a pass that changes nothing moves
    /// nothing (`setEngagedInsets` puts the stream back at its top).
    private var appliedInsets: (top: CGFloat, bottom: CGFloat)?

    /// The panel's insets: under the bar, the page's breath before the first
    /// row (`SnapCommentsLayout.streamTopBreath`); the composer resting on the
    /// sheet's bottom edge, a breath over the window's bottom inset — not on
    /// the band the page keeps for its toolbar, which the panel's engaged
    /// layout otherwise reserves. The bar's own bottom stands in for the
    /// safe area while the sheet is laid out ahead of its presentation.
    func applyPanelInsets() {
        guard let detail = panel as? PostDetailViewController else { return }
        let bar = navigationController.map { view.convert($0.navigationBar.frame, from: $0.view).maxY } ?? 0
        let top = max(view.safeAreaInsets.top, bar) + SnapCommentsLayout.streamTopBreath
        let bottom = max(0, composerBottomInset + Spacing.sm - detail.composerRestingGap)
        if let applied = appliedInsets, abs(applied.top - top) < 0.5, abs(applied.bottom - bottom) < 0.5 { return }
        appliedInsets = (top, bottom)
        detail.setEngagedInsets(top: top, bottomInset: bottom)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true { onDismissed?() }
    }
}
