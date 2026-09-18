// `VideoRenderView` — the surface the settled page's clip plays in.
import MediaPlayback
import UIKit

/// One page of the canvas: the media, filling it.
final class MediaEditorPageCell: UICollectionViewCell {
    /// ⚠️ A PICTURE ARRIVES LATE AND A CELL IS REUSED EARLY — the same guard the
    /// grid's tile carries, for the same reason.
    private(set) var representedID: String?

    private let picture = UIImageView()
    private let surface = VideoRenderView()

    /// Where the page's text, emoji and stickers are drawn, as views over the
    /// picture and the video alike.
    ///
    /// ⚠️ **PINNED TO THE PICTURE, LIKE THE SURFACE — AND ABOVE IT.** Overlays
    /// are placed in fractions of the finished picture, so they must live in the
    /// rectangle the picture lives in, whichever way it is laid; and they sit
    /// over a playing clip, not under it. The overlay mode fills it and decides
    /// when it takes touches; until it does, it is empty and takes none.
    let overlayHost = MediaOverlayLayerView()

    /// ⚠️ **HELD, BECAUSE A FITTED PICTURE DOES NOT LIVE IN THE SAME RECTANGLE AS
    /// A FILLED ONE.** Filling means the whole window, bars included — that is what
    /// full-bleed is for. Fitting means showing the picture WHOLE, and a whole
    /// picture centred in the window puts its middle behind the toolbar and its
    /// edges under the chrome: it reads as hanging low. The window a fitted picture
    /// is centred in runs from the foot of the top bar to the head of the page
    /// indicator, and these four constants are how it gets there.
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(picture)
        top = picture.topAnchor.constraint(equalTo: contentView.topAnchor)
        bottom = picture.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            top, bottom,
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        // ⚠️ **PINNED TO THE PICTURE, NOT TO THE CONTENT VIEW.** The fit/fill
        // window is four constants held on `picture`, and a surface that
        // duplicated them would drift the first time one of the two was changed
        // alone. Pinned here it inherits the geometry for free: when the author
        // fits a clip, the video is laid in the same rectangle as the poster it
        // replaces, and the swap from one to the other moves nothing.
        surface.isHidden = true
        surface.isUserInteractionEnabled = false
        // The page draws its own ground (the editor paints behind everything);
        // an opaque black surface would put a letterbox back under a fitted clip.
        surface.paintsOpaqueGround = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: picture.topAnchor),
            surface.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: picture.trailingAnchor)
        ])
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlayHost)
        NSLayoutConstraint.activate([
            overlayHost.topAnchor.constraint(equalTo: picture.topAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
            overlayHost.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
            overlayHost.trailingAnchor.constraint(equalTo: picture.trailingAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .image
        picture.accessibilityTraits = .image
    }

    /// ⚠️ **A CELL THAT IS AN ACCESSIBILITY ELEMENT HIDES EVERYTHING INSIDE
    /// IT.** VoiceOver would read "Photo" and never reach an overlay; so a page
    /// carrying overlays becomes a container of the picture and its overlays,
    /// and a page without any stays the one element it always was.
    func overlaysDidChange() {
        let overlays = overlayHost.items
        isAccessibilityElement = overlays.isEmpty
        picture.isAccessibilityElement = !overlays.isEmpty
        picture.accessibilityLabel = accessibilityLabel
        accessibilityElements = overlays.isEmpty ? nil : [picture] + overlays
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **A REUSED CELL MUST NOT KEEP A SURFACE THAT IS STILL PLAYING.** The
    /// canvas recycles pages, so the cell that carried page 2's clip becomes
    /// page 5's without asking anyone. Whoever put a player here has to be told;
    /// the editor sets this when it hands the cell a surface to play in.
    var onReuse: ((VideoRenderView) -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        picture.image = nil
        overlayHost.contentSize = nil
        onReuse?(surface)
        onReuse = nil
        surface.isHidden = true
    }

    func prepare(for item: MediaLibraryItem) {
        representedID = item.id
        accessibilityLabel = item.isVideo ? "Video" : "Photo"
        picture.accessibilityLabel = accessibilityLabel
    }

    /// The surface a video plays in, for the editor to hand to its player.
    /// Hidden until something is actually bound to it — an empty
    /// `VideoRenderView` over the poster is a black rectangle.
    var videoSurface: VideoRenderView { surface }

    /// Reveals the video and lets the poster underneath show through until the
    /// first decoded frame arrives.
    func beginShowingVideo() {
        // The poster is the picture this page already drew — the very frame the
        // grid showed and the publish path will upload. Handing the surface the
        // same one means the swap to live playback changes the motion and
        // nothing else.
        surface.setPoster(picture.image)
        surface.isHidden = false
        surface.fadeInOnFirstFrame(over: 0.2)
    }

    func stopShowingVideo() {
        surface.isHidden = true
        surface.setPoster(nil)
    }

    /// Hands over a picture fetched for `id`, and ignores one whose page has
    /// moved on.
    func show(_ image: UIImage?, for id: String) {
        guard representedID == id else { return }
        picture.image = image
        overlayHost.contentSize = image?.size
    }

    /// ⚠️ **`contentMode` IS NOT AN ANIMATABLE PROPERTY.** Assigning it inside a
    /// `UIView.animate` block changes the picture in one frame. A crossfade
    /// through `UIView.transition` is how the jump is softened — the same move
    /// the feed's render view makes when it swaps a poster for live playback.
    func setContentMode(_ mode: UIView.ContentMode, animated: Bool) {
        guard picture.contentMode != mode else { return }
        guard animated else {
            picture.contentMode = mode
            return
        }
        UIView.transition(
            with: picture, duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.picture.contentMode = mode
        }
    }

    /// Lays the picture the way the author left it, in the window a fitted one is
    /// centred in.
    ///
    /// ⚠️ **THE INSETS APPLY TO `fit` ONLY.** A filled picture keeps the whole
    /// window on purpose — it is cropped by the frame either way, so insetting it
    /// would only show less of it for nothing.
    func lay(_ fit: ContentFit, within window: UIEdgeInsets, animated: Bool) {
        setContentMode(fit.mode, animated: animated)
        // The overlays follow the same choice: a filled picture's chrome covers
        // part of it, a fitted one is already inset clear of it.
        overlayHost.fit = fit
        overlayHost.chromeInsets = fit == .fit ? .zero : window
        // ⚠️ THE VIDEO OBEYS THE SAME CHOICE AS THE PICTURE. Left at the feed's
        // `.resizeAspectFill`, a clip the author asked to see WHOLE would carry
        // on being cropped — and the poster beneath it would not be, so the swap
        // to live playback would jump.
        surface.videoGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        let applied = fit == .fit ? window : .zero
        guard top.constant != applied.top || bottom.constant != -applied.bottom else { return }
        top.constant = applied.top
        bottom.constant = -applied.bottom
        guard animated else {
            contentView.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.contentView.layoutIfNeeded()
        }
    }

    /// Internal for tests: where the picture actually sits in its page.
    var debugPictureFrame: CGRect { picture.frame }
    /// Internal for tests: whether a curve is carrying the picture somewhere.
    var debugPictureIsMoving: Bool { !(picture.layer.animationKeys() ?? []).isEmpty }

    /// Internal for tests: the picture on the page, to read its pixels.
    var debugPicture: UIImage? { picture.image }

    /// Internal for tests: whether a picture has actually landed.
    var debugHasPicture: Bool { picture.image != nil }
    /// Internal for tests: how the picture is currently laid in its page.
    var debugContentMode: UIView.ContentMode { picture.contentMode }
    /// Internal for tests: the size of what is actually on the page — the only
    /// thing that can tell a rendered crop from the picture it was cut from.
    var debugPictureSize: CGSize { picture.image?.size ?? .zero }
    /// Internal for tests: whether this page is showing a video surface at all.
    var debugIsShowingVideo: Bool { !surface.isHidden }
    /// Internal for tests: how the video is laid, which must track the picture.
    var debugVideoGravityIsFit: Bool { surface.videoGravity == .resizeAspect }
}
