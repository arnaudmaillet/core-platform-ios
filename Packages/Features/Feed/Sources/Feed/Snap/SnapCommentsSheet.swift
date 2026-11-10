import CoreModels
import CoreNavigation
import DesignSystem
import UIKit

/// A media post's comments as a NATIVE SHEET (#2087) —
/// the TikTok arrangement the owner asked for on 2026-11-03:
///
///   ┌──────────────────────┐
///   │      [ media ]       │  ← the post's media, shrunk WHOLE into the room
///   │                      │    above, centred, still playing; the page's
///   ├──────────────────────┤    interface and bars gone
///   │ [Popular|Recent] [♥ 250] │  ← the sheet's own bar: the tabs, the balance
///   │  comment rows …      │  ← today's comments panel, in a UIKit sheet
///   │  [ compose bar ]     │    resting at the height the media leaves it
///   └──────────────────────┘
///
/// ONE MEASURE DRIVES THE PAGE: the sheet's top, read every frame from its
/// presentation layer, so the media and the page's interface follow the
/// sheet through its entrance, a drag down and its exit — never a second
/// animation trying to keep pace with UIKit's.
///
/// ONE HEIGHT PER SHAPE, NEVER ITS COMMENTS' (#2195, the owner 2026-11-08):
/// collapsed, the sheet rests at its media's shape's height
/// (`restingHeight`, `CommentsSheetShape`) — the same sheet with no comments
/// or a thousand, as TikTok and Instagram keep it. Comments arriving, a
/// comment sent, replies opened, Popular ↔ Recent: nothing refits it; they
/// only decide whether the expanded detent is offered
/// (`offerExpandedDetentIfNeeded`). A short thread reads in the room left:
/// Popular from the top, Recent from the bottom, as a conversation.
///
/// Expanded, for a shape that offers it (portrait today) and comments that
/// outgrow the collapsed sheet: up to the top of the screen, the media
/// shrinking on in the room left and a floating preview taking it from
/// there. ONCE EXPANDED, the sheet offers that detent alone (the owner,
/// 2026-11-10): a swipe down closes it straight to the bottom, UIKit's own
/// dismissal deciding, and the collapsed height is back at the next opening
/// (`CommentsSheetDetents`). A full-width shape (square, 4:3, 16:9) keeps its
/// one height and never shrinks; the comments scroll inside the sheet. The
/// sheet is undimmed, so the media above it stays lit; a tap there closes
/// it, as a swipe down does.
@MainActor
final class SnapCommentsSheetSession: NSObject, UISheetPresentationControllerDelegate {
    /// The sheet's numbers, next to its catalogue (#2195 § 5).
    private static let layout = CommentsSheetLayout.standard
    static let detent = CommentsSheetDetents.collapsed
    /// The sheet up to the top of the screen — offered only while the
    /// comments outgrow `detent` (the owner, 2026-11-03), the media shrinking
    /// on in the room left above it; once selected, the only one
    /// (`CommentsSheetDetents`).
    static let expandedDetent = CommentsSheetDetents.expanded

    /// The sheet's collapsed height: ONE per shape on a screen (#2184, #2195,
    /// `CommentsSheetShape`), read once, at the opening — a carousel paged
    /// under the sheet does not move it, and its comments never do. The
    /// shape's `layout` decides:
    ///
    /// - **`shrinksIntoRoom`** (portrait): the media shrinks into the room
    ///   above a sheet between `floorShare` and `ceilingShare` of the screen —
    ///   the width would leave the sheet no room.
    /// - **`fullWidth`** (square, 4:3, 16:9): the media keeps the screen's
    ///   whole width, less `mediaSideMargin` on each side (it never touches
    ///   them, the owner 2026-11-03), and the sheet takes exactly what is
    ///   left — never under `minimumSheetHeight`, where the media shrinks to
    ///   fit instead (a square on an iPhone SE).
    ///
    /// On a 17 Pro Max: 60 % portrait, 45 % square, 56 % 4:3, 64 % 16:9. A
    /// picture not known yet gets the floor, as a shrinking shape would.
    ///
    /// The height of a custom detent, so it leaves out the bottom safe area
    /// the sheet stands on.
    ///
    /// - Parameter picture: what the sheet shrinks, as the page draws it
    ///   (`SnapFeedCell.commentsSheetPictureSize`).
    static func restingHeight(
        screen: CGSize, safeArea: UIEdgeInsets, picture: CGSize,
        catalogue: [CommentsSheetShape] = CommentsSheetShape.catalogue,
        layout: CommentsSheetLayout = .standard
    ) -> CGFloat {
        let ceiling: CGFloat = screen.height * layout.ceilingShare
        let floor: CGFloat = screen.height * layout.floorShare
        guard let shape = CommentsSheetShape.of(picture, in: catalogue) else { return floor }
        let mediaWidth: CGFloat = screen.width - 2 * layout.mediaSideMargin
        let mediaHeight: CGFloat = mediaWidth * picture.height / picture.width
        let reserved: CGFloat = safeArea.top + mediaHeight + layout.mediaGap + safeArea.bottom
        let left: CGFloat = screen.height - reserved
        let lowest: CGFloat = shape.layout == .shrinksIntoRoom ? floor : layout.minimumSheetHeight
        return min(max(left, lowest), ceiling)
    }

    /// Whether a sheet over a picture of `picture`'s shape offers its
    /// expanded detent at all (#2184): the shape says
    /// (`CommentsSheetShape.offersExpandedDetent`, portrait only today); a
    /// full-width media keeps its one height and never shrinks — the comments
    /// scroll inside the sheet. A picture not known yet offers it, as the
    /// floor height it gets is a shrinking shape's.
    static func offersExpandedDetent(
        picture: CGSize, catalogue: [CommentsSheetShape] = CommentsSheetShape.catalogue
    ) -> Bool {
        CommentsSheetShape.of(picture, in: catalogue)?.offersExpandedDetent ?? true
    }

    let postID: PostID
    /// What is presented: the content itself, carrying its own bar.
    var sheet: UIViewController { content }
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
    /// Where the sheet's top rests, in the window: kept while it is not
    /// leaving (`follow`).
    private var restingTop: CGFloat?
    /// The sheet's top as last drawn (`follow`): what a frame that cannot be
    /// read is given.
    private var lastDrawnTop: CGFloat?
    /// The collapsed detent last resolved under the screen's top (a floating
    /// sheet's), and where the sheet's top should then rest, in the window
    /// (`correctCap`).
    private var restsAtCap = false
    private var capTop: CGFloat?
    /// The detents' rule for this opening (#2195): the shape's height, whether
    /// the shape offers the expanded detent, and whether it has been selected
    /// since the sheet opened. A new opening is a new session: the collapsed
    /// detent is back.
    private var detentRule = CommentsSheetDetents(restingHeight: 0, bottomInset: 0, offersExpanded: false)
    /// The sheet left from expanded (#2195, the owner 2026-11-10): the top
    /// the media's growth back to full screen is measured from — where the
    /// leave began, then where the media took the picture back from its
    /// preview (`follow`). Nil otherwise.
    private var leaveRestTop: CGFloat?
    /// What a floating sheet's detent needs on top of `restingHeight` to rest
    /// where it says, measured on the first sheet and kept (`correctCap`).
    private static var capCorrection: CGFloat = 0
    /// Follows the keyboard's top, frame by frame — its interactive
    /// dismissal included, which no notification reports.
    private let keyboardTracker = UIView()
    /// The keyboard's top, in the window, as it rests while up.
    private var keyboardRestTop: CGFloat?
    /// The keyboard is animating away: the sheet is UIKit's again.
    private var isKeyboardHiding = false
    private let keyboardObservers = NotificationObserverBag()

    /// - Parameters:
    ///   - walletBadge: the balance for the sheet's bar, nil for none (a
    ///     guest, a feed that shows no balance); the feed keeps it current.
    ///   - onWalletTap: what a tap on it does, nil for display only.
    init(postID: PostID, panel: UIViewController, cell: SnapFeedCell, feed: UIViewController,
         walletBadge: WalletBadgeButton?, onWalletTap: (() -> Void)?,
         onEnd: @escaping () -> Void) {
        self.postID = postID
        content = SnapCommentsSheetViewController(panel: panel, walletBadge: walletBadge, onWalletTap: onWalletTap)
        self.feed = feed
        self.cell = cell
        self.onEnd = onEnd
        super.init()
    }

