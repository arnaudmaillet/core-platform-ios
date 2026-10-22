import CoreModels
import CoreNavigation
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// What a long press on a For You row lifts: the post, bigger — the native
/// context-menu PREVIEW, the way a long press on a conversation in Messages
/// lifts the thread (`ConversationListViewController`'s `previewProvider`).
///
/// ```
///   ┌──────────────────────┐
///   │                      │   the post's picture at its own shape
///   │                      │   (held between 2:3 and 16:9), or the
///   │  Ana                 │   words on the card for a text post;
///   │  two lines of …      │   its author and caption over the foot
///   └──────────────────────┘
///   ┌──────────────────────┐
///   │ Open                 │   the menu (`PostShelfSection`)
///   │ View Profile         │
///   └──────────────────────┘
/// ```
///
/// A card's preview is its post; a friend's is the post a tap on their face
/// opens first, so the preview answers "what would I see" in both rows.
///
/// ⚠️ THE CLIP, PLAYING (the owner, 2026-10-17, #1318) — over its cover. The
/// tile under the lift is already playing this post from the shared pool, and
/// the preview JOINS that playback as one more surface
/// (`VideoPlaybackController.attachSurface(_:to:scope:)`): under the default
/// sample-buffer backing a second surface is an insertion, so the tile keeps
/// playing and simply carries on when the preview closes — the card the
/// flight takes off from if the preview is committed. A tile that was not
/// playing gets a playback of the preview's own, returned when it closes.
/// Without a pool (or for a photograph) the cover is the preview.
///
/// ⚠️ A PICTURE'S AUTHOR IS THE CARD'S BAND (#1498, the owner 2026-10-20):
/// over the media's foot, the card's own `PostAuthorBandView` at card size —
/// the 40 pt disc, the name over `@handle · date` — with the likes at its
/// trailing end, and the caption's two lines above it. It replaced the small
/// author line of the card's overlay, which said who but not when or how
/// liked. White words over a scrim and soft shadows, as on a card's media.
///
/// ⚠️ A TEXT POST'S PREVIEW IS ITS POST SCREEN, IN SMALL (#1498, the owner
/// 2026-10-20): the same author band, the caption, then its most popular
/// comments in the post screen's own rows (`CommentRowView`) — as many as
/// fit, never one cut in half; read-only, no composer. No comments: the
/// caption alone. Measured when it is made, so UIKit sizes the lift to it.
///
/// The caption is an `EmoteLabel` either way, so its emotes animate here too.
@MainActor
final class ForYouPostPreviewViewController: UIViewController {
    let post: GalleryPost
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController?
    private let imageView = UIImageView()
    /// The clip, over the cover, once its first frame is in.
    private let videoView = VideoRenderView()
    /// Whether the preview runs a playback of its OWN (the tile had none to
    /// join), which it must hand back.
    private var ownsPlayback = false
    private var playTask: Task<Void, Never>?
    /// The cover's load, on the loading ladder's rules (#1085).
    private let cover = ImageLoadSlot(size: .full)

    /// The shapes a picture previews between: a portrait clip is held at 2:3
    /// (a 9:16 frame would be taller than the space above the menu), a
    /// panorama at 16:9.
    static let aspectRange: ClosedRange<Double> = (2.0 / 3.0)...(16.0 / 9.0)

    /// The size UIKit is asked for at `width` — a hint it fits to the screen.
    static func preferredSize(for post: GalleryPost, width: CGFloat) -> CGSize {
        guard post.kind != .text else {
            // Words: a card a little wider than tall, room for the caption's
            // seven lines and the author under them.
            return CGSize(width: width, height: (width * 0.8).rounded())
        }
        let aspect = min(max(post.aspectRatio, aspectRange.lowerBound), aspectRange.upperBound)
        return CGSize(width: width, height: (width / aspect).rounded())
    }

