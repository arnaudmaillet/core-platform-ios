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
/// One height for now (60 %); a full-screen detent waits for the owner's
/// approval of this one. The sheet is undimmed, so the media above it stays
/// lit; a tap there closes it, as a swipe down does.
@MainActor
final class SnapCommentsSheetSession: NSObject, UIAdaptivePresentationControllerDelegate {
    /// The sheet's resting height, as a share of the screen.
    static let restingShare: CGFloat = 0.6
    static let detent = UISheetPresentationController.Detent.Identifier("feed.comments.v2")

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
    /// The bars as the sheet found them, given back as it leaves.
    private var barsWereHidden: (navigation: Bool, toolbar: Bool)?
    private var hasEnded = false

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
        sheet.modalPresentationStyle = .pageSheet
        sheet.presentationController?.delegate = self
        // Dark, the sheet's own material included: the panel is drawn for the
        // dark page it lived on, and a sheet the keyboard grows otherwise
        // turns to a light glass under its white text.
        sheet.overrideUserInterfaceStyle = .dark
        sheet.presentationController?.traitOverrides.userInterfaceStyle = .dark
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.custom(identifier: Self.detent) { context in
                min(context.maximumDetentValue, screenHeight * share)
            }]
            controller.largestUndimmedDetentIdentifier = Self.detent
            controller.prefersGrabberVisible = true
            controller.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        content.onDismissed = { [weak self] in self?.end() }

        // The page's bars leave with its interface, through UIKit's own API.
        if let navigation = feed.navigationController {
            barsWereHidden = (navigation.isNavigationBarHidden, navigation.isToolbarHidden)
        }
        setBarsHidden(true, animated: animated)
        catcher.frame = feed.view.bounds
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        feed.view.addSubview(catcher)

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
        content.freeze()
        // The bars come back WITH the sheet's exit, not after it.
        setBarsHidden(false, animated: true)
        feed?.dismiss(presented: sheet)
    }

    /// The page's bars: gone while the sheet is up, as the sheet found them
    /// otherwise. Idempotent — the exit asks more than once.
    private func setBarsHidden(_ hidden: Bool, animated: Bool) {
        guard let barsWereHidden, let navigation = feed?.navigationController else { return }
        let navigationHidden = hidden || barsWereHidden.navigation
        let toolbarHidden = hidden || barsWereHidden.toolbar
        if navigation.isNavigationBarHidden != navigationHidden {
            navigation.setNavigationBarHidden(navigationHidden, animated: animated)
        }
        if navigation.isToolbarHidden != toolbarHidden {
            navigation.setToolbarHidden(toolbarHidden, animated: animated)
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
        // …against where it rests: the model frame is already the end of
        // whatever is animating.
        let restingTop = container.convert(presented.frame, to: nil).minY
        let progress = (height - top) / max(1, height - restingTop)
        let roomTop = window.safeAreaInsets.top
        let region = CGRect(x: 0, y: roomTop, width: window.bounds.width, height: max(1, top - roomTop))
        cell.setCommentsSheetLayout(progress: progress, mediaRegion: region)
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        link?.invalidate()
        link = nil
        catcher.removeFromSuperview()
        cell?.clearCommentsSheetLayout()
        setBarsHidden(false, animated: true)
        onEnd()
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    /// A swipe down has begun: the bars start back now, and leave again if
    /// the sheet is let go back to its rest.
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        setBarsHidden(false, animated: true)
        content.freeze()
        sheet.transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            guard context.isCancelled else { return }
            self?.setBarsHidden(true, animated: true)
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

    let panel: UIViewController
    private let tabs = CommentTabsSelector()
    let walletBadge: WalletBadgeButton?
    var onDismissed: (() -> Void)?
    private let keyboardObservers = NotificationObserverBag()

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
            panel.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    /// The sheet is leaving: its content moves as one piece from here.
    func freeze() {
        (panel as? PostDetailViewController)?.setComposerTracksKeyboard(false)
    }

    private func installWalletItem() {
        navigationItem.rightBarButtonItem = walletBadge.map {
            BarItems.container(id: BarItems.SharedID.walletBalance, view: $0)
        }
    }

    /// The composer rests on the SHEET's bottom edge, its home indicator
    /// cleared by a breath — not on the band the page keeps for its toolbar,
    /// which the panel's engaged layout otherwise reserves (#2087).
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let detail = panel as? PostDetailViewController else { return }
        let rest = view.safeAreaInsets.bottom + Spacing.sm
        detail.setEngagedInsets(top: 0, bottomInset: max(0, rest - detail.composerRestingGap))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true { onDismissed?() }
    }
}