    func present(animated: Bool) {
        guard let feed, let window = feed.view.window, let cell else { return end() }
        let resting = Self.restingHeight(
            screen: window.bounds.size, safeArea: window.safeAreaInsets, picture: cell.commentsSheetPictureSize
        )
        // A custom detent's height leaves out the bottom safe area, which the
        // content's own height includes.
        let bottomInset = window.safeAreaInsets.bottom
        sheet.modalPresentationStyle = .pageSheet
        sheet.presentationController?.delegate = self
        // The DEVICE's style (the owner, 2026-11-03), the sheet's own material
        // included — read off the window, which the page's dark pin over a
        // photograph does not reach — and followed while the sheet is up.
        applyStyle(window.traitCollection.userInterfaceStyle)
        styleRegistration = window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (window: UIWindow, _) in
            self?.applyStyle(window.traitCollection.userInterfaceStyle)
        }
        // ⚠️ ONE LEVEL AT BOTH HEIGHTS (measured on a device, 2026-11-03):
        // UIKit raises a sheet at the screen's top to the elevated level and
        // lowers it again below — every view in it re-read its traits at each
        // detent change, ~10 ms of the frame that starts the move, and the
        // dynamic colours shifted between the two heights.
        sheet.traitOverrides.userInterfaceLevel = .base
        let rule = CommentsSheetDetents(
            restingHeight: resting, bottomInset: bottomInset,
            offersExpanded: Self.offersExpandedDetent(picture: cell.commentsSheetPictureSize)
        )
        detentRule = rule
        if let controller = sheet.sheetPresentationController {
            // ⚠️ THE SHAPE'S HEIGHT, WHATEVER THE COMMENTS (#2195): no content
            // height reaches this closure, so nothing the comments do can
            // move the collapsed sheet — only the floating sheet's
            // correction, once, on the way in (`correctCap`).
            collapsedDetent = .custom(identifier: Self.detent) { [weak self] context in
                MainActor.assumeIsolated {
                    let maximum = context.maximumDetentValue
                    let height = rule.collapsedHeight(capCorrection: Self.capCorrection, maximum: maximum)
                    self?.restsAtCap = height < maximum
                    return height
                }
            }
            controller.largestUndimmedDetentIdentifier = Self.expandedDetent
            if #available(iOS 26.1, *) { controller.backgroundEffect = UIColorEffect(color: Self.ground) }
            controller.prefersGrabberVisible = true
            // A scroll at the top of the rows grows the sheet first, as a
            // drag on its bar does — with nothing to grow to, it scrolls.
            controller.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        capTop = window.bounds.height - resting - bottomInset
        content.onDetachedEditingChanged = { [weak self] editing in self?.holdDetent(editing) }
        // ⚠️ THE FIELD EXPANDS THE SHEET (#2153, the owner 2026-11-05). From
        // collapsed, writing moved the sheet twice: up with the keys, then
        // back down without them. Now a way into the field (a tap, Reply, a
        // mention) expands it first, when it can, and the keys come to the
        // detached bar over the rows: one movement, and the sheet stays
        // expanded when they go (`holdDetent`). Asked here because this is
        // read as the keys are about to come: expanded any later, the keys
        // would go to the sheet's own bar and UIKit would raise it first.
        // With nothing to expand to, the collapsed sheet still rides the keys
        // (the owner, 2026-11-04).
        content.detachesKeyboard = { [weak self] in
            guard let self, let controller = sheet.sheetPresentationController else { return false }
            let route = Self.fieldRoute(
                selected: controller.selectedDetentIdentifier,
                offersExpanded: controller.detents.contains { $0.identifier == Self.expandedDetent }
            )
            if route.expands {
                controller.animateChanges {
                    controller.selectedDetentIdentifier = Self.expandedDetent
                    // Selected in code, which UIKit does not report: the
                    // collapsed detent goes in the same change.
                    self.detentSelected(Self.expandedDetent)
                }
            }
            return route.detached
        }
        content.onDismissed = { [weak self] in self?.end() }
        content.onClose = { [weak self] in self?.close() }

        // The page's top bar items leave with its interface.
        setTopBarItemsHidden(true, animated: animated)
        catcher.frame = feed.view.bounds
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mediaTapped)))
        feed.view.addSubview(catcher)
        keyboardTracker.isUserInteractionEnabled = false
        keyboardTracker.translatesAutoresizingMaskIntoConstraints = false
        catcher.addSubview(keyboardTracker)
        catcher.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            keyboardTracker.topAnchor.constraint(equalTo: catcher.keyboardLayoutGuide.topAnchor),
            keyboardTracker.leadingAnchor.constraint(equalTo: catcher.leadingAnchor),
            keyboardTracker.widthAnchor.constraint(equalToConstant: 1),
            keyboardTracker.heightAnchor.constraint(equalToConstant: 1),
        ])
        observeKeyboard()
        // Laid out at its height before it is presented: the stream settles
        // in the room it will have (a short Recent anchored to its bottom),
        // and its content's height is known.
        sheet.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: resting + bottomInset)
        content.composerBottomInset = bottomInset
        sheet.view.layoutIfNeeded()
        content.applyPanelInsets()
        content.view.layoutIfNeeded()
        // The detents once the content's height is known: the expanded one
        // only for comments that outgrow the collapsed one.
        if let controller = sheet.sheetPresentationController { applyDetents(to: controller) }

        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        // As fast as the screen: a 120 Hz sheet followed at 60 drags its
        // media a frame behind every other frame (measured, 2026-11-03).
        link.preferredFrameRateRange = DisplayLinkTarget.movingRate
        link.add(to: .main, forMode: .common)
        observeCommits()
        self.link = link
        feed.present(sheet, animated: animated)
        follow()
    }

    /// A tap on the media above the sheet: with the keyboard up, it puts the
    /// keyboard away and nothing else (the owner, 2026-11-03); otherwise it
    /// closes the sheet.
    /// The keyboard put away, wherever it is edited — in the sheet, or in
    /// the detached composer over it.
    private func endEditing() {
        sheet.view.endEditing(true)
        content.endDetachedEditing()
    }

    @objc private func mediaTapped() {
        if content.isKeyboardUp {
            endEditing()
            return
        }
        close()
    }

    /// The keyboard's resting top as it comes up, and its going.
    private func observeKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                self?.isKeyboardHiding = false
                self?.keyboardRestTop = frame?.minY
            }
        })
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] note in
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            MainActor.assumeIsolated { self?.keyboardWillHide(duration: duration) }
        })
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isKeyboardHiding = false
                self?.keyboardRestTop = nil
            }
        })
    }

    /// The keyboard dragged down by the finger (interactive dismissal): the
    /// whole sheet goes down with it, as iOS's own sheets over a keyboard do
    /// (the owner, 2026-11-03). UIKit only moves the sheet on the keyboard's
    /// notifications, none of which a drag sends: the sheet is translated by
    /// how far the keyboard's top stands under its rest, read every frame.
    ///
    /// ⚠️ ON THE PRESENTATION'S CONTAINER, NOT THE SHEET (measured,
    /// 2026-11-03): UIKit writes the sheet's own transform (its
    /// `UIDropShadowView`) on every layout, and a translation set there never
    /// showed. The container (`UITransitionView`) holds the sheet alone and is
    /// left to us.
    private func followKeyboardDrag() {
        // The detached composer's keyboard is not the sheet's: it never moves it.
        guard !content.editsDetached, !isKeyboardHiding, let keyboardRestTop,
              let container = sheet.presentationController?.containerView else { return }
        catcher.layoutIfNeeded()
        let keyboardTop = keyboardTracker.convert(CGPoint.zero, to: nil).y
        // ⚠️ A SHEET HELD AT THE SCREEN'S TOP STAYS (the owner, 2026-11-03):
        // moved down whole with the keys, its bar left the top — not how a
        // conversation lets its keyboard go. Its composer follows the keys
        // down instead, the rows above it with it. A sheet riding on the keys
        // goes down with them, or they would leave a hole under it.
        if content.followKeyboardDrag(to: keyboardTop, restingAt: keyboardRestTop) {
            if container.transform != .identity { container.transform = .identity }
            return
        }
        let drop = max(0, keyboardTop - keyboardRestTop)
        guard abs(container.transform.ty - drop) > 0.5 else { return }
        container.transform = drop > 0 ? CGAffineTransform(translationX: 0, y: drop) : .identity
    }

    /// The keyboard is going: the drag's translation is let go in the same
    /// animation as UIKit's own lowering of the sheet, so the two land as one.
    private func keyboardWillHide(duration: TimeInterval) {
        isKeyboardHiding = true
        guard let container = sheet.presentationController?.containerView,
              container.transform != .identity else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) {
            container.transform = .identity
        }
    }

    /// Closes the sheet; the session ends when it has gone.
    @objc func close() {
        guard !hasEnded, sheet.presentingViewController != nil else { return }
        endEditing()
        beginLeaving()
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

    /// The sheet's top as last followed, and whether UIKit is animating it
    /// or the keyboard is on the move (the display link's pace).
    fileprivate var lastFollowedTop: CGFloat? { lastDrawnTop }
    fileprivate var isAnimating: Bool {
        isKeyboardHiding || (sheet.presentationController?.presentedView?.layer.animationKeys()?.isEmpty == false)
            || preview?.layer.animationKeys()?.isEmpty == false
            || (!isPreviewUnavailable && mediaOutShare != (previewOwnsMedia ? 1 : 0))
    }

    /// The display link's frame as `follow` is called for it: its time, and
    /// when the frame it builds is shown. Nil off the link.
    fileprivate var frameTiming: (now: CFTimeInterval, shown: CFTimeInterval)?
    /// The sheet's top as last read, and when.
    private var lastTopReading: (top: CGFloat, at: CFTimeInterval)?
    /// A reading on the model frame from afar, held back a frame (`follow`).
    private var pendingEndRead: CGFloat?
    private static let endReadFar: CGFloat = 40
    /// The top last shown while UIKit animates the sheet, and towards where.
    private var lastShownTop: (top: CGFloat, towards: CGFloat)?

    private func predictedTop(drawn: CGFloat, model: CGFloat) -> CGFloat {
        defer { if let frameTiming { lastTopReading = (drawn, frameTiming.now) } }
        guard let frameTiming, abs(drawn - model) > 0.5,
              let last = lastTopReading, frameTiming.now > last.at else {
            if abs(drawn - model) <= 0.5 { lastShownTop = nil }
            return drawn
        }
        let speed = (drawn - last.top) / CGFloat(frameTiming.now - last.at)
        let ahead = drawn + speed * CGFloat(frameTiming.shown - frameTiming.now)
        var shown = min(max(ahead, min(drawn, model)), max(drawn, model))
        // ⚠️ NEVER BACK ON THE WAY (measured, 2026-11-04): frames come at
        // uneven times, and the speed read from them with them — a top
        // carried far ahead one frame, less the next, went back (254, 276,
        // 260 pt) and the preview riding it shook. On the way to one end the
        // shown top only goes on towards it.
        if let previous = lastShownTop, abs(previous.towards - model) < 0.5 {
            shown = model > drawn ? max(shown, min(previous.top, model)) : min(shown, max(previous.top, model))
        }
        lastShownTop = (shown, model)
        return shown
    }

    /// Before each commit: a sheet moved under a finger since the link's call
    /// — a touch handled after it — is followed in the same frame.
    private var followCommitObserver: CFRunLoopObserver?
    private var lastFollowedModelTop: CGFloat?

    private func observeCommits() {
        // Just ahead of Core Animation's own commit observer (order 2 000 000).
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // The keys under a finger too: the rows held over the
                // composer after the finger's last scroll.
                self?.followKeyboardDrag()
                self?.followIfMovedByHand()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        followCommitObserver = observer
    }

    private func followIfMovedByHand() {
        guard let container = sheet.presentationController?.containerView,
              let presented = sheet.presentationController?.presentedView,
              presented.layer.animationKeys()?.isEmpty ?? true else { return }
        let modelTop = container.convert(presented.frame, to: nil).minY
        guard let last = lastFollowedModelTop, abs(modelTop - last) > 0.1 else { return }
        let timing = frameTiming
        frameTiming = nil
        follow()
        frameTiming = timing
    }

    /// The page as the sheet stands this frame.
    fileprivate func follow() {
        followKeyboardDrag()
        guard let cell, let window = cell.window,
              let container = sheet.presentationController?.containerView,
              let presented = sheet.presentationController?.presentedView else { return }
        let height = window.bounds.height
        // Where the sheet IS on screen, mid-animation or under a finger: its
        // presentation layer, carried up the presentation tree to the window.
        //
        // ⚠️ ONE FRAME OF A DETENT CHANGE READS 0 (measured, 2026-11-03): the
        // presentation layer, carried up a tree UIKit is rearranging, put the
        // sheet at the screen's very top for a frame — the media handed to
        // its preview all at once, the preview flashed up at its corner and
        // back. No sheet stands above the screen's top inset: such a reading
        // is the last frame's — not the model frame's, which is already the
        // detent the sheet is on its way to.
        let modelTop = container.convert(presented.frame, to: nil).minY
        var drawnTop = lastDrawnTop ?? modelTop
        if let layer = presented.layer.presentation() {
            let read = layer.convert(layer.bounds, to: nil).minY
            if read >= window.safeAreaInsets.top - 1 { drawnTop = read }
        } else {
            drawnTop = modelTop
        }
        // ⚠️ ONE FRAME AT THE END BEFORE THE MOVE (measured, 2026-11-04):
        // as the keys go, the sheet read where it is going (62 → 361 pt) for
        // one frame — its new place set, the animation to it not yet
        // attached — then back where it stood (66 pt), and on. The media and
        // its preview swapped for that frame, the preview thrown 300 pt. A
        // reading landing on the model frame from far, no finger on the
        // sheet, waits a frame: still there, the sheet did move at once.
        if let last = lastDrawnTop, abs(drawnTop - modelTop) < 0.5, abs(last - modelTop) > Self.endReadFar,
           pendingEndRead != modelTop, !isSheetDragged {
            pendingEndRead = modelTop
            drawnTop = last
        } else if abs(drawnTop - modelTop) >= 0.5 || pendingEndRead != modelTop {
            pendingEndRead = nil
        }
        lastDrawnTop = drawnTop
        // ⚠️ ONE FRAME AHEAD (measured on a device, 2026-11-03): read at the
        // display link's call, the presentation layer is the sheet NOW, and
        // the frame this pass builds is shown a frame later — the media a
        // frame behind the sheet, the gap between them breathing with the
        // sheet's speed. While UIKit animates the sheet (its drawn top is not
        // its model's), its top is carried on at its current speed to the
        // moment the frame is shown, never past where it is going. Under a
        // finger there is no animation: the model frame is the sheet's, and
        // it is followed before the frame commits (`followCommitObserver`).
        let shownTop = predictedTop(drawn: drawnTop, model: modelTop)
        // …against where it RESTS. The model frame is the end of whatever is
        // animating — the rest on the way in — but once the
        // sheet starts to leave it is the finger's, then the exit's, off the
        // screen. Read there (measured, 2026-11-03), the progress stayed at 1
        // under the finger and ran to 157 on the release: the media held its
        // shrunk size all the way down and jumped to full screen at the end.
        // So the rest is kept from before the sheet started to leave.
        //
        // ⚠️ AND FROM BEFORE THE KEYBOARD CAME (measured, 2026-11-03). UIKit
        // raises the sheet over the keyboard (its top from 507 to 193 pt):
        // read then, the rest jumped with it — the progress fell to 0.54 and
        // the media grew back towards full screen for a frame. Against the
        // rest from before, a sheet above it is past 1 (held there by the
        // page), and the media shrinks with the rising sheet into the room
        // left above it (the owner, 2026-11-03).
        //
        // ⚠️ AND NEVER ABOVE THE COLLAPSED DETENT'S TOP (the expanded one,
        // 2026-11-03): pulled up, and resting expanded, the model frame is
        // the finger's and the expanded rest. The collapsed rest is never
        // higher than its cap's top: a sheet above it is past 1, the page
        // held there, and a drag back down shows the page again only once
        // the sheet is below its collapsed rest.
        lastFollowedModelTop = modelTop
        if !isLeaving, !content.isKeyboardUp {
            if sheet.isBeingPresented { correctCap(restingAt: modelTop) }
            restingTop = max(modelTop, capTop ?? modelTop)
        }
        guard let restingTop else { return }
        let top = shownTop
        // The room above the sheet, a breath short of its top and of the
        // screen's sides: the media never touches them.
        //
        // ⚠️ NEVER SMALLER THAN ITS PREVIEW (the owner, 2026-11-03): shrunk
        // on with the sheet, the media became a speck its corners turned to
        // a lozenge. It stops at the preview's size, where the preview takes
        // it over as the sheet goes on rising (`followPreview`); with no
        // preview to take it, it scales out where it stands.
        let roomTop = window.safeAreaInsets.top
        let room = top - Self.layout.mediaGap - roomTop
        // ⚠️ ON THE KEYS, THE MEDIA STAYS (the owner, 2026-11-04): a
        // collapsed sheet the keys raise is held there — pulled, it gives a
        // few points — and handing the picture to the preview for those left
        // the room above empty. While the keys carry the sheet (and as they
        // go), the media shrinks on with the room down to `keyboardFloor`;
        // only a room smaller than that is the preview's.
        let ridesKeys = (content.isKeyboardUp || isKeyboardHiding) && !content.editsDetached
        let previewHeight = SnapCommentsPreview.size(
            for: cell.commentsSheetPictureSize, screenWidth: window.bounds.width
        ).height
        let smallest = ridesKeys ? min(previewHeight, Self.keyboardFloor) : previewHeight
        let region = CGRect(
            x: Self.layout.mediaSideMargin, y: roomTop,
            width: window.bounds.width - 2 * Self.layout.mediaSideMargin,
            height: max(room, smallest)
        )
        let wasPreviewOwned = previewOwnsMedia
        if isSheetAtRest(top: top) {
            previewOwnsMedia = room < smallest - Self.previewTakesAt
        } else if !previewOwnsMedia, room < smallest - Self.previewTakesAt {
            previewOwnsMedia = true
        } else if previewOwnsMedia, room > smallest + Self.mediaTakesBackAt {
            previewOwnsMedia = false
        }
        if room >= smallest { isPreviewUnavailable = false }
        // ⚠️ FROM EXPANDED, ONE MOVE TO FULL SCREEN (#2195, the owner
        // 2026-11-10). Measured against the collapsed rest, the media came
        // back from the preview at the room's size, held it down to the
        // collapsed sheet's top — the shrunk media of a sheet the swipe never
        // stops at — and only then grew to full screen. Leaving from
        // expanded, its growth is measured from where it takes the picture
        // back (`leaveRestTop`): from the preview's size, at that top, to
        // full screen at the bottom, in one curve.
        if leaveRestTop != nil, wasPreviewOwned, !previewOwnsMedia { leaveRestTop = top }
        let progressRest: CGFloat = leaveRestTop ?? restingTop
        let progress: CGFloat = (height - top) / max(1, height - progressRest)
        // Out before the preview comes — one picture at a time; with no
        // preview to come, out past its smallest, with the sheet.
        let out: CGFloat = isPreviewUnavailable
            ? min(1, max(0, (smallest - room) / Self.mediaOutSpan))
            : timedMediaOut()
        // From the collapsed rest's room down to the smallest: the corners
        // turn the preview's on the way. Leaving from expanded, they go with
        // the growth itself.
        let restingRoom = restingTop - Self.layout.mediaGap - roomTop
        let towardsPreview: CGFloat = leaveRestTop != nil
            ? min(1, max(0, progress))
            : min(1, max(0, (restingRoom - room) / max(1, restingRoom - smallest)))
        let sheetRadius = sheetCornerRadius(below: container)
        cell.setCommentsSheetLayout(
            progress: progress, mediaRegion: region, sheetCornerRadius: sheetRadius, out: out,
            towardsPreview: towardsPreview, previewCornerRadius: SnapCommentsPreview.cornerRadius
        )
        followPreview(wantsPreview: previewOwnsMedia && mediaOutShare >= 1, in: window, sheetTop: top)
        offerExpandedDetentIfNeeded()
    }

    // MARK: The preview

    /// The media floating over the sheet once it has grown over it, nil
    /// while the media stands above the sheet.
    private var preview: SnapCommentsPreview?
    /// The media has nothing for a preview to draw: it scales out instead.
    private var isPreviewUnavailable = false
    /// The room lost, past the media's smallest, over which it scales out.
    private static let mediaOutSpan: CGFloat = 64
    /// ONE PICTURE AT A TIME (the owner, 2026-11-03), AND ALWAYS ONE (the
    /// owner, 2026-11-04). One state says whose the picture is: the preview
    /// takes it once the room above the sheet is `previewTakesAt` short of
    /// the media's smallest, and gives it back once the room is
    /// `mediaTakesBackAt` past it. The media scales out (`timedMediaOut`),
    /// then the preview pops in (`setPreviewPopped`); back, the preview goes
    /// and the media scales in.
    ///
    /// ⚠️ NO HEIGHT WITH NEITHER (the owner's video, 2026-11-04): the media
    /// and the preview had thresholds of their own, the media out within
    /// 12 pt of its smallest, the preview in only 24 pt past it — a band
    /// with no picture, said to be crossed only. A sheet raised by the keys
    /// rests where UIKit puts it, and rested in it. Between the two
    /// thresholds the picture stays whose it was: the media, its smallest,
    /// a few points under the sheet's edge at most.
    ///
    /// ⚠️ AT REST, ONE THRESHOLD (the owner's video, 2026-11-04): the band
    /// between the two is there for a finger at the threshold, and a sheet
    /// the keys raise rests in it — pulled up and let go, it came back with
    /// the preview and an empty room over it. Once the sheet stands still,
    /// no finger on it, the picture is the media's wherever it fits
    /// (`isSheetAtRest`): one picture for one height, however it got there.
    private var previewOwnsMedia = false
    private static let previewTakesAt: CGFloat = 8
    /// The media's smallest height while the keys carry the sheet.
    private static let keyboardFloor: CGFloat = 64
    private static let mediaTakesBackAt: CGFloat = 24
    private static let mediaOutDuration: CFTimeInterval = 0.2
    /// How long the sheet stands still before it is at rest.
    private static let restAfter: CFTimeInterval = 0.12
    /// The sheet's top since it last moved, and since when.
    private var stillTop: (top: CGFloat, since: CFTimeInterval)?

    /// The sheet still for `restAfter`, UIKit not animating it, no finger
    /// dragging it.
    private func isSheetAtRest(top: CGFloat) -> Bool {
        let now = frameTiming?.now ?? CACurrentMediaTime()
        if stillTop.map({ abs($0.top - top) >= 0.5 }) ?? true { stillTop = (top, now) }
        guard let stillTop, now - stillTop.since >= Self.restAfter,
              sheet.presentationController?.presentedView?.layer.animationKeys()?.isEmpty != false else { return false }
        return !isSheetDragged
    }

    /// A pan on the sheet or its frame — UIKit's own drag — under way.
    private var isSheetDragged: Bool {
        let container = sheet.presentationController?.containerView
        var view = sheet.presentationController?.presentedView
        while let current = view, current !== container {
            let dragging = current.gestureRecognizers?.contains {
                $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed)
            } ?? false
            if dragging { return true }
            view = current.superview
        }
        return false
    }
    /// The media's way out, 0 in, 1 out.
    private var mediaOutShare: CGFloat = 0
    private var lastMediaOutTime: CFTimeInterval?

    /// ⚠️ THE MEDIA'S WAY OUT IN ITS OWN TIME, as the preview's pop (the
    /// owner, 2026-11-03): played over the room's last points, a quick throw
    /// crossed them in a frame or two and the media vanished at once. The
    /// sheet decides when (`previewOwnsMedia`); the scale-out takes
    /// `mediaOutDuration` whatever its speed, advanced frame by frame on the
    /// display link's clock, and turns back from where it stands. Its SIZE
    /// stays the sheet's: the room above it.
    private func timedMediaOut() -> CGFloat {
        let target: CGFloat = previewOwnsMedia ? 1 : 0
        if let now = frameTiming?.now {
            if let last = lastMediaOutTime, mediaOutShare != target {
                let step = CGFloat((now - last) / Self.mediaOutDuration)
                mediaOutShare = target > mediaOutShare
                    ? min(target, mediaOutShare + step)
                    : max(target, mediaOutShare - step)
            }
            lastMediaOutTime = now
        }
        return Self.smoothstep(mediaOutShare)
    }
    /// The preview's size, as a share of its own, as it pops in and out.
    private static let popFrom: CGFloat = 0.5

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let t = min(max(0, t), 1)
        return t * t * (3 - 2 * t)
    }


    /// ⚠️ THE SHEET DRIVES THE HAND-OVER, frame by frame (the owner,
    /// 2026-11-03). Played as an animation when the media crossed its
    /// smallest size, it bounced in and out under a finger held at the
    /// threshold, landed back on a media already bigger than itself (a jump
    /// in size), and lost the race with a sheet closed from expanded (the
    /// media popped back full screen at the end). Now the media scales out
    /// where it stands, then the preview pops in at its corner, both as
    /// `previewOwnsMedia` says: under the finger, both ways, and out with the
    /// closing sheet. Carrying the media to the corner instead was tried and
    /// dropped (the owner, 2026-11-03).
    ///
    /// ⚠️ ONE PREVIEW A SHEET, hidden and shown, never made again at the
    /// threshold (measured, 2026-11-03): a new one's mirror drew a black frame
    /// before the player's next picture reached it.
    private func followPreview(wantsPreview: Bool, in window: UIWindow, sheetTop: CGFloat) {
        lastSheetTop = sheetTop
        if preview == nil {
            guard wantsPreview, !isLeaving, !isPreviewUnavailable, let cell,
                  let picture = cell.commentsSheetPictureFrame, picture.width > 0, picture.height > 0 else { return }
            let size = SnapCommentsPreview.size(for: picture.size, screenWidth: window.bounds.width)
            guard makePreview(size: size, in: window) else {
                isPreviewUnavailable = true
                return
            }
        }
        guard let preview else { return }
        // In its corner, riding with the sheet's bar; left where it is under
        // a finger and while it settles in a corner.
        if !isPreviewHeld {
            let corner = previewFrame(size: preview.bounds.size, in: window, sheetTop: sheetTop)
            preview.center = CGPoint(x: corner.midX, y: corner.midY)
        }
        if wantsPreview != isPreviewPopped { setPreviewPopped(wantsPreview) }
    }

    /// Whether the preview is popped in, or on its way in.
    private var isPreviewPopped = false

    /// ⚠️ THE POP PLAYS IN ITS OWN TIME (the owner, 2026-11-03): driven by
    /// the sheet, a quick throw played it in a frame or two — a jump. The
    /// sheet decides WHEN (`followPreview`); the pop takes the same time
    /// whatever its speed, and a pop turned back mid-way goes back from where
    /// it stands.
    private func setPreviewPopped(_ popped: Bool) {
        guard let preview, let cell else { return }
        isPreviewPopped = popped
        if popped {
            if preview.isHidden {
                setPreviewShown(true)
                preview.alpha = 0
                preview.transform = CGAffineTransform(scaleX: Self.popFrom, y: Self.popFrom)
            }
            UIView.animate(
                withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                preview.alpha = 1
                preview.transform = .identity
            }
        } else {
            // The media is the sheet's again at once — it scales back in with
            // the sheet — as the preview fades out over it.
            cell.setCommentsSheetMediaHidden(false)
            cell.setPausedMarkVisible(isMediaPaused, animated: false)
            UIView.animate(
                withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseIn, .allowUserInteraction]
            ) {
                preview.alpha = 0
                preview.transform = CGAffineTransform(scaleX: Self.popFrom, y: Self.popFrom)
            } completion: { [weak self] _ in
                guard let self, !self.isPreviewPopped else { return }
                self.setPreviewShown(false)
            }
        }
    }

    /// The corner the preview stands in (`SnapCommentsPreview.lastCorner`),
    /// and whether it is stashed off that corner's side.
    private var previewCorner = SnapCommentsPreview.lastCorner
    private var isPreviewStashed = false
    /// A finger holds the preview, or it is settling where it was thrown:
    /// it does not ride with the sheet meanwhile.
    private var isPreviewHeld = false
    /// The sheet's top as last followed: where the preview's corners stand.
    private var lastSheetTop: CGFloat = 0

    /// Where the preview stands, in its corner (the top right by default,
    /// the owner, 2026-11-03), the media's margin from the side:
    ///
    /// - up top, under the sheet's bar — riding with the sheet as it rises,
    ///   never over its ✕ and balance — the screen's top once expanded;
    /// - down below, over the composer (and the keyboard under it).
    ///
    /// Stashed, all but a tab of it off its side.
    private func previewFrame(size: CGSize, in window: UIWindow, sheetTop: CGFloat) -> CGRect {
        let bounds = previewBounds(in: window, sheetTop: sheetTop)
        let y = previewCorner.isTop ? bounds.minY : max(bounds.minY, bounds.maxY - size.height)
        let x: CGFloat
        switch (previewCorner.isLeading, isPreviewStashed) {
        case (true, false): x = bounds.minX
        case (false, false): x = bounds.maxX - size.width
        case (true, true): x = SnapCommentsPreview.stashedTab - size.width
        case (false, true): x = window.bounds.width - SnapCommentsPreview.stashedTab
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The room the preview's corners stand in: under the sheet's bar, over
    /// its composer, the media's margins from the sides.
    private func previewBounds(in window: UIWindow, sheetTop: CGFloat) -> CGRect {
        let top = max(window.safeAreaInsets.top, sheetTop) + content.barBottom + Spacing.sm
        let bottom = (content.composerTop ?? window.bounds.height - window.safeAreaInsets.bottom) - Spacing.sm
        return CGRect(
            x: Self.layout.mediaSideMargin, y: top,
            width: window.bounds.width - 2 * Self.layout.mediaSideMargin, height: max(0, bottom - top)
        )
    }

    /// A drag on the preview: it follows the finger, then goes, thrown, to
    /// the corner nearest where it would come to rest — or, thrown past a
    /// side, is stashed there; thrown back in, it comes out again.
    private func previewPanned(_ pan: UIPanGestureRecognizer) {
        guard let preview, let window = preview.window else { return }
        switch pan.state {
        case .began:
            isPreviewHeld = true
            preview.layer.removeAllAnimations()
        case .changed:
            let move = pan.translation(in: window)
            preview.center = CGPoint(x: preview.center.x + move.x, y: preview.center.y + move.y)
            pan.setTranslation(.zero, in: window)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: window)
            // Where it would come to rest, thrown: a fifth of a second on.
            let landing = CGPoint(x: preview.center.x + velocity.x * 0.2, y: preview.center.y + velocity.y * 0.2)
            let bounds = previewBounds(in: window, sheetTop: lastSheetTop)
            previewCorner = .at(top: landing.y < bounds.midY, leading: landing.x < window.bounds.midX)
            SnapCommentsPreview.lastCorner = previewCorner
            isPreviewStashed = landing.x < 0 || landing.x > window.bounds.width
            settlePreview(velocity: velocity, in: window)
        default:
            break
        }
    }

    /// A tap on the preview plays or pauses the clip (the owner,
    /// 2026-11-03) — its stopped mark on the preview, not on the page under
    /// the sheet — and brings a stashed preview out again.
    private func previewTapped() {
        guard let preview, let window = preview.window else { return }
        if isPreviewStashed {
            isPreviewStashed = false
            isPreviewHeld = true
            settlePreview(velocity: .zero, in: window)
            return
        }
        guard let paused = cell?.togglePlayback(markOnPage: false) else { return }
        isMediaPaused = paused
        preview.showPaused(paused)
    }

    /// The clip stands paused — before the preview came, or from it: the
    /// preview wears the stopped mark meanwhile, the page once the media is
    /// back in place.
    private var isMediaPaused = false

    /// The preview's expand button: the sheet down to its collapsed height,
    /// the media back above it — the preview flies into it on the way
    /// (`followPreview`). The keyboard goes first.
    ///
    /// A tap asking for it, not a swipe (#2195): the collapsed detent, taken
    /// out once the sheet expanded, comes back with it — and the expanded
    /// detent's rule starts over, as at an opening.
    private func previewExpanded() {
        guard let controller = sheet.sheetPresentationController else { return }
        if content.isKeyboardUp { endEditing() }
        detentRule.collapseAgain()
        let identifiers = detentRule.identifiers(contentHeight: content.contentHeight, capCorrection: Self.capCorrection)
        controller.animateChanges {
            if !holdsDetent { controller.detents = detents(for: identifiers) }
            controller.selectedDetentIdentifier = Self.detent
        }
    }

    /// The preview into its corner, on a spring carrying the throw.
    private func settlePreview(velocity: CGPoint, in window: UIWindow) {
        guard let preview else { return }
        let frame = previewFrame(size: preview.bounds.size, in: window, sheetTop: lastSheetTop)
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let distance = hypot(target.x - preview.center.x, target.y - preview.center.y)
        let speed = hypot(velocity.x, velocity.y)
        let stashed = isPreviewStashed ? previewCorner.isLeading : nil
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8,
            initialSpringVelocity: distance > 1 ? speed / distance : 0, options: [.allowUserInteraction]
        ) {
            preview.center = target
            preview.showStash(leading: stashed)
        } completion: { [weak self] _ in
            self?.isPreviewHeld = false
        }
    }

    /// A preview for the media, over the media, which it hides — false
    /// when the media has nothing for it to draw.
    private func makePreview(size: CGSize, in window: UIWindow) -> Bool {
        guard let cell, let picture = cell.commentsSheetPictureFrame,
              let media = cell.makeCommentsPreviewContent() else { return false }
        let preview = SnapCommentsPreview(content: media)
        preview.onPan = { [weak self] pan in self?.previewPanned(pan) }
        preview.onTap = { [weak self] in self?.previewTapped() }
        preview.onExpand = { [weak self] in self?.previewExpanded() }
        preview.bounds = CGRect(origin: .zero, size: size)
        preview.center = CGPoint(x: picture.midX, y: picture.midY)
        preview.isHidden = true
        window.addSubview(preview)
        self.preview = preview
        return true
    }

    /// The preview out, over the media it hides, or back in the media, the
    /// media shown — the clip's stopped mark going with whichever shows it.
    private func setPreviewShown(_ shown: Bool) {
        guard let preview, preview.isHidden == shown, let cell else { return }
        if shown {
            isMediaPaused = cell.showsPausedMark
            preview.showPaused(isMediaPaused)
            // Out towards the last corner, and out of any stash.
            isPreviewStashed = false
            preview.showStash(leading: nil)
            previewCorner = SnapCommentsPreview.lastCorner
            preview.isHidden = false
            cell.setCommentsSheetMediaHidden(true)
        } else {
            preview.layer.removeAllAnimations()
            isPreviewHeld = false
            isPreviewPopped = false
            preview.isHidden = true
            preview.alpha = 1
            preview.transform = .identity
            cell.setCommentsSheetMediaHidden(false)
            cell.setPausedMarkVisible(isMediaPaused, animated: false)
        }
    }

    /// The preview gone at once: the media back in place, its mirror let go.
    private func removePreview() {
        setPreviewShown(false)
        isPreviewHeld = false
        guard let preview else { return }
        self.preview = nil
        cell?.releaseCommentsPreviewContent(preview.content)
        isMediaPaused = false
        preview.removeFromSuperview()
    }

    /// The sheet's corners as UIKit rounds them: on a view's corner
    /// configuration, never its layer's radius (all 0, measured) — the
    /// largest on the way up from the sheet's view. A media tile's before
    /// iOS 26, which has no such configuration.
    private func sheetCornerRadius(below container: UIView) -> CGFloat {
        guard #available(iOS 26.0, *) else { return Spacing.lg }
        var radius: CGFloat = 0
        var view: UIView? = sheet.view
        while let current = view, current !== container {
            radius = max(radius, current.effectiveRadius(corner: .topLeft))
            view = current.superview
        }
        return radius
    }

    /// ⚠️ A FLOATING SHEET RESTS LOWER THAN ITS DETENT SAYS (measured,
    /// 2026-11-03): inset from the screen's edges, it stood ~15 pt under the
    /// top `restingHeight` reckons (the screen's height less the detent and
    /// the bottom safe area), so the room above it outgrew the media and the
    /// gap under the media with it (16 pt seen for 8). The difference is read
    /// where the sheet rests at its cap — from the first frame, its model
    /// frame is already the rest — given back to the detent, and kept for
    /// the next sheet. On the way in only: once up, the model frame is also
    /// a finger's, and the cap does not move.
    private func correctCap(restingAt modelTop: CGFloat) {
        guard restsAtCap, let capTop, let controller = sheet.sheetPresentationController else { return }
        let error = modelTop - capTop
        guard abs(error) > 0.5, abs(Self.capCorrection + error) < 60 else { return }
        Self.capCorrection += error
        controller.animateChanges { controller.invalidateDetents() }
    }

    /// ⚠️ THE CONTENT NEVER MOVES THE SHEET (#2195, the owner 2026-11-08).
    /// Rows landing, a comment sent, replies opened, the other tab: until
    /// #2195 each refitted the collapsed sheet to its content, animated —
    /// the media above shrinking and moving with it — and the height held
    /// while the keys carried the sheet existed only for that refit (a
    /// comment sent with the keys up refitted it 85 pt above them): it went
    /// with it. A change of content now only offers the expanded detent, or
    /// takes it back, as the comments outgrow the collapsed sheet or no
    /// longer do: a change of the list alone, with the collapsed detent
    /// selected, which moves nothing.
    ///
    /// Never on the way out, nor while the detached composer holds the list
    /// (`holdDetent`), nor while the keys carry the sheet: UIKit lays the
    /// sheet out again over the keys on a change of its list. The offer
    /// comes once they have gone — the collapsed height the same.
    private func offerExpandedDetentIfNeeded() {
        guard !isLeaving, !holdsDetent, !content.isKeyboardUp, !isKeyboardHiding,
              let controller = sheet.sheetPresentationController else { return }
        applyDetents(to: controller)
    }

    /// The list the rule asks for, set only when it differs from the one up.
    private func applyDetents(to controller: UISheetPresentationController) {
        let wanted = detentRule.identifiers(contentHeight: content.contentHeight, capCorrection: Self.capCorrection)
        guard controller.detents.map(\.identifier) != wanted else { return }
        controller.detents = detents(for: wanted)
    }

    /// A detent selected, by a drag (`sheetPresentationControllerDidChangeSelectedDetentIdentifier`)
    /// or in code (the field's way in, #2153): once it is the expanded one,
    /// the collapsed one leaves the list (#2195). The sheet stands at the
    /// expanded detent, which stays: the change is invisible.
    private func detentSelected(_ identifier: UISheetPresentationController.Detent.Identifier?) {
        let had = detentRule.hasExpanded
        detentRule.select(identifier)
        guard detentRule.hasExpanded, !had, !isLeaving, !holdsDetent,
              let controller = sheet.sheetPresentationController else { return }
        applyDetents(to: controller)
    }

    /// The selected detent, as the sheet stands now.
    private var isExpanded: Bool {
        sheet.sheetPresentationController?.selectedDetentIdentifier == Self.expandedDetent
    }

    /// While the detached composer edits, the sheet holds its height: a drag
    /// at the rows' top puts the keys away and leaves the sheet be.
    private var holdsDetent = false

    private func holdDetent(_ hold: Bool) {
        guard hold != holdsDetent, let controller = sheet.sheetPresentationController else { return }
        holdsDetent = hold
        // On the way out, the list is left to the exit.
        guard !isLeaving else { return }
        // ⚠️ THE UNDIMMED DETENT WITH IT (the owner, 2026-11-04): left on the
        // expanded one, missing from a list held at the collapsed one, UIKit
        // dimmed the page at once — a black veil over the media.
        if hold {
            let current = controller.selectedDetentIdentifier ?? Self.detent
            controller.largestUndimmedDetentIdentifier = current
            controller.detents = controller.detents.filter { $0.identifier == current }
        } else {
            let wanted = detentRule.identifiers(contentHeight: content.contentHeight, capCorrection: Self.capCorrection)
            controller.detents = detents(for: wanted)
            controller.largestUndimmedDetentIdentifier = Self.expandedDetent
        }
    }

    /// What a way into the field does (#2153): from expanded, the keys go to
    /// the detached bar; from collapsed with an expanded detent offered, the
    /// sheet expands and they go there too; with none, the sheet's own bar
    /// edits and the sheet rides the keys. Pure.
    static func fieldRoute(
        selected: UISheetPresentationController.Detent.Identifier?, offersExpanded: Bool
    ) -> (detached: Bool, expands: Bool) {
        if selected == expandedDetent { return (true, false) }
        return offersExpanded ? (true, true) : (false, false)
    }

    /// The collapsed detent (`present`), kept to rebuild the list with.
    private var collapsedDetent: UISheetPresentationController.Detent?

    /// The sheet's detents for the rule's identifiers, in its order.
    private func detents(
        for identifiers: [UISheetPresentationController.Detent.Identifier]
    ) -> [UISheetPresentationController.Detent] {
        identifiers.compactMap { identifier -> UISheetPresentationController.Detent? in
            if identifier == Self.detent { return collapsedDetent.map(Self.opaque) }
            let expanded = UISheetPresentationController.Detent.custom(identifier: Self.expandedDetent) { context in
                context.maximumDetentValue
            }
            return Self.opaque(expanded)
        }
    }

    private var styleRegistration: (any UITraitChangeRegistration)?

    private func applyStyle(_ style: UIUserInterfaceStyle) {
        sheet.overrideUserInterfaceStyle = style
        sheet.presentationController?.traitOverrides.userInterfaceStyle = style
    }

    /// The sheet's ground: opaque, the page's plain background in the
    /// device's style (the owner, 2026-11-03: not the glass, grey over the
    /// black page in light) — on
    /// every detent and the presentation itself, or it is glass on the way
    /// up (as the wallet sheet found, #1494).
    private static let ground = UIColor.systemBackground

    private static func opaque(
        _ detent: UISheetPresentationController.Detent
    ) -> UISheetPresentationController.Detent {
        if #available(iOS 26.1, *) { detent.backgroundEffect = UIColorEffect(color: ground) }
        return detent
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        link?.invalidate()
        link = nil
        if let styleRegistration { feed?.view.window?.unregisterForTraitChanges(styleRegistration) }
        styleRegistration = nil
        if let followCommitObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), followCommitObserver, .commonModes) }
        followCommitObserver = nil
        removePreview()
        catcher.removeFromSuperview()
        sheet.presentationController?.containerView?.transform = .identity
        cell?.clearCommentsSheetLayout()
        setTopBarItemsHidden(false, animated: true)
        onEnd()
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    /// With the keyboard up, nothing outside the sheet closes it — a tap on
    /// the media puts the keyboard away and nothing else (the owner,
    /// 2026-11-03). ⚠️ That tap never reaches `catcher`: the sheet then
    /// stands taller than its undimmed detent, UIKit lays its own tap-outside
    /// view over the page and asks here (measured) — so the keyboard is put
    /// away from here. A swipe down with the keyboard up does the same.
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard content.isKeyboardUp else { return true }
        DispatchQueue.main.async { [weak self] in self?.endEditing() }
        return false
    }

    /// A swipe down has begun: the sheet leaves from here, unless it is let
    /// go back to its rest.
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        beginLeaving()
        content.freeze()
        sheet.transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            guard context.isCancelled else { return }
            self?.isLeaving = false
            self?.leaveRestTop = nil
        }
    }

    /// The sheet starts to leave: its rest holds still, and from expanded the
    /// media's way back to full screen is measured from here (`follow`).
    private func beginLeaving() {
        isLeaving = true
        leaveRestTop = isExpanded ? (lastDrawnTop ?? capTop) : nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        end()
    }

    // MARK: UISheetPresentationControllerDelegate

    /// A drag let go at another detent: up to the expanded one, the
    /// collapsed one leaves the list (#2195).
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheetPresentationController: UISheetPresentationController
    ) {
        detentSelected(sheetPresentationController.selectedDetentIdentifier)
    }
}