    /// - Parameter comments: a text post's top comments, most popular first
    ///   (the post screen's first page, prefetched) — the preview shows the
    ///   top-level ones that fit. Ignored for a picture.
    init(
        post: GalleryPost, imagePipeline: ImagePipeline, width: CGFloat,
        videoPlayback: VideoPlaybackController? = nil, comments: [CommentEntry] = []
    ) {
        self.post = post
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        super.init(nibName: nil, bundle: nil)
        if post.kind == .text {
            textCard = TextCardPreview(post: post, comments: comments, width: width, imagePipeline: imagePipeline)
            preferredContentSize = textCard?.size ?? Self.preferredSize(for: post, width: width)
        } else {
            preferredContentSize = Self.preferredSize(for: post, width: width)
        }
    }

    /// A text post's preview — see the note on this type.
    private var textCard: TextCardPreview?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startClip()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cover.cancel()
        stopClip()
    }

    /// Joins the tile's playback of this post, or starts one of its own.
    private func startClip() {
        guard let videoPlayback, post.kind != .text, let url = post.videoURL else { return }
        if videoPlayback.attachSurface(videoView, to: url, scope: post.id.rawValue) { return }
        ownsPlayback = true
        let view = videoView
        let scope = post.id.rawValue
        playTask = Task { @MainActor in
            await videoPlayback.play(url, in: view, scope: scope)
        }
    }

    /// Leaves the playback as it found it: a joined surface detaches (the
    /// tile carries on), an own playback is stopped and its loan returned.
    private func stopClip() {
        playTask?.cancel()
        playTask = nil
        guard let videoPlayback else { return }
        if ownsPlayback {
            ownsPlayback = false
            videoPlayback.stop(videoView)
        } else {
            videoPlayback.detachSurface(videoView, reason: "preview closed")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ THE LIFT IS DRAWN THROUGH A PORTAL (#1564): UIKit keeps this view
        // in a container at alpha 0, so every emote in it read as unseen and
        // stayed a blank square. Its emotes are on show while it is.
        EmoteVisibility.treatAsOnShow(view)
        let isText = post.kind == .text
        view.backgroundColor = isText
            ? PostGridListRowCell.cardFillColor
            : PostGridTileCell.fillColor(for: post)
        view.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: view)
        if videoPlayback != nil, !isText, post.videoURL != nil {
            videoView.isUserInteractionEnabled = false
            videoView.pin(to: view)
        }
        if let textCard {
            textCard.install(in: view)
        } else if isText {
            let overlay = ForYouCardCaptionOverlay(post: post, placement: .onCard, imagePipeline: imagePipeline)
            overlay.pin(to: view)
        } else {
            installMediaFoot()
        }

        guard !isText, let url = post.thumbnailURL else { return }
        cover.load(url, using: imagePipeline) { [weak self] image, transition in
            guard let self else { return }
            transition.perform(on: imageView) { self.imageView.image = image }
        }
    }

    // MARK: - A picture's foot (#1498)

    /// The scrim under the words: clear at its top, dark at the foot.
    private let footScrim = PreviewFootScrimView()
    /// The caption's two lines, white, over the scrim.
    private let captionLabel = EmoteLabel()
    /// The card's author band, at card size.
    private let band = PostAuthorBandView()
    /// The likes, closing the band's line.
    private let likes = PostLikeReadoutView(ground: .media, font: ForYouPostPreviewViewController.likeFont)

    /// Between the foot's words and the preview's edges.
    static let footInset: CGFloat = 16
    /// Between the caption and the band under it.
    static let captionToBand: CGFloat = 10
    /// The likes' type: the band's handle line, a step up.
    static let likeFont = UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)

    private func installMediaFoot() {
        footScrim.isUserInteractionEnabled = false
        view.addSubview(footScrim)

        captionLabel.font = .scaledFont(forTextStyle: .footnote, weight: .medium)
        captionLabel.textColor = .white
        captionLabel.textEntityStyle = .emphasis
        captionLabel.numberOfLines = PostCardCaptionOverlay.mediaCaptionLines
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.text = post.caption
        captionLabel.isHidden = post.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        view.addSubview(captionLabel)

        // The card's band, drawn in the dark style over the picture: its
        // `.label` / `.secondaryLabel` ink reads white on the scrim.
        band.overrideUserInterfaceStyle = .dark
        band.configure(with: PostAuthorBandView.Model(post: post), imagePipeline: imagePipeline)
        band.isUserInteractionEnabled = false
        view.addSubview(band)

        likes.setCount(post.reactionCount)
        likes.isUserInteractionEnabled = false
        view.addSubview(likes)

        for ink in [captionLabel, band, likes] as [UIView] {
            ink.layer.shadowColor = UIColor.black.cgColor
            ink.layer.shadowOpacity = 0.45
            ink.layer.shadowRadius = 3
            ink.layer.shadowOffset = .zero
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard band.superview != nil else { return }
        let bounds = view.bounds
        let inset = Self.footInset
        let bandHeight = PostAuthorBandView.height(showsIdentity: true)
        let likeSize = likes.isHidden ? .zero : likes.fittedSize
        likes.frame = CGRect(
            x: bounds.maxX - inset - likeSize.width,
            y: bounds.maxY - inset - bandHeight / 2 - likeSize.height / 2,
            width: likeSize.width, height: likeSize.height
        )
        let bandTrailing = likes.isHidden ? bounds.maxX - inset : likes.frame.minX - 8
        band.frame = CGRect(x: inset, y: bounds.maxY - inset - bandHeight,
                            width: max(0, bandTrailing - inset), height: bandHeight)
        let captionWidth = max(0, bounds.width - 2 * inset)
        let captionHeight = captionLabel.isHidden ? 0
            : captionLabel.sizeThatFits(CGSize(width: captionWidth, height: .greatestFiniteMagnitude)).height
        captionLabel.frame = CGRect(
            x: inset, y: band.frame.minY - Self.captionToBand - captionHeight,
            width: captionWidth, height: captionHeight
        )
        // From a little above the words to the foot.
        let top = (captionLabel.isHidden ? band.frame.minY : captionLabel.frame.minY) - 40
        footScrim.frame = CGRect(x: 0, y: max(0, top), width: bounds.width, height: bounds.maxY - max(0, top))
    }

    #if DEBUG
    /// A text post's preview, for a test (#1498).
    var debugTextCard: TextCardPreview? { textCard }
    /// The foot's pieces, for a test (#1498).
    var debugBand: PostAuthorBandView { band }
    var debugLikes: PostLikeReadoutView { likes }
    var debugCaption: UILabel { captionLabel }
    var debugShowsCover: Bool { imageView.image != nil }
    /// The clip's surface and whether the preview owns its playback (#1318).
    var debugVideoView: VideoRenderView { videoView }
    var debugOwnsPlayback: Bool { ownsPlayback }
    #endif
}

