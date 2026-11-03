import CoreModels
import CoreNavigation
import DesignSystem
import UIKit

/// A media post's comments as a NATIVE SHEET (#2087, behind `CommentsV2`) —
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
/// Two heights (the owner, 2026-11-03): collapsed, the content's own, at most
/// what the media leaves it (`restingHeight`) — a short thread takes a short
/// sheet, with no room above its first row — and, for comments that outgrow
/// it, expanded to the top of the screen, the media shrinking on in the room
/// left (a floating preview takes it from there, #2087's next steps). The
/// sheet is undimmed, so the media above it stays lit; a tap there closes
/// it, as a swipe down does.
@MainActor
final class SnapCommentsSheetSession: NSObject, UIAdaptivePresentationControllerDelegate {
    /// The sheet's tallest resting height, as shares of the screen: never
    /// under the floor, which keeps the rows readable — lower for a square
    /// to landscape media, whose whole width comes first — never over the
    /// ceiling (`restingHeight`).
    static let floorShare: CGFloat = 0.6
    static let wideFloorShare: CGFloat = 0.5
    static let ceilingShare: CGFloat = 0.75
    static let detent = UISheetPresentationController.Detent.Identifier("feed.comments.v2")
    /// The sheet up to the top of the screen — offered only while the
    /// comments outgrow `detent` (the owner, 2026-11-03), the media shrinking
    /// on in the room left above it.
    static let expandedDetent = UISheetPresentationController.Detent.Identifier("feed.comments.v2.expanded")
    /// Between the shrunk media's bottom and the sheet's top.
    static let mediaGap: CGFloat = Spacing.sm
    /// Between the shrunk media and the screen's sides: it never touches
    /// them (the owner, 2026-11-03).
    static let mediaSideMargin: CGFloat = Spacing.sm

    /// The sheet's tallest resting height, the media's to decide (the owner,
    /// 2026-11-03): the media keeps the screen's whole width, less its side
    /// margins, in the room above, and the sheet takes what is left, between
    /// a floor and `ceilingShare` of the screen. A square to landscape media
    /// comes first, down to `wideFloorShare` (the owner, 2026-11-03): a 4:3
    /// one keeps its whole width over a ~55 % sheet, a square one shrinks a
    /// little over a 50 % one. A portrait one, which the width would leave
    /// the sheet no room, gets `floorShare`. Read once, at the opening: a
    /// carousel paged under the sheet does not move it.
    ///
    /// The height of a custom detent, so it leaves out the bottom safe area
    /// the sheet stands on.
    ///
    /// - Parameter picture: what the sheet shrinks, as the page draws it
    ///   (`SnapFeedCell.commentsSheetPictureSize`).
    static func restingHeight(screen: CGSize, safeArea: UIEdgeInsets, picture: CGSize) -> CGFloat {
        let ceiling = screen.height * ceilingShare
        guard picture.width > 0, picture.height > 0 else { return screen.height * floorShare }
        let floor = screen.height * (picture.width >= picture.height ? wideFloorShare : floorShare)
        let mediaHeight = (screen.width - 2 * mediaSideMargin) * picture.height / picture.width
        let left = screen.height - safeArea.top - mediaHeight - mediaGap - safeArea.bottom
        return min(max(left, floor), ceiling)
    }