/// The comments sheet's detents for one opening, as one pure rule (#2195):
///
/// - **The collapsed height is the shape's** (`collapsedHeight`): the resting
///   height and the floating sheet's correction, nothing the comments do.
/// - **The expanded detent** is offered while the shape offers it and the
///   comments outgrow the collapsed sheet (`isExpandable`) — the only thing
///   a change of content decides.
/// - **Once the expanded detent is selected, it is the only one** (the owner,
///   2026-11-10): a swipe down from there closes the sheet straight to the
///   bottom, UIKit's own dismissal deciding — no gesture of ours, no
///   velocity read. The collapsed height comes back at the next opening, a
///   new rule (or by the preview's own button, `collapseAgain`); a drag
///   back to it is gone, which the owner accepted.
@MainActor
struct CommentsSheetDetents {
    typealias Identifier = UISheetPresentationController.Detent.Identifier
    static let collapsed = Identifier("feed.comments.v2")
    static let expanded = Identifier("feed.comments.v2.expanded")

    /// The shape's height (`SnapCommentsSheetSession.restingHeight`), a
    /// custom detent's: without the bottom safe area.
    let restingHeight: CGFloat
    /// The bottom safe area the sheet stands on, which the content's height
    /// includes.
    let bottomInset: CGFloat
    /// Whether the media's shape offers the expanded detent at all
    /// (`CommentsSheetShape.offersExpandedDetent`).
    let offersExpanded: Bool
    /// The expanded detent has been selected since this opening.
    private(set) var hasExpanded = false

