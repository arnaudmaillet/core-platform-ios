import CoreModels
import DesignSystem
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
/// The caption is the card's own overlay (`ForYouCardCaptionOverlay`), so its
/// emotes animate here too (`EmoteLabel`).
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

    init(post: GalleryPost, imagePipeline: ImagePipeline, width: CGFloat, videoPlayback: VideoPlaybackController? = nil) {
        self.post = post
        self.imagePipeline = imagePipeline
        self.videoPlayback = videoPlayback
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSize(for: post, width: width)
    }

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
        let overlay = ForYouCardCaptionOverlay(
            post: post, placement: isText ? .onCard : .onMedia, imagePipeline: imagePipeline
        )
        overlay.pin(to: view)

        guard !isText, let url = post.thumbnailURL else { return }
        cover.load(url, using: imagePipeline) { [weak self] image, transition in
            guard let self else { return }
            transition.perform(on: imageView) { self.imageView.image = image }
        }
    }

    #if DEBUG
    var debugShowsCover: Bool { imageView.image != nil }
    /// The clip's surface and whether the preview owns its playback (#1318).
    var debugVideoView: VideoRenderView { videoView }
    var debugOwnsPlayback: Bool { ownsPlayback }
    #endif
}
