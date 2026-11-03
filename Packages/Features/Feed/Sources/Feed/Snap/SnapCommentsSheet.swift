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
    /// The sheet's top as last drawn (`follow`): what a frame that cannot be
    /// read is given.
    private var lastDrawnTop: CGFloat?
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
        lastDrawnTop = drawnTop
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
        // it over as the sheet goes on rising (`followPreview`); with no
        // preview to take it, it scales out where it stands.
        let roomTop = window.safeAreaInsets.top
        let room = top - Self.mediaGap - roomTop
        let smallest = SnapCommentsPreview.size(for: cell.commentsSheetPictureSize).height
        let region = CGRect(
            x: Self.mediaSideMargin, y: roomTop,
            width: window.bounds.width - 2 * Self.mediaSideMargin,
            height: max(room, smallest)
        )
        let handoff = min(1, max(0, (smallest - room) / Self.previewHandoffSpan))
        let out: CGFloat = if CommentsV2.previewPops, !isPreviewUnavailable {
            // The trial: out over the hand-over's first half.
            Self.smoothstep(min(1, handoff / Self.popMediaOutShare))
        } else if isPreviewUnavailable {
            min(1, max(0, (smallest - room) / Self.mediaOutSpan))
        } else {
            0
        }
        // From the collapsed rest's room down to the smallest: the corners
        // turn the preview's on the way.
        let restingRoom = restingTop - Self.mediaGap - roomTop
        let towardsPreview = min(1, max(0, (restingRoom - room) / max(1, restingRoom - smallest)))
        let sheetRadius = sheetCornerRadius(below: container)
        cell.setCommentsSheetLayout(
            progress: progress, mediaRegion: region, sheetCornerRadius: sheetRadius, out: out,
            towardsPreview: towardsPreview, previewCornerRadius: SnapCommentsPreview.cornerRadius
        )
        followPreview(handoff: handoff, in: window, sheetTop: top)
        refit()
    }

    // MARK: The preview

    /// The media floating over the sheet once it has grown over it, nil
    /// while the media stands above the sheet.
    private var preview: SnapCommentsPreview?
    /// The media has nothing for a preview to draw: it scales out instead.
    private var isPreviewUnavailable = false
    /// The sheet's travel, past the media's smallest, over which the preview
    /// goes from where the media stands to its corner.
    private static let previewHandoffSpan: CGFloat = 96
    /// The room lost, past the media's smallest, over which it scales out.
    private static let mediaOutSpan: CGFloat = 64
    /// How far the preview has gone, 0 at the media, 1 in its corner.
    private var previewHandoff: CGFloat = 0
    /// The trial (`CommentsV2.previewPops`): the share of the hand-over the
    /// media scales out over, from its start, and the stretch the preview
    /// pops in over — overlapping well, so the screen is never empty
    /// (measured: a short overlap left a stretch with neither showing).
    private static let popMediaOutShare: CGFloat = 0.6
    private static let popPreviewIn: ClosedRange<CGFloat> = 0.2...0.8

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let t = min(max(0, t), 1)
        return t * t * (3 - 2 * t)
    }

    /// The trial's pop: from half its size to a little over its own, back
    /// to its own (an ease-out-back), as `t` goes 0 to 1.
    private static func popScale(_ t: CGFloat) -> CGFloat {
        let t = min(max(0, t), 1)
        let c1: CGFloat = 1.70158
        let back = 1 + (c1 + 1) * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        return 0.5 + 0.5 * back
    }

    /// ⚠️ THE SHEET DRIVES THE HAND-OVER, frame by frame (the owner,
    /// 2026-11-03). Played as an animation when the media crossed its
    /// smallest size, it bounced in and out under a finger held at the
    /// threshold, landed back on a media already bigger than itself (a jump
    /// in size), and lost the race with a sheet closed from expanded (the
    /// media popped back full screen at the end). Now the preview stands
    /// where `handoff` puts it between the media — the same size, the same
    /// corners — and its corner, as the media and the page do: under the
    /// finger, both ways, and out with the closing sheet.
    ///
    /// ⚠️ ONE PREVIEW A SHEET, hidden and shown, never made again at the
    /// threshold (measured, 2026-11-03): a new one's mirror drew a black frame
    /// before the player's next picture reached it.
    private func followPreview(handoff: CGFloat, in window: UIWindow, sheetTop: CGFloat) {
        lastSheetTop = sheetTop
        previewHandoff = handoff
        guard handoff > 0 else {
            setPreviewShown(false)
            isPreviewUnavailable = false
            return
        }
        if preview == nil {
            guard !isLeaving, !isPreviewUnavailable, let cell, let picture = cell.commentsSheetPictureFrame,
                  picture.width > 0, picture.height > 0 else { return }
            guard makePreview(size: SnapCommentsPreview.size(for: picture.size), in: window) else {
                isPreviewUnavailable = true
                return
            }
        }
        setPreviewShown(true)
        guard let preview else { return }
        if CommentsV2.previewPops {
            // The trial: in its corner from the start, popping in as the
            // media scales out, both driven by the sheet.
            let span = Self.popPreviewIn.upperBound - Self.popPreviewIn.lowerBound
            let t = min(1, max(0, (handoff - Self.popPreviewIn.lowerBound) / span))
            // Seen early in its pop: the fade done by its middle.
            preview.alpha = Self.smoothstep(min(1, t * 2))
            if !isPreviewHeld {
                let scale = Self.popScale(t)
                preview.transform = CGAffineTransform(scaleX: scale, y: scale)
                let corner = previewFrame(size: preview.bounds.size, in: window, sheetTop: sheetTop)
                preview.center = CGPoint(x: corner.midX, y: corner.midY)
            }
            return
        }
        // Left alone under a finger and while it settles in a corner.
        guard !isPreviewHeld, let center = drivenPreviewCenter(of: preview, in: window) else { return }
        preview.center = center
    }

    private static func center(of frame: CGRect) -> CGPoint? {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Where the hand-over puts the preview: on its way from the media,
    /// where it stands above the sheet, to its corner — eased at both ends.
    private func drivenPreviewCenter(of preview: SnapCommentsPreview, in window: UIWindow) -> CGPoint? {
        guard let picture = cell?.commentsSheetPictureFrame else { return nil }
        let corner = previewFrame(size: preview.bounds.size, in: window, sheetTop: lastSheetTop)
        let t = previewHandoff * previewHandoff * (3 - 2 * previewHandoff)
        return CGPoint(
            x: picture.midX + (corner.midX - picture.midX) * t,
            y: picture.midY + (corner.midY - picture.midY) * t
        )
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
            x: Self.mediaSideMargin, y: top,
            width: window.bounds.width - 2 * Self.mediaSideMargin, height: max(0, bottom - top)
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
    private func previewExpanded() {
        guard let controller = sheet.sheetPresentationController else { return }
        if content.isKeyboardUp { sheet.view.endEditing(true) }
        controller.animateChanges { controller.selectedDetentIdentifier = Self.detent }
    }

    /// The preview into its corner, on a spring carrying the throw.
    private func settlePreview(velocity: CGPoint, in window: UIWindow) {
        guard let preview else { return }
        guard let target = CommentsV2.previewPops
            ? Self.center(of: previewFrame(size: preview.bounds.size, in: window, sheetTop: lastSheetTop))
            : drivenPreviewCenter(of: preview, in: window) else { return }
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
            // The trial scales the media out instead (`out`).
            if !CommentsV2.previewPops { cell.setCommentsSheetMediaHidden(true) }
        } else {
            preview.layer.removeAllAnimations()
            isPreviewHeld = false
            preview.isHidden = true
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

    /// The composer's top, in the window: where the preview's lower corners
    /// stop.
    var composerTop: CGFloat? {
        guard let detail = panel as? PostDetailViewController, let host = detail.composeBar.superview,
              !detail.composeBar.isHidden else { return nil }
        return host.convert(detail.composeBar.frame, to: nil).minY
    }

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