    init(restingHeight: CGFloat, bottomInset: CGFloat, offersExpanded: Bool) {
        self.restingHeight = restingHeight
        self.bottomInset = bottomInset
        self.offersExpanded = offersExpanded
    }

    /// The collapsed detent's height: the shape's, plus what a floating
    /// sheet needs to rest where it says, within what UIKit allows. No
    /// content height comes in.
    func collapsedHeight(capCorrection: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, restingHeight + capCorrection)
    }

    /// Whether the comments (`contentHeight`, the panel's, nil before it is
    /// known) stand taller than the collapsed sheet, over a shape that
    /// offers the expanded detent.
    func isExpandable(contentHeight: CGFloat?, capCorrection: CGFloat) -> Bool {
        guard offersExpanded, let contentHeight else { return false }
        let collapsed: CGFloat = restingHeight + capCorrection + 1
        return contentHeight - bottomInset > collapsed
    }

    /// The sheet's detents, smallest first: the expanded one alone once
    /// selected; otherwise the collapsed one, and the expanded one while the
    /// comments outgrow it.
    func identifiers(contentHeight: CGFloat?, capCorrection: CGFloat) -> [Identifier] {
        if hasExpanded { return [Self.expanded] }
        let expandable = isExpandable(contentHeight: contentHeight, capCorrection: capCorrection)
        return expandable ? [Self.collapsed, Self.expanded] : [Self.collapsed]
    }

    /// A detent selected, by a drag or in code.
    mutating func select(_ identifier: Identifier?) {
        if identifier == Self.expanded, offersExpanded { hasExpanded = true }
    }

    /// The preview's button asked for the collapsed sheet: as at an opening.
    mutating func collapseAgain() {
        hasExpanded = false
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

    @objc func tick(_ link: CADisplayLink) {
        guard let session else { return }
        let before = session.lastFollowedTop
        session.frameTiming = (link.timestamp, link.targetTimestamp)
        session.follow()
        session.frameTiming = nil
        // ⚠️ AT THE SCREEN'S RATE ONLY WHILE SOMETHING MOVES: a sheet at rest
        // followed 120 times a second for as long as it is up. Still for a
        // quarter second, the link drops to a slow pace; the first frame
        // that moves brings it back (and a finger's move is followed before
        // its frame commits anyway, `followCommitObserver`).
        let moved = before.map { abs($0 - (session.lastFollowedTop ?? $0)) > 0.1 } ?? true
        stillFrames = moved || session.isAnimating ? 0 : stillFrames + 1
        let range = stillFrames > 30 ? Self.restingRate : Self.movingRate
        if link.preferredFrameRateRange != range { link.preferredFrameRateRange = range }
    }

    private var stillFrames = 0
    static let movingRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    private static let restingRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
}

