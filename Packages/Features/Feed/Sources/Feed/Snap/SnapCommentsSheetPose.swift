import CoreNavigation
import DesignSystem
import MediaPlayback
import PostGrid
import ThreadKit
import UIKit

/// What the comments sheet's pose asks of the page (#2521): its media card,
/// its chrome and the stage they stand on, the action column's stage, and
/// the clip it plays, for the sheet's preview.
@MainActor
protocol SnapCommentsSheetPoseHost: UIView {
    var mediaCard: SnapMediaCardView { get }
    var chrome: SnapChromeView { get }
    var pageStage: UIView { get }
    var columnStage: SnapActionColumnLayer { get }
    var audibleSurface: VideoRenderView? { get }
    var videoPlayback: VideoPlaybackController? { get }
}

/// The page under the comments sheet (#2087), out of `SnapFeedCell` (#2521):
/// the media shrinking into the room above the sheet as its sheet cut, the
/// window and bands round it, the picture's edge, the interface fading, and
/// the media the sheet's preview draws. Driven every frame by the sheet
/// (`SnapCommentsSheet`, `CommentsSheetLanding`).
@MainActor
final class SnapCommentsSheetPose {
    private unowned let host: any SnapCommentsSheetPoseHost

    init(host: any SnapCommentsSheetPoseHost) {
        self.host = host
    }