/// The preview's foot scrim (#1498): clear at its top, 55 % black at the foot.
private final class PreviewFootScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A text post's preview (#1498): the author band, the caption, then the top
/// comments that fit — laid out by frames, measured once at `width`.
@MainActor
final class TextCardPreview {
    /// Between the words and the card's edges.
    static let inset: CGFloat = 16
    /// Between the band and the caption, and the caption and the rule.
    static let gap: CGFloat = 12
    /// The caption's lines at most: the post screen shows it whole, a lift
    /// shows enough to read.
    static let captionLines = 8
    /// The tallest the lift is, as a share of its width — room for the menu
    /// under it on any phone.
    static let maxHeightShare: CGFloat = 1.35
    /// Between two comments.
    static let rowSpacing: CGFloat = 8
    /// The caption's type: the post screen's body.
    static let captionFont = UIFont.scaledFont(forTextStyle: .body, weight: .regular)

    let band = PostAuthorBandView()
    let likes = PostLikeReadoutView(ground: .card, font: ForYouPostPreviewViewController.likeFont)
    let caption = EmoteLabel()
    let rule = UIView()
    /// The comments shown — those that fit, in order.
    private(set) var rows: [CommentRowView] = []
    /// Where each piece sits.
    private var frames: [UIView: CGRect] = [:]
    /// The card's measured size.
    private(set) var size: CGSize = .zero