/// The sheet's content: today's comments panel as it is in the page (#2087's
/// first step: the panel moves, its redesign comes after), under the sheet's
/// own bar — the Popular | Recent selector leading, the balance trailing (the
/// owner, 2026-11-03), the page's own balance gone with the page's bar.
///
/// ⚠️ A LONE BAR, NOT A NAVIGATION STACK (profiled, 2026-11-03). Nothing is
/// pushed in the sheet: the stack was there for its bar alone, and moving it
/// into the window — its bars' set-up and position, the insets it hands down
/// — weighed on every opening. The bar is a `UINavigationBar` this screen
/// holds, showing its own `navigationItem`: the same native items, and a
/// height known before the sheet is presented.
final class SnapCommentsSheetViewController: UIViewController, UINavigationBarDelegate, ScreenCovering {
    /// ⚠️ NEVER A COVER, expanded included (#1970's rule would pause the
    /// clip it hides): the media plays on above the sheet, and expanded it
    /// will play on in its preview (#2087).
    var coversScreen: Bool { false }

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
    /// Whether a keyboard is up (or coming up) over the sheet.
    private(set) var isKeyboardUp = false
    /// The panel to the sheet's bottom at rest; to its resting height while
    /// a keyboard is up (`setKeyboardUp`).
    private var panelBottom: NSLayoutConstraint?
    private var panelHeight: NSLayoutConstraint?
    /// The view's height at rest, without a keyboard.
    private var restingHeight: CGFloat = 0
    /// Over the list's top edge, as tall as the bar: what makes UIKit draw
    /// the soft edge under it (`viewWillAppear`).
    private let topPocket = UIView()
    private let topPocketElement = UILabel()
    private let topPocketInteraction = UIScrollEdgeElementContainerInteraction()