    /// The pool the page plays through (`if let videoPlayback` binds it below).
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }

    /// The sheet's window onto the media: the picture's own, rounded, and its
    /// bands' — above, below and beside it, never over it, so the picture's
    /// corners are the only ones drawn there (`setCommentsSheetLayout`).
    private var commentsSheetMask: UIView?
    private let commentsSheetPictureWindow = UIView()
    private let commentsSheetTopBand = UIView()
    private let commentsSheetBottomBand = UIView()
    private let commentsSheetLeftBand = UIView()
    private let commentsSheetRightBand = UIView()

    /// What the comments sheet shrinks: the picture's sheet cut
    /// (`commentsSheetCut`) — and so the preview's shape.
    var commentsSheetPictureSize: CGSize {
        CommentsSheetShape.commentsSheetCut(of: host.mediaCard.wholePictureRect).size
    }

    /// The page under the comments sheet, at `progress` of the way from rest
    /// (0) to the sheet up (1): the page's interface fades out, and the media
    /// shrinks into `mediaRegion` (the window's coordinates) — the room above
    /// the sheet — centred, as its sheet cut (`commentsSheetCut`): from what
    /// the page shows to that cut as the sheet rises, a tall picture's whole
    /// width opening as its top and bottom close. Driven every frame by the
    /// sheet's own position, so it follows the finger on the way down.
    ///
    /// ⚠️ A TRANSFORM ON THE CARD, and nothing else moves: the card keeps its
    /// playback, and `clearCommentsSheetLayout` is identity again. Its frame
    /// moves once: a picture the card crops to its shape spreads it to the
    /// picture's own, past the screen's sides, in the first frame
    /// (`spreadCommentsSheetCard`) — the same pixels on the screen.
    ///
    /// THE PICTURE WEARS THE CORNERS, never the window round its bands (the
    /// owner, 2026-11-03): from the screen's own where it fills the screen —
    /// square where it does not reach the screen's corners — to a media
    /// tile's once shrunk, or the sheet's own `sheetCornerRadius` for a
    /// landscape picture. The bands fade out round it, and a light grey line
    /// fades in round the picture (`drawCommentsSheetEdge`).
    ///
    /// `out` (0…1) scales the media out where it stands, smaller and fading:
    /// the sheet has grown past the room its smallest size needs.
    /// `towardsPreview` (0…1) is how far the media has shrunk from its
    /// collapsed size to its smallest — its preview's size: its corners go
    /// the same way, to `previewCornerRadius`, so the preview takes it over
    /// as it stands (the owner, 2026-11-03).
    ///
    /// `interface` (0…1) is how far the page's interface has gone — the
    /// progress when nil; on the way back it waits for the media (#2287).
    func setCommentsSheetLayout(
        progress: CGFloat, mediaRegion: CGRect, sheetCornerRadius: CGFloat, out: CGFloat = 0,
        towardsPreview: CGFloat = 0, previewCornerRadius: CGFloat = 0, interface: CGFloat? = nil
    ) {
        let t = min(max(0, progress), 1)
        let hidden = min(max(0, interface ?? t), 1)
        // The interface, and the action column riding above it (#695).
        host.chrome.alpha = 1 - hidden
        host.columnStage.alpha = 1 - hidden
        // …which glides down to the composer's line on the same share, and
        // back up as the interface comes back (#2326): the sheet's own
        // movement is the clock, a drag that cancels included.
        host.chrome.actionColumn.setCommentsSheetShare(hidden)
        guard let stage = host.mediaCard.superview else { return }
        let mediaRegion = stage.convert(mediaRegion, from: nil)
        guard mediaRegion.width > 0, mediaRegion.height > 0 else { return }
        // Every frame, and cheap when nothing changed: the picture's framing
        // may change under the sheet (a clip's first frame telling its real
        // shape), and the spread with it.
        spreadCommentsSheetCard()
        let bounds = host.mediaCard.bounds
        // The page as it stands, in the card's bounds — the card less its
        // spread — and the picture it shows there.
        let page = bounds.insetBy(dx: commentsSheetSpread.width, dy: commentsSheetSpread.height)
        // Within the card: a card that could not spread keeps its picture to
        // what it draws.
        let whole = host.mediaCard.wholePictureRect(in: page).intersection(bounds)
        let picture = whole.intersection(page)
        guard picture.width > 0, picture.height > 0, !picture.isNull else { return }
        let landscape = whole.width > whole.height
        // What lands in the region: the picture's sheet cut.
        let shown = CommentsSheetShape.commentsSheetCut(of: whole)
        // The scale that fits it in the region, and the move that centres it
        // there — about the card's centre, its transform's anchor.
        //
        // ⚠️ A FULL-WIDTH SHAPE'S CUT MAY GROW (#2184): its whole width comes
        // first, and a cut standing narrower on the page than the screen —
        // capped at 1, it never reached the full width the sheet's height was
        // reckoned from (measured on the simulator: 325 of 386 pt). A shape
        // that shrinks into the room never grows past the page.
        let shrinksIntoRoom = CommentsSheetShape.of(shown.size)?.layout == .shrinksIntoRoom
        let growCap: CGFloat = shrinksIntoRoom ? 1 : .greatestFiniteMagnitude
        let fit = min(mediaRegion.width / shown.width, mediaRegion.height / shown.height, growCap)
        let scale = 1 + (fit - 1) * t
        let cardCenter = host.mediaCard.center
        let offset = CGPoint(x: shown.midX - bounds.midX, y: shown.midY - bounds.midY)
        let landed = CGPoint(x: cardCenter.x + offset.x * fit, y: cardCenter.y + offset.y * fit)
        let move = CGPoint(x: (mediaRegion.midX - landed.x) * t, y: (mediaRegion.midY - landed.y) * t)
        // Scaled out where it stands, about the picture's own centre — the
        // region's. ⚠️ A view's transform is about its centre: the pivot is
        // the region's centre as seen from the card's (measured, 2026-11-03:
        // taken in the stage's coordinates, it was far off at the bottom
        // right, and the media slid there as it shrank).
        let out = min(max(0, out), 1)
        let shrink = 1 - Self.commentsSheetOutShrink * out
        let pivot = CGPoint(x: mediaRegion.midX - cardCenter.x, y: mediaRegion.midY - cardCenter.y)
        host.mediaCard.transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: move.x, y: move.y))
            .concatenating(CGAffineTransform(translationX: -pivot.x, y: -pivot.y))
            .concatenating(CGAffineTransform(scaleX: shrink, y: shrink))
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        commentsSheetMediaOut = out
        applyCommentsSheetMediaAlpha()

        let mask = commentsSheetMask ?? {
            let mask = UIView()
            for window in [
                commentsSheetPictureWindow, commentsSheetTopBand, commentsSheetBottomBand,
                commentsSheetLeftBand, commentsSheetRightBand,
            ] {
                window.backgroundColor = .black
                window.layer.cornerCurve = .continuous
                mask.addSubview(window)
            }
            host.mediaCard.mask = mask
            commentsSheetMask = mask
            return mask
        }()
        mask.frame = bounds
        // The radii are drawn on the mask, which the card's scale shrinks
        // with it: divided by it.
        let unscale = 1 / max(scale, 0.01)
        let screenRadius = ScreenGeometry.cornerRadius(behind: host)
        let fills = picture.width >= page.width - 0.5 && picture.height >= page.height - 0.5
        let from = fills ? screenRadius : 0
        let to = landscape ? sheetCornerRadius : ChaoticSliceLayout.harmonisedCornerRadius
        // In the mask's coordinates: the picture as the page shows it, going
        // to its cut as the sheet rises.
        let local = { (rect: CGRect) in rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        let cut = local(shown)
        let window = Self.interpolate(local(picture), cut, t)
        // ⚠️ NEVER MORE THAN HALF ITS SHORTER SIDE (the owner, 2026-11-03):
        // a picture shrunk under its radius twice over read as a lozenge. A
        // pill at the very least.
        let shownSide = min(window.width, window.height) * scale * shrink
        let k = min(max(0, towardsPreview), 1)
        let settled = to + (previewCornerRadius - to) * k
        let radius = min(from + (settled - from) * t, shownSide / 2)
        commentsSheetPictureWindow.frame = window
        commentsSheetPictureFrame = host.mediaCard.convert(window.offsetBy(dx: bounds.minX, dy: bounds.minY), to: nil)
        commentsSheetWholePictureFrame = host.mediaCard.convert(whole, to: nil)
        commentsSheetPictureRadius = radius
        let unshrink = 1 / max(shrink, 0.01)
        commentsSheetPictureWindow.layer.cornerRadius = radius * unscale * unshrink
        drawCommentsSheetEdge(
            around: host.mediaCard.convert(window.offsetBy(dx: bounds.minX, dy: bounds.minY), to: stage),
            cornerRadius: radius, progress: t, in: stage
        )

        // ⚠️ THE BANDS STOP AT THE PICTURE (the owner, 2026-11-03): one
        // window round both, fading, let the picture's square corners show
        // through its rounding until it had gone. They are the window that
        // shrinks from the page onto the cut, less the picture's, fading.
        let bands = Self.interpolate(local(page), cut, t)
        let top = CGRect(x: bands.minX, y: bands.minY, width: bands.width, height: max(0, window.minY - bands.minY))
        let bottom = CGRect(
            x: bands.minX, y: window.maxY, width: bands.width, height: max(0, bands.maxY - window.maxY)
        )
        let left = CGRect(x: bands.minX, y: window.minY, width: max(0, window.minX - bands.minX), height: window.height)
        let right = CGRect(
            x: window.maxX, y: window.minY, width: max(0, bands.maxX - window.maxX), height: window.height
        )
        commentsSheetTopBand.frame = top
        commentsSheetBottomBand.frame = bottom
        commentsSheetLeftBand.frame = left
        commentsSheetRightBand.frame = right
        // Their outer corners, the screen's at full screen: a side band takes
        // a corner only where no band runs above or below it.
        let noTop = top.height < 0.5, noBottom = bottom.height < 0.5
        commentsSheetTopBand.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        commentsSheetBottomBand.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        commentsSheetLeftBand.layer.maskedCorners = CACornerMask()
            .union(noTop ? .layerMinXMinYCorner : [])
            .union(noBottom ? .layerMinXMaxYCorner : [])
        commentsSheetRightBand.layer.maskedCorners = CACornerMask()
            .union(noTop ? .layerMaxXMinYCorner : [])
            .union(noBottom ? .layerMaxXMaxYCorner : [])
        for band in [commentsSheetTopBand, commentsSheetBottomBand, commentsSheetLeftBand, commentsSheetRightBand] {
            band.alpha = 1 - t
            band.layer.cornerRadius = screenRadius * (1 - t) * unscale
        }
    }

    /// The page under the comments sheet as `pose` stands (#2287):
    /// `setCommentsSheetLayout`, from one value.
    func setCommentsSheetLayout(
        _ pose: CommentsSheetPose, sheetCornerRadius: CGFloat, previewCornerRadius: CGFloat
    ) {
        setCommentsSheetLayout(
            progress: pose.progress, mediaRegion: pose.region, sheetCornerRadius: sheetCornerRadius,
            out: pose.out, towardsPreview: pose.towardsPreview, previewCornerRadius: previewCornerRadius,
            interface: pose.interface
        )
    }

    /// Where the page shows the picture at rest, in the window's
    /// coordinates — the card untransformed, unspread: what the media's way
    /// back to full screen lands on (#2287). Nil before the card has a size.
    var commentsSheetRestingPictureFrame: CGRect? {
        guard let stage = host.mediaCard.superview else { return nil }
        let bounds = host.mediaCard.bounds
        let page = bounds.insetBy(dx: commentsSheetSpread.width, dy: commentsSheetSpread.height)
        let picture = host.mediaCard.wholePictureRect(in: page).intersection(page)
        guard !picture.isNull, picture.width > 0, picture.height > 0 else { return nil }
        let center = host.mediaCard.center
        let onStage = picture.offsetBy(dx: center.x - bounds.midX, dy: center.y - bounds.midY)
        return stage.convert(onStage, to: nil)
    }

    /// `from` at 0, `to` at 1, edge by edge.
    private static func interpolate(_ from: CGRect, _ to: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }

    /// How far the card stands past the page on each side while the sheet is
    /// up (`spreadCommentsSheetCard`), zero otherwise.
    private var commentsSheetSpread: CGSize = .zero

    /// The card spread to its picture's whole shape, or back to the page:
    /// the card crops a filling picture to the page's shape (a 9:16 clip
    /// loses its sides on a taller screen), and the sheet's cut opens its
    /// whole width (the owner, 2026-11-04). Aspect fill in the picture's own
    /// shape draws the same pixels where the page is — and the mask shows
    /// the page only, at first — so nothing moves on the screen.
    ///
    /// ⚠️ BY THE PINS' CONSTANTS, not by a frame: a layout pass under the
    /// sheet keeps the spread. In one settled layout (`settleGeometry`): the
    /// sample-buffer layer animates its own content to a new size otherwise.
    ///
    /// Read off the PAGE, not the card's bounds: spread, the card's bounds are
    /// the old shape's, and a framing changed under the sheet is redone from
    /// the page — a picture that turned out to fit comes back to it.
    private func spreadCommentsSheetCard(_ spread: Bool = true) {
        let page = host.mediaCard.bounds.insetBy(dx: commentsSheetSpread.width, dy: commentsSheetSpread.height)
        let whole = host.mediaCard.wholePictureRect(in: page)
        let size = spread
            ? CGSize(width: max(0, page.minX - whole.minX), height: max(0, page.minY - whole.minY))
            : .zero
        guard size != commentsSheetSpread else { return }
        let pins = host.pageStage.constraints.filter { $0.firstItem === host.mediaCard && $0.secondItem === host.pageStage }
        // Pinned some other way, the card cannot spread: the layout keeps the
        // picture within the card rather than open on sides nothing draws.
        guard pins.count == 4 else { return }
        commentsSheetSpread = size
        for pin in pins {
            switch pin.firstAttribute {
            case .leading: pin.constant = -size.width
            case .trailing: pin.constant = size.width
            case .top: pin.constant = -size.height
            case .bottom: pin.constant = size.height
            default: break
            }
        }
        host.mediaCard.renderView.settleGeometry { host.pageStage.layoutIfNeeded() }
    }

    /// The picture's edge while the sheet is up: one device pixel of a light
    /// grey — subtle but seen (the owner, 2026-11-03: the separator's grey and
    /// systemGray3 read too faint, a whole point of this one too much) —
    /// fading in as the media shrinks — on the stage, over the media and
    /// untransformed, so the line keeps its width at every scale. Kept for
    /// every media (the owner, 2026-11-03): it marks the media's frame, black
    /// bands baked into the file included, so a viewer sees why they are
    /// there.
    private var commentsSheetEdge: UIView?

    private func drawCommentsSheetEdge(
        around picture: CGRect, cornerRadius: CGFloat, progress: CGFloat, in stage: UIView
    ) {
        let edge = commentsSheetEdge ?? {
            let edge = UIView()
            edge.isUserInteractionEnabled = false
            edge.layer.cornerCurve = .continuous
            commentsSheetEdge = edge
            return edge
        }()
        if edge.superview !== stage { stage.insertSubview(edge, aboveSubview: host.mediaCard) }
        // The media stands on black whatever the page's style: the dark edge.
        let dark = host.traitCollection.modifyingTraits { $0.userInterfaceStyle = .dark }
        edge.layer.borderColor = UIColor.systemGray2.resolvedColor(with: dark).cgColor
        edge.layer.borderWidth = Surface.hairline(for: host.traitCollection)
        edge.frame = picture
        edge.layer.cornerRadius = cornerRadius
        edge.alpha = progress * host.mediaCard.alpha
        edge.isHidden = host.mediaCard.alpha == 0
    }

    /// The page at rest again: identity media, its interface back.
    ///
    /// ⚠️ ONLY FROM REST (#2287): called over a media still on its way back,
    /// it put the page back in one frame — the jump the owner filmed. The
    /// sheet's session calls it once the media has landed
    /// (`CommentsSheetLanding`), where it changes nothing on the screen.
    func clearCommentsSheetLayout() {
        #if DEBUG
        debugCommentsSheetClears += 1
        #endif
        commentsSheetMediaFade = 1
        host.chrome.alpha = 1
        host.columnStage.alpha = 1
        host.chrome.actionColumn.setCommentsSheetShare(0)
        host.mediaCard.transform = .identity
        // Back to the page before the mask goes: the spread's sides never
        // show.
        spreadCommentsSheetCard(false)
        host.mediaCard.mask = nil
        commentsSheetMask = nil
        commentsSheetEdge?.removeFromSuperview()
        commentsSheetPictureFrame = nil
        commentsSheetWholePictureFrame = nil
        // Whatever the last frame left of a scale-out goes with the sheet.
        commentsSheetMediaOut = 0
        setCommentsSheetMediaHidden(false)
    }

    // MARK: The comments sheet's preview (#2087)

    /// Where the shrunk picture stands, in the window's coordinates, as the
    /// last layout drew it, and its corners' radius there: what the sheet's
    /// preview flies from and back to.
    private(set) var commentsSheetPictureFrame: CGRect?
    private(set) var commentsSheetPictureRadius: CGFloat = 0
    /// The whole picture the card draws, in the window's coordinates, as the
    /// last layout placed it — the shrunk window above shows a part of it:
    /// what a stand-in drawn over the sheet places its picture by (#2287).
    private(set) var commentsSheetWholePictureFrame: CGRect?
    #if DEBUG
    /// How many times the page was put back at rest (`clearCommentsSheetLayout`).
    private(set) var debugCommentsSheetClears = 0
    /// The card as the sheet's layout leaves it: its transform, its opacity,
    /// and the interface's.
    var debugCommentsSheetCardTransform: CGAffineTransform { host.mediaCard.transform }
    var debugCommentsSheetCardAlpha: CGFloat { host.mediaCard.alpha }
    var debugCommentsSheetInterfaceAlpha: CGFloat { host.chrome.alpha }
    /// A clip of `aspect` on the card, for the sheet's tests.
    func debugFrameClip(aspect: CGSize) {
        host.mediaCard.configure(kind: .video)
        host.mediaCard.setDeclaredAspect(aspect)
        host.layoutIfNeeded()
    }
    #endif

    /// The media's opacity on top of the rest (`applyCommentsSheetMediaAlpha`):
    /// Reduce Motion's way back cross-fades it in place (#2287).
    var commentsSheetMediaFade: CGFloat = 1 {
        didSet { applyCommentsSheetMediaAlpha() }
    }

    /// The picture out of sight in place while its preview is out — the
    /// card's alpha only: it keeps its frame, its surface and its playback.
    func setCommentsSheetMediaHidden(_ hidden: Bool) {
        isCommentsSheetMediaHidden = hidden
        applyCommentsSheetMediaAlpha()
    }

    private var isCommentsSheetMediaHidden = false
    /// How far the media is scaled out (`setCommentsSheetLayout`).
    private var commentsSheetMediaOut: CGFloat = 0
    /// How much smaller the media is once all the way out.
    private static let commentsSheetOutShrink: CGFloat = 0.4

    private func applyCommentsSheetMediaAlpha() {
        let alpha = (isCommentsSheetMediaHidden ? 0 : 1 - commentsSheetMediaOut) * min(max(0, commentsSheetMediaFade), 1)
        host.mediaCard.alpha = alpha
        commentsSheetEdge?.isHidden = alpha == 0
    }

    /// The media as the sheet's preview draws it: for a clip, a passive
    /// surface on the clip's own player (`attachSurface(_:alongsideSurface:)`),
    /// so it plays on in step and never starts again; otherwise the picture.
    /// Nil when there is nothing to draw.
    func makeCommentsPreviewContent() -> UIView? {
        if let surface = host.audibleSurface, let videoPlayback {
            let mirror = VideoRenderView()
            mirror.videoGravity = .resizeAspectFill
            mirror.isUserInteractionEnabled = false
            mirror.setPoster(host.mediaCard.showsCollection ? host.mediaCard.currentPageCover : host.mediaCard.imageView.image)
            if videoPlayback.attachSurface(mirror, alongsideSurface: surface) { return mirror }
        }
        let picture = host.mediaCard.showsCollection ? host.mediaCard.currentPageCover : host.mediaCard.imageView.image
        guard let picture else { return nil }
        let view = UIImageView(image: picture)
        view.contentMode = .scaleAspectFill
        return view
    }

    /// Lets a preview's content go: a mirror leaves the clip's player.
    func releaseCommentsPreviewContent(_ content: UIView) {
        guard let mirror = content as? VideoRenderView else { return }
        videoPlayback?.detachSurface(mirror, reason: "comments-preview")
    }
}