    init(post: GalleryPost, comments: [CommentEntry], width: CGFloat, imagePipeline: ImagePipeline) {
        let inset = Self.inset
        let inner = max(0, width - 2 * inset)
        var y = inset

        band.configure(with: PostAuthorBandView.Model(post: post), imagePipeline: imagePipeline)
        band.isUserInteractionEnabled = false
        likes.setCount(post.reactionCount)
        let bandHeight = PostAuthorBandView.height(showsIdentity: true)
        let likeSize = likes.fittedSize
        frames[likes] = CGRect(x: width - inset - likeSize.width, y: y + (bandHeight - likeSize.height) / 2,
                               width: likeSize.width, height: likeSize.height)
        let bandTrailing = likes.isHidden ? width - inset : width - inset - likeSize.width - 8
        frames[band] = CGRect(x: inset, y: y, width: max(0, bandTrailing - inset), height: bandHeight)
        y += bandHeight + Self.gap

        caption.font = Self.captionFont
        caption.textColor = .label
        caption.textEntityStyle = .link
        caption.numberOfLines = Self.captionLines
        caption.lineBreakMode = .byTruncatingTail
        caption.text = post.caption
        let captionHeight = ceil(caption.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        frames[caption] = CGRect(x: inset, y: y, width: inner, height: captionHeight)
        y += captionHeight

        let maxHeight = (width * Self.maxHeightShare).rounded()
        let now = Date()
        let topLevel = comments.map { CommentDisplayModel(entry: $0, now: now) }.filter { !$0.isReply }
        if !topLevel.isEmpty {
            rule.backgroundColor = .separator
            let ruleY = y + Self.gap
            var rowY = ruleY + 1 + Self.gap / 2
            for model in topLevel {
                let row = CommentRowView(installsContextMenu: false)
                row.configure(with: model, imagePipeline: imagePipeline)
                row.isUserInteractionEnabled = false
                let height = ceil(row.systemLayoutSizeFitting(
                    CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
                ).height)
                // Never one cut in half: a row that does not fit ends the list.
                guard rowY + height + inset <= maxHeight else { break }
                frames[row] = CGRect(x: inset, y: rowY, width: inner, height: height)
                rows.append(row)
                rowY += height + Self.rowSpacing
            }
            if !rows.isEmpty {
                frames[rule] = CGRect(x: inset, y: ruleY, width: inner, height: 0.5)
                y = rowY - Self.rowSpacing
            }
        }
        size = CGSize(width: width, height: min(maxHeight, ceil(y + inset)))
    }

    /// Puts every piece in `view`, at its measured frame.
    func install(in view: UIView) {
        for piece in [band, likes, caption] as [UIView] + (rows.isEmpty ? [] : [rule]) + rows {
            piece.translatesAutoresizingMaskIntoConstraints = true
            piece.frame = frames[piece] ?? .zero
            view.addSubview(piece)
        }
    }
}

/// A committed lift, captured AS UIKit COMMITS IT (#1543): where the flight
/// that opens its post takes off.
///
/// ⚠️ CAPTURED, NEVER LOOKED UP LATER. Measured 2026-10-22 on iOS 27: a `.pop`
/// commit runs the animator's completion BEFORE the run loop's next turn, the
/// one the post opens on. A lift looked up when the flight asked for its
/// origin was already gone, and the flight left from the tile.
///
/// ⚠️ AND NEVER THE PREVIEW CONTROLLER'S OWN VIEW. UIKit keeps it in a
/// container at alpha 0, at (0, 0) on one lift and (-402, 0) on the next, and
/// draws it through a portal in the context menu's platter, which a later
/// sibling of that container holds — at (16, 78) for the same lift. The
/// platter is the first view of the lift's own size in the containers added
/// after the lift's; nothing private is named.
///
/// ⚠️ AND IT STAYS ON SCREEN UNTIL THE CARD IS. Opening the feed costs about
/// 250 ms before the flight's first frame (`-zoom-profile`: the screen's
/// build, then ~80 ms before the first commit), and UIKit's fade of the lift
/// is over in ~115 ms: filmed at 60 fps, three frames showed neither. A tap
/// on a tile hides that cost behind the tile; here a still of the lift holds
/// its place over everything until the flight conceals its source — once
/// the card is drawing (`ZoomAnimator`'s first-frame handoff) — or the
/// capture expires.
@MainActor
final class PreviewLaunch {
    /// How long the capture answers: the flight's departure asks within a
    /// frame or two of the commit; a close, much later, must land on the tile.
    static let lifetime: CFTimeInterval = 1
    /// The lift's rounding, on a continuous curve: UIKit draws it, and names
    /// it nowhere. Measured 2026-10-22 on iOS 27 (a text card's lift at 3x):
    /// the edge goes straight ~33 pt from the corner, 1.53 × 22.
    static let cornerRadius: CGFloat = 22