    /// The sheet's own bar.
    private let ownBar = UINavigationBar()

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
        let bottom = panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        panelBottom = bottom
        panelHeight = panel.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            // Under the bar: the rows pass behind it, its soft edge over them.
            panel.view.topAnchor.constraint(equalTo: view.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
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
        installOwnBar(ownBar)
        NSLayoutConstraint.activate([
            topPocket.topAnchor.constraint(equalTo: view.topAnchor),
            topPocket.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topPocket.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topPocket.bottomAnchor.constraint(equalTo: ownBar.bottomAnchor),
            // The whole pocket: the edge is drawn as tall as what it holds.
            topPocketElement.topAnchor.constraint(equalTo: topPocket.topAnchor),
            topPocketElement.bottomAnchor.constraint(equalTo: topPocket.bottomAnchor),
            topPocketElement.leadingAnchor.constraint(equalTo: topPocket.leadingAnchor),
            topPocketElement.trailingAnchor.constraint(equalTo: topPocket.trailingAnchor),
        ])
        tabs.bind(to: panel as? PostDetailViewController)
        // ⚠️ THE COMPOSER NEVER RIDES THE KEYBOARD HERE (measured,
        // 2026-11-03). UIKit raises the sheet itself over the keyboard, its
        // resting height just above the keys: the composer, at the foot of
        // the panel held at that height (`setKeyboardUp`), lands over them
        // with the sheet, as one piece. Riding the keyboard's guide as well —
        // a guide anchored to the screen, on the keyboard's curve while the
        // sheet moves on its own — pinned the field at the screen's bottom
        // while a sheet slid in or out, and threw it over the rows while the
        // sheet rose.
        (panel as? PostDetailViewController)?.setComposerTracksKeyboard(false)
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
            keyboardObservers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardWillMove(to: frame) }
            })
        }
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keyboardWillHide() } })
        keyboardObservers.add(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.setKeyboardUp(false) } })
    }

    /// How far the rows go on under the keys' top while they carry the sheet.
    private static let rowsUnderKeys: CGFloat = 48

    /// The composer's stand-in over the keyboard, the expanded detent's
    /// (`detachesKeyboard`).
    private var detachedComposer: SnapCommentsDetachedComposer?

    func endDetachedEditing() {
        detachedComposer?.endEditing()
    }

    /// The detached composer began or ended editing.
    var onDetachedEditingChanged: ((Bool) -> Void)?
    /// Whether the keys go to the detached composer, asked as the composer
    /// is about to edit; nil, they do.
    var detachesKeyboard: (() -> Bool)?
    /// Whether the keys are the detached composer's: the sheet's keyboard
    /// paths leave them be.
    var editsDetached: Bool { detachedComposer?.isEditingDetached == true }


    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detachedComposer?.tearDown()
        setShielded(false)
    }

    /// ⚠️ WITH THE KEYS UP, NOTHING BUT THE COMPOSER (the owner, 2026-11-04):
    /// the rows scrolled, the sheet moved, the preview played under a
    /// finger while a comment was being written. Over the whole window
    /// while the keys carry the sheet, this takes every touch outside the
    /// composer and puts the keys away with it, and nothing else — the
    /// detached composer's way (`SnapCommentsDetachedComposer`). In the
    /// window, not the sheet: a view in the sheet still fed UIKit's drag of it.
    private lazy var shield: KeyboardShield = {
        let shield = KeyboardShield()
        shield.onTouch = { [weak self] in self?.panel.view.endEditing(true) }
        return shield
    }()

    private func setShielded(_ shielded: Bool) {
        guard shielded else {
            shield.removeFromSuperview()
            return
        }
        guard let window = view.window, let detail = panel as? PostDetailViewController else { return }
        shield.passThrough = detail.composeBar
        shield.frame = window.bounds
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(shield)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let detail = panel as? PostDetailViewController else { return }
        if detachedComposer == nil {
            let composer = SnapCommentsDetachedComposer(source: detail.composeBar, sheetView: view)
            composer.onEditingChanged = { [weak self] editing in self?.onDetachedEditingChanged?(editing) }
            composer.detaches = { [weak self] in self?.detachesKeyboard?() ?? true }
            detachedComposer = composer
        }
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

    /// The lone bar: at the sheet's top, under the grabber's band, showing
    /// this screen's item, with no ground of its own — the sheet's material
    /// is its ground, as a stack's bar in a sheet.
    private func installOwnBar(_ bar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.delegate = self
        bar.items = [navigationItem]
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.lg),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func position(for bar: UIBarPositioning) -> UIBarPosition { .top }

    /// The composer's top, in the window: where the preview's lower corners
    /// stop.
    var composerTop: CGFloat? {
        guard let detail = panel as? PostDetailViewController, let host = detail.composeBar.superview,
              !detail.composeBar.isHidden else { return nil }
        return host.convert(detail.composeBar.frame, to: nil).minY
    }

    /// The bar's bottom in this view.
    var barBottom: CGFloat { ownBar.frame.maxY }

    /// The bar and the top pocket on the list shown.
    private func follow(_ list: UIScrollView) {
        setContentScrollView(list, for: .top)
        topPocketInteraction.scrollView = list
    }

    /// The panel's height for what it shows (`PostDetailViewController.fittedHeight`):
    /// whether the comments outgrow the collapsed sheet, and so whether the
    /// expanded detent is offered — never the sheet's height, which is its
    /// shape's (#2195).
    ///
    /// ⚠️ AN EMPTY PAGE, BY ITS OWN BLOCK (measured, 2026-11-04): the "No
    /// comments yet" page stretches over the room it is given, so its rows
    /// only ever measure the sheet. Its block's own height — the caption
    /// over it included — says whether it outgrows the sheet, as the text
    /// post's composer sizes its sheet. (Until #2195 it also sized the
    /// collapsed sheet, which opened ~140 pt too tall without it.)
    var contentHeight: CGFloat? {
        guard let detail = panel as? PostDetailViewController else { return nil }
        if let empty = detail.viewHeightShowingEmptyPage(
            contentSizeCategory: traitCollection.preferredContentSizeCategory
        ) {
            return empty
        }
        return detail.fittedHeight
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isKeyboardUp { restingHeight = view.bounds.height }
    }

    /// A keyboard coming up or changing: the panel's height for it. One going
    /// away (its frame off the screen) is `keyboardWillHide`'s.
    private func keyboardWillMove(to frame: CGRect?) {
        guard let frame, let window = view.window, frame.minY < window.screen.bounds.maxY else { return }
        setKeyboardUp(true)
        if editsDetached { return }
        guard let panelHeight, restingHeight > 0 else { return }
        let height = panelHeightOverKeyboard(at: frame.minY, in: window)
        holdStreamEnd(panelGrowingBy: height - panelHeight.constant)
        panelHeight.constant = height
    }

    /// ⚠️ THE ROW OVER THE COMPOSER STAYS THE ROW OVER THE COMPOSER (the
    /// owner, 2026-11-03). The panel's height changes as a keyboard comes and
    /// goes, and the stream, laid out from its top, showed another last row
    /// over the composer. Its offset takes the change back — inside the
    /// keyboard's animation, which runs this — so what stands over the
    /// composer stays, within what the stream can scroll to.
    private func holdStreamEnd(panelGrowingBy growth: CGFloat) {
        guard abs(growth) > 0.5, let list = (panel as? PostDetailViewController)?.stream.collectionView else { return }
        let inset = list.adjustedContentInset
        let lowest = -inset.top
        let highest = max(lowest, list.contentSize.height + inset.bottom - (list.bounds.height + growth))
        let offset = min(max(list.contentOffset.y - growth, lowest), highest)
        guard abs(offset - list.contentOffset.y) > 0.5 else { return }
        list.contentOffset.y = offset
    }

    /// The panel's height while a keyboard is up, its top at `keyboardTop`
    /// (the window's).
    ///
    /// ⚠️ NEVER READ OFF THE SHEET AS IT STANDS (measured, 2026-11-03). Read
    /// when the keyboard was announced, the sheet was still at rest — the
    /// panel fell to ~70 pt for a frame and the composer crossed the rows —
    /// and read in the layout pass, it moved on the keyboard's curve while
    /// the sheet moved on UIKit's. Two fixed rules instead, set once:
    ///
    /// - UIKit raises a sheet so its resting height stands over the keys,
    ///   its foot ~5 pt under their top (measured): the composer, at rest a
    ///   home indicator and a breath over that foot, stood 35 pt over the
    ///   keys. The keys now cover the home indicator, so the panel's foot
    ///   drops by it, less the breath kept: the composer stands about
    ///   `Spacing.sm` over the keys (the owner, 2026-11-03).
    /// - A sheet too tall for that is held at the top of the screen, its top
    ///   on the window's top inset (measured): its panel ends where the
    ///   composer stands `Spacing.sm` over the keys from there.
    /// The keyboard dragged down under a finger, its top at `keyboardTop`:
    /// for a sheet the keys hold at the screen's top, the panel's foot — the
    /// composer — follows them down, the rows at its end with it, and true;
    /// false for a sheet that rides on the keys, which the session moves.
    func followKeyboardDrag(to keyboardTop: CGFloat, restingAt restTop: CGFloat) -> Bool {
        guard isKeyboardUp, let window = view.window, let panelHeight, restingHeight > 0 else { return false }
        let lowered = restingHeight + composerBottomInset - Spacing.sm
        let heldAtRest = restTop + composerBottomInset - window.safeAreaInsets.top
        guard heldAtRest < lowered else { return false }
        let height = min(view.bounds.height, panelHeightOverKeyboard(at: max(restTop, keyboardTop), in: window, cap: false))
        let growth = height - panelHeight.constant
        guard let list = (panel as? PostDetailViewController)?.stream.collectionView else { return true }
        // ⚠️ THE ROWS FOLLOW THE KEYS, NOT THE FINGER (the owner, 2026-11-04):
        // a drag in the rows that takes the keyboard down also scrolled them
        // with it, and the last row slid under the keys. As in Messages, once
        // the keys move, the rows' end keeps where it stood over the composer
        // — the finger's scroll is held, here, before every commit.
        let inset = list.adjustedContentInset
        let boundsHeight = list.bounds.height + growth
        if keyboardTop > restTop + 0.5 {
            let gap = keyboardDragEndGap ?? (list.contentSize.height + inset.bottom - list.contentOffset.y - list.bounds.height)
            keyboardDragEndGap = gap
            let lowest = -inset.top
            let highest = max(lowest, list.contentSize.height + inset.bottom - boundsHeight)
            let offset = min(max(list.contentSize.height + inset.bottom - boundsHeight - gap, lowest), highest)
            if abs(offset - list.contentOffset.y) > 0.25 { list.contentOffset.y = offset }
        } else {
            keyboardDragEndGap = nil
            holdStreamEnd(panelGrowingBy: growth)
        }
        if abs(growth) > 0.5 { panelHeight.constant = height }
        return true
    }

    /// How far the rows' end stood under the composer as the keys began to
    /// move under a finger (`followKeyboardDrag`).
    private var keyboardDragEndGap: CGFloat?

    private func panelHeightOverKeyboard(at keyboardTop: CGFloat, in window: UIWindow, cap: Bool = true) -> CGFloat {
        let lowered = restingHeight + composerBottomInset - Spacing.sm
        let heldAtTop = keyboardTop + composerBottomInset - window.safeAreaInsets.top
        return max(0, cap ? min(lowered, heldAtTop) : heldAtTop)
    }

    /// The keyboard is going: the panel back on the sheet's foot at once, in
    /// the keyboard's own animation.
    ///
    /// ⚠️ NOT AT ITS END (measured, 2026-11-03): held at a height of its own
    /// until the keyboard had gone, the panel outgrew the shrinking sheet for
    /// ~0.8 s — the composer under its visible edge, and the soft edge drawn
    /// over the composer left standing in the middle of the rows.
    private func keyboardWillHide() {
        setKeyboardUp(false)
    }

    /// ⚠️ THE KEYBOARD DOES NOT RESIZE THE PANEL WITH THE SHEET (measured,
    /// 2026-11-03). UIKit raises the sheet over the keyboard and grows it
    /// down under the keys (its content from 373 to 701 pt). While a keyboard
    /// is up the panel is pinned to the sheet's top at a height of its own
    /// (`panelHeightOverKeyboard(at:in:)`), and the sheet grows below it,
    /// under the keys.
    private func setKeyboardUp(_ up: Bool) {
        // The detached composer edits over the keys: the panel stays as it is.
        if editsDetached {
            isKeyboardUp = up
            return
        }
        guard up != isKeyboardUp, let panelBottom, let panelHeight, restingHeight > 0 else { return }
        isKeyboardUp = up
        keyboardDragEndGap = nil
        setShielded(up)
        // The streams end under the keys, past their rounded corners: the
        // composer stands `Spacing.sm` over them.
        (panel as? PostDetailViewController)?.setStreamsClippedAtComposer(up, below: Spacing.sm + Self.rowsUnderKeys)
        if up {
            panelHeight.constant = restingHeight
            panelBottom.isActive = false
            panelHeight.isActive = true
        } else {
            holdStreamEnd(panelGrowingBy: restingHeight - panelHeight.constant)
            panelHeight.isActive = false
            panelBottom.isActive = true
        }
    }

    /// The sheet is leaving: its content moves as one piece from here. The
    /// composer never rides the keyboard in the sheet (`viewDidLoad`); kept
    /// for the call sites that say so.
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
    ///
    /// ⚠️ THE BAR'S HEIGHT IS LEARNED, NOT MEASURED, UNTIL THE SHEET HAS
    /// SETTLED (profiled, 2026-11-03). A sheet's bar only takes its height on
    /// screen — 44 pt ahead of the presentation, 64 then 70 pt during it —
    /// and each new top re-laid the stream out inside the presentation's
    /// frame: its rows were made there, ~25 ms of the ~150 ms between the
    /// tap and the sheet's first frame. The bar's settled bottom is kept from
    /// the last sheet, and the panel is laid out against it until this one
    /// has appeared.
    func applyPanelInsets() {
        guard let detail = panel as? PostDetailViewController else { return }
        let measured = max(view.safeAreaInsets.top, barBottom)
        let barBottom = hasAppeared ? measured : max(measured, Self.settledBarBottom ?? 0)
        let top = barBottom + SnapCommentsLayout.streamTopBreath
        let bottom = max(0, composerBottomInset + Spacing.sm - detail.composerRestingGap)
        if let applied = appliedInsets, abs(applied.top - top) < 0.5, abs(applied.bottom - bottom) < 0.5 { return }
        appliedInsets = (top, bottom)
        detail.setEngagedInsets(top: top, bottomInset: bottom)
    }

    /// The bar's bottom as the last sheet settled with it (`applyPanelInsets`).
    private static var settledBarBottom: CGFloat?
    private var hasAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        Self.settledBarBottom = max(view.safeAreaInsets.top, barBottom)
        // The learned bottom was this one's, or the panel takes the real one.
        applyPanelInsets()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismissed?() }
    }
}

/// Over the window while the keys carry the comments sheet: every touch
/// but the composer's is its own, and puts the keys away.
private final class KeyboardShield: UIView {
    weak var passThrough: UIView?
    var onTouch: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let passThrough, passThrough.window != nil,
           passThrough.convert(passThrough.bounds, to: self).contains(point) {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?()
    }
}
