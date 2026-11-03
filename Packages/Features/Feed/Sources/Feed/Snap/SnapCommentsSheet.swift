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
///   │  Popular | Recent    │
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
    let sheet: SnapCommentsSheetViewController
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

    init(postID: PostID, panel: UIViewController, cell: SnapFeedCell, feed: UIViewController,
         onEnd: @escaping () -> Void) {
        self.postID = postID
        sheet = SnapCommentsSheetViewController(panel: panel)
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
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.custom(identifier: Self.detent) { context in
                min(context.maximumDetentValue, screenHeight * share)
            }]
            controller.largestUndimmedDetentIdentifier = Self.detent
            controller.prefersGrabberVisible = true
            controller.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        sheet.onDismissed = { [weak self] in self?.end() }

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

/// The sheet's content: the Popular | Recent selector over today's comments
/// panel, as it is in the page (#2087's first step: the panel moves, its
/// redesign comes after).
final class SnapCommentsSheetViewController: UIViewController {
    let panel: UIViewController
    private let tabs = CommentTabsSelector()
    var onDismissed: (() -> Void)?

    init(panel: UIViewController) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The panel is drawn for the dark page it lived on.
        overrideUserInterfaceStyle = .dark
        let header = tabs.tabBar
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        panel.view.backgroundColor = .clear
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.lg),
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.sm),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tabs.bind(to: panel as? PostDetailViewController)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismissed?() }
    }
}