    /// The last lift committed, for a surface that opens the post without
    /// being handed it — a window opening out of it (`TextRevealInstaller`).
    private static weak var latest: PreviewLaunch?

    /// The lift `postID` was committed from, while its capture answers.
    static func pending(for postID: PostID, now: CFTimeInterval = CACurrentMediaTime()) -> PreviewLaunch? {
        guard let latest, latest.postID == postID, now < latest.expiry else { return nil }
        return latest
    }

    let postID: PostID
    /// Whether the post is words, which a window shows in place.
    private let isText: Bool
    private let frameInWindow: CGRect
    private weak var window: UIWindow?
    private weak var lift: UIView?
    private weak var drawing: UIView?
    /// The still holding the lift's place — see the note on this type.
    private var hold: UIView?
    private let expiry: CFTimeInterval

    /// Nil when the lift is not on screen, or UIKit's drawing of it cannot be
    /// found — the tile is then the honest origin.
    init?(_ preview: ForYouPostPreviewViewController, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let lift = preview.viewIfLoaded, let window = lift.window,
              let drawing = Self.drawing(of: lift, in: window) else { return nil }
        postID = preview.post.id
        isText = preview.post.kind == .text
        frameInWindow = drawing.convert(drawing.bounds, to: window)
        self.window = window
        self.lift = lift
        self.drawing = drawing
        expiry = now + Self.lifetime
        // The lift's own view: the platter's portal snapshots blank.
        if let still = lift.snapshotView(afterScreenUpdates: true) {
            still.frame = frameInWindow
            still.isUserInteractionEnabled = false
            window.addSubview(still)
            hold = still
            // A post that never opens must not leave the still behind — one
            // a window opened from (`takeStill`) is its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak still, weak window] in
                if let still, still.superview === window { still.removeFromSuperview() }
            }
        }
        Self.latest = self
    }

    /// Where the lift was, in `space` — nil once the capture has expired.
    func frame(in space: UICoordinateSpace, now: CFTimeInterval = CACurrentMediaTime()) -> CGRect? {
        guard now < expiry, let window else { return nil }
        return window.convert(frameInWindow, to: space)
    }

    /// Where the menu's dismissal takes the lift: where it already is, so it
    /// fades out IN PLACE under the flight leaving from it.
    ///
    /// ⚠️ Measured 2026-10-22 (iOS 27, 30 fps film): with the tile as the
    /// target — and with `.pop`, which follows the same target — UIKit carried
    /// the lift back into its card, and the card stood there for four frames
    /// before the flight jumped up to the lift's place. A collection view's
    /// nil target means the cell, so the target is a clear view of the lift's
    /// size, centred on it.
    func dismissalTarget(now: CFTimeInterval = CACurrentMediaTime()) -> UITargetedPreview? {
        guard now < expiry, let window else { return nil }
        let blank = UIView(frame: CGRect(origin: .zero, size: frameInWindow.size))
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(
            view: blank, parameters: parameters,
            target: UIPreviewTarget(container: window, center: CGPoint(x: frameInWindow.midX, y: frameInWindow.midY))
        )
    }