    let postID: PostID
    /// What is presented: the content itself, carrying its own bar — or, as
    /// first built (`CommentsV2.sheetUsesNavigationStack`), in a stack of its
    /// own for the stack's bar.
    let sheet: UIViewController
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
    /// The detent last resolved at the media's cap, not at its content's
    /// height, and where the sheet's top should then rest, in the window
    /// (`correctCap`).
    private var restsAtCap = false
    private var capTop: CGFloat?
    /// The collapsed detent's tallest height (`restingHeight`), and the
    /// bottom safe area the sheet stands on: whether the comments outgrow it
    /// (`isExpandable`).
    private var restingHeight: CGFloat = 0
    private var bottomInset: CGFloat = 0
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
        let stacked = CommentsV2.sheetUsesNavigationStack
        content = SnapCommentsSheetViewController(
            panel: panel, walletBadge: walletBadge, onWalletTap: onWalletTap, ownsBar: !stacked
        )
        sheet = stacked ? UINavigationController(rootViewController: content) : content
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
        // Dark, the sheet's own material included: the panel is drawn for the
        // dark page it lived on, and a sheet the keyboard grows otherwise
        // turns to a light glass under its white text.
        sheet.overrideUserInterfaceStyle = .dark
        sheet.presentationController?.traitOverrides.userInterfaceStyle = .dark
        restingHeight = resting
        self.bottomInset = bottomInset
        if let controller = sheet.sheetPresentationController {
            collapsedDetent = .custom(identifier: Self.detent) { [weak self, weak content] context in
                MainActor.assumeIsolated {
                    let cap = min(context.maximumDetentValue, resting + Self.capCorrection)
                    let height = content?.fittedHeight.map { min(cap, $0 - bottomInset) } ?? cap
                    self?.restsAtCap = height == cap && cap < context.maximumDetentValue
                    return height
                }
            }
            controller.largestUndimmedDetentIdentifier = Self.expandedDetent
            controller.prefersGrabberVisible = true
            // A scroll at the top of the rows grows the sheet first, as a
            // drag on its bar does — with nothing to grow to, it scrolls.
            controller.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        capTop = window.bounds.height - resting - bottomInset
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
        // Laid out at the sheet's width before it is presented, so the first
        // height it resolves is already its content's.
        sheet.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: resting + bottomInset)
        content.composerBottomInset = bottomInset
        sheet.view.layoutIfNeeded()
        content.applyPanelInsets()
        content.view.layoutIfNeeded()
        fittedHeight = content.fittedHeight
        // The detents once the content's height is known: the expanded one
        // only for comments that outgrow the collapsed one.
        sheet.sheetPresentationController?.detents = detents(expandable: isExpandable)

        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        feed.present(sheet, animated: animated)
        follow()
    }

    /// A tap on the media above the sheet: with the keyboard up, it puts the
    /// keyboard away and nothing else (the owner, 2026-11-03); otherwise it
    /// closes the sheet.
    @objc private func mediaTapped() {
        if content.isKeyboardUp {
            sheet.view.endEditing(true)
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
        guard !isKeyboardHiding, let keyboardRestTop,
              let container = sheet.presentationController?.containerView else { return }
        catcher.layoutIfNeeded()
        let keyboardTop = keyboardTracker.convert(CGPoint.zero, to: nil).y
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
        followKeyboardDrag()
        guard let cell, let window = cell.window,
              let container = sheet.presentationController?.containerView,
              let presented = sheet.presentationController?.presentedView else { return }
        let height = window.bounds.height
        // Where the sheet IS on screen, mid-animation or under a finger: its
        // presentation layer, carried up the presentation tree to the window.
        let drawnTop: CGFloat
        if let layer = presented.layer.presentation() {
            drawnTop = layer.convert(layer.bounds, to: nil).minY
        } else {
            drawnTop = container.convert(presented.frame, to: nil).minY
        }
        // …against where it RESTS. The model frame is the end of whatever is
        // animating — the rest on the way in and on a refit — but once the
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
        if !isLeaving, !content.isKeyboardUp {
            let modelTop = container.convert(presented.frame, to: nil).minY
            if sheet.isBeingPresented { correctCap(restingAt: modelTop) }
            restingTop = max(modelTop, capTop ?? modelTop)
        }
        guard let restingTop else { return }
        let top = drawnTop
        let progress = (height - top) / max(1, height - restingTop)
        // The room above the sheet, a breath short of its top and of the
        // screen's sides: the media never touches them.
        //
        // ⚠️ NEVER SMALLER THAN ITS PREVIEW (the owner, 2026-11-03): shrunk
        // on with the sheet, the media became a speck its corners turned to
        // a lozenge. It stops at the preview's size, where the preview takes
        // it (`followPreview`); past that room, with no preview to take it,
        // it scales out where it stands.
        let roomTop = window.safeAreaInsets.top
        let room = top - Self.mediaGap - roomTop
        let smallest = SnapCommentsPreview.size(for: cell.commentsSheetPictureSize).height
        let region = CGRect(
            x: Self.mediaSideMargin, y: roomTop,
            width: window.bounds.width - 2 * Self.mediaSideMargin,
            height: max(room, smallest)
        )
        let out = preview == nil ? min(1, max(0, (smallest - room) / Self.mediaOutSpan)) : 0
        let sheetRadius = sheetCornerRadius(below: container)
        cell.setCommentsSheetLayout(progress: progress, mediaRegion: region, sheetCornerRadius: sheetRadius, out: out)
        followPreview(in: window, sheetTop: top)
        refit()
    }

    // MARK: The preview

    /// The media floating over the sheet once it has grown over it, nil
    /// while the media stands above the sheet.
    private var preview: SnapCommentsPreview?
    /// The preview is flying back into the media: it is let finish.
    private var isPreviewReturning = false
    /// How much bigger than the preview the media must grow back before the
    /// preview flies into it: a sheet held at the threshold does not bounce
    /// the media in and out.
    private static let previewHysteresis: CGFloat = Spacing.lg
    /// The room lost, past the media's smallest, over which it scales out.
    private static let mediaOutSpan: CGFloat = 64

    /// ⚠️ THE MEDIA FLIES INTO ITS PREVIEW once it has shrunk to the
    /// preview's size above the rising sheet (the owner, 2026-11-03) — not
    /// at the expanded rest, where it would be a speck first — and back out
    /// once it has room to stand bigger than the preview again.
    private func followPreview(in window: UIWindow, sheetTop: CGFloat) {
        guard let cell, let picture = cell.commentsSheetPictureFrame, picture.width > 0, picture.height > 0 else {
            return
        }
        let size = SnapCommentsPreview.size(for: picture.size)
        // Its centre, never its frame: the flight in is a transform on it.
        if let preview, !isPreviewReturning {
            let frame = previewFrame(size: preview.bounds.size, in: window, sheetTop: sheetTop)
            preview.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        if preview == nil {
            // A point's slack: the preview's size is rounded.
            guard !isLeaving, picture.width <= size.width + 1, picture.height <= size.height + 1 else { return }
            showPreview(size: size, from: picture, in: window, sheetTop: sheetTop)
        } else if !isPreviewReturning,
                  picture.width > size.width + Self.previewHysteresis
                    || picture.height > size.height + Self.previewHysteresis {
            hidePreview(into: picture)
        }
    }

    /// Where the preview stands: the screen's top right, under the sheet's
    /// bar — riding with the sheet as it rises, never over its ✕ and balance
    /// — the media's margin from the side. Expanded, the screen's top.
    private func previewFrame(size: CGSize, in window: UIWindow, sheetTop: CGFloat) -> CGRect {
        let top = max(window.safeAreaInsets.top, sheetTop) + content.barBottom + Spacing.sm
        return CGRect(
            x: window.bounds.width - Self.mediaSideMargin - size.width, y: top,
            width: size.width, height: size.height
        )
    }

    private func showPreview(size: CGSize, from picture: CGRect, in window: UIWindow, sheetTop: CGFloat) {
        guard let cell, let media = cell.makeCommentsPreviewContent() else { return }
        let preview = SnapCommentsPreview(content: media)
        let frame = previewFrame(size: size, in: window, sheetTop: sheetTop)
        preview.frame = frame
        window.addSubview(preview)
        self.preview = preview
        cell.setCommentsSheetMediaHidden(true)
        // From the shrunk media, exactly where it stood, into the corner —
        // landing with a little bounce.
        preview.transform = SnapCommentsPreview.transform(from: frame, onto: picture)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0) {
            preview.transform = .identity
        }
    }

    /// The preview back into the media, then gone, and the media shown.
    private func hidePreview(into picture: CGRect) {
        guard let preview else { return }
        isPreviewReturning = true
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
            preview.transform = SnapCommentsPreview.transform(from: preview.frame, onto: picture)
        } completion: { [weak self] _ in
            self?.removePreview()
        }
    }

    /// The preview gone at once: the media back in place, its mirror let go.
    private func removePreview() {
        isPreviewReturning = false
        guard let preview else { return }
        self.preview = nil
        cell?.releaseCommentsPreviewContent(preview.content)
        cell?.setCommentsSheetMediaHidden(false)
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

    /// The detent again when the content's height has moved — rows landing,
    /// a thread's replies opening, the other tab — never on the way out; and
    /// the expanded detent offered, or taken back, as the comments outgrow
    /// the collapsed one or no longer do.
    private func refit() {
        guard !isLeaving, let controller = sheet.sheetPresentationController else { return }
        let fitted = content.fittedHeight
        if let fitted, let last = fittedHeight, abs(fitted - last) < 1 { return }
        guard fitted != fittedHeight else { return }
        fittedHeight = fitted
        let expandable = isExpandable
        controller.animateChanges {
            if expandable != controller.detents.contains(where: { $0.identifier == Self.expandedDetent }) {
                controller.detents = detents(expandable: expandable)
            }
            controller.invalidateDetents()
        }
    }

    /// The collapsed detent (`present`), kept to rebuild the list with.
    private var collapsedDetent: UISheetPresentationController.Detent?

    /// Whether the comments stand taller than the collapsed detent: the
    /// expanded one has something to show.
    private var isExpandable: Bool {
        guard let fitted = content.fittedHeight else { return false }
        return fitted - bottomInset > restingHeight + Self.capCorrection + 1
    }

    /// The sheet's detents: the collapsed one, and the expanded one when the
    /// comments outgrow it.
    private func detents(expandable: Bool) -> [UISheetPresentationController.Detent] {
        guard let collapsedDetent else { return [] }
        guard expandable else { return [collapsedDetent] }
        return [collapsedDetent, .custom(identifier: Self.expandedDetent) { $0.maximumDetentValue }]
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        link?.invalidate()
        link = nil
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
        DispatchQueue.main.async { [weak self] in self?.sheet.view.endEditing(true) }
        return false
    }

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
///
/// ⚠️ A LONE BAR, NOT A NAVIGATION STACK (profiled, 2026-11-03). Nothing is
/// pushed in the sheet: the stack was there for its bar alone, and moving it
/// into the window — its bars' set-up and position, the insets it hands down
/// — weighed on every opening. The bar is a `UINavigationBar` this screen
/// holds, showing its own `navigationItem`: the same native items, and a
/// height known before the sheet is presented. The stacked build stays
/// behind `CommentsV2.sheetUsesNavigationStack`.
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

    /// The sheet's own bar; nil in a navigation stack, whose bar it uses.
    private let ownBar: UINavigationBar?

    init(panel: UIViewController, walletBadge: WalletBadgeButton?, onWalletTap: (() -> Void)?, ownsBar: Bool) {
        self.panel = panel
        self.walletBadge = walletBadge
        ownBar = ownsBar ? UINavigationBar() : nil
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
        if let ownBar { installOwnBar(ownBar) }
        NSLayoutConstraint.activate([
            topPocket.topAnchor.constraint(equalTo: view.topAnchor),
            topPocket.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topPocket.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topPocket.bottomAnchor.constraint(equalTo: ownBar?.bottomAnchor ?? view.safeAreaLayoutGuide.topAnchor),
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

    /// The bar's bottom in this view: the lone bar's, or the stack's.
    var barBottom: CGFloat {
        if let ownBar { return ownBar.frame.maxY }
        return navigationController.map { view.convert($0.navigationBar.frame, from: $0.view).maxY } ?? 0
    }

    /// The bar and the top pocket on the list shown.
    private func follow(_ list: UIScrollView) {
        setContentScrollView(list, for: .top)
        topPocketInteraction.scrollView = list
    }

    /// The panel's height for what it shows (`PostDetailViewController.fittedHeight`).
    var fittedHeight: CGFloat? { (panel as? PostDetailViewController)?.fittedHeight }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isKeyboardUp { restingHeight = view.bounds.height }
    }

    /// A keyboard coming up or changing: the panel's height for it. One going
    /// away (its frame off the screen) is `keyboardWillHide`'s.
    private func keyboardWillMove(to frame: CGRect?) {
        guard let frame, let window = view.window, frame.minY < window.screen.bounds.maxY else { return }
        setKeyboardUp(true)
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
    private func panelHeightOverKeyboard(at keyboardTop: CGFloat, in window: UIWindow) -> CGFloat {
        let lowered = restingHeight + composerBottomInset - Spacing.sm
        let heldAtTop = keyboardTop + composerBottomInset - window.safeAreaInsets.top
        return max(0, min(lowered, heldAtTop))
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
        guard up != isKeyboardUp, let panelBottom, let panelHeight, restingHeight > 0 else { return }
        isKeyboardUp = up
        // Nothing of the streams under the composer while it stands on the keys.
        (panel as? PostDetailViewController)?.setStreamsClippedAtComposer(up)
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
        if (navigationController ?? self).isBeingDismissed { onDismissed?() }
    }
}