    /// The window a post opens through, leaving from this lift: its frame,
    /// its corner, and its still as what the window starts as — handed over,
    /// so it goes on holding the lift's place inside the opening.
    func revealLaunch(now: CFTimeInterval = CACurrentMediaTime()) -> RevealLaunch? {
        guard now < expiry, window != nil else { return nil }
        return RevealLaunch(
            frame: { [weak self] space in self?.frame(in: space) },
            cornerRadius: Self.cornerRadius,
            pageFit: isText ? .clipped : .covering,
            makeStandIn: { [weak self] in self?.takeStill() }
        )
    }

    /// The still, taken out of the window for the window opening from it.
    private func takeStill() -> UIView? {
        guard let hold, let window else { return nil }
        self.hold = nil
        // The page's own ground (`SnapFeedViewController.resolvedGround`).
        let ground: UIColor = isText ? .systemBackground : .black
        return LiftStandInView(still: hold, at: frameInWindow, in: window, ground: ground)
    }

    /// Hides the lift wherever it is drawn: the card flying out of it is the
    /// lift now, and UIKit's own fade of it must not draw over the card.
    func conceal() {
        lift?.alpha = 0
        drawing?.alpha = 0
        hold?.removeFromSuperview()
        hold = nil
    }

    #if DEBUG
    /// Whether the still is holding the lift's place.
    var debugIsHolding: Bool { hold?.window != nil }
    #endif

    /// The view UIKit draws `lift` in.
    private static func drawing(of lift: UIView, in window: UIWindow) -> UIView? {
        let size = lift.bounds.size
        guard size.width > 0, size.height > 0,
              let held = window.subviews.firstIndex(where: { lift.isDescendant(of: $0) })
        else { return nil }
        // Breadth first: the platter, not a same-sized piece inside it.
        var queue = Array(window.subviews[(held + 1)...])
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if !view.isHidden, view.alpha > 0.01,
               abs(view.bounds.width - size.width) < 0.5, abs(view.bounds.height - size.height) < 0.5 {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// The lift's still as a window's stand-in (#1543): it stays WHERE THE LIFT
/// WAS while the window grows around it on the page's ground, clipped to
/// the window's corner, and the page fades in over it.
///
/// ⚠️ On the page's ground, not clear: a clear window showed the list
/// through it for ~0.4 s, the lift sitting still on top, until the page's
/// fade-in — nothing seemed to open (filmed 2026-10-22).
///
/// ⚠️ Never the still itself: a reveal sets its stand-in's frame to the
/// window's, and a snapshot stretches to its frame — the lift's words
/// swelled with the window (filmed 2026-10-22).
@MainActor
final class LiftStandInView: UIView, RevealStandInShaping {
    private let still: UIView
    private let stillFrame: CGRect
    private weak var space: UIWindow?

    init(still: UIView, at frame: CGRect, in window: UIWindow, ground: UIColor) {
        self.still = still
        stillFrame = frame
        space = window
        super.init(frame: frame)
        backgroundColor = ground
        clipsToBounds = true
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        still.removeFromSuperview()
        addSubview(still)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // In the window's space, where the lift was; this view's own origin
        // when it is not in one yet.
        guard let space, window != nil else {
            still.frame = CGRect(origin: .zero, size: stillFrame.size)
            return
        }
        still.frame = convert(stillFrame, from: space)
    }

    func setCornerRadius(_ radius: CGFloat) { layer.cornerRadius = radius }

    func setContentOpacity(_ alpha: CGFloat) { still.alpha = alpha }
}
