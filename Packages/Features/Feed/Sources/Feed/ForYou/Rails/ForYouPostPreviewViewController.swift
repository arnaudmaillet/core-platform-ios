import CoreModels
import DesignSystem
import MediaCore
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
///   │ Open                 │   the menu (`ForYouRailsView`)
///   │ View Profile         │
///   └──────────────────────┘
/// ```
///
/// A card's preview is its post; a friend's is the post a tap on their face
/// opens first, so the preview answers "what would I see" in both rows.
///
/// ⚠️ A STILL, NOT THE CLIP. The row's card is already playing this post from
/// the shared pool, and a second surface on that playback is a render slot
/// MOVED rather than shared outside the sample-buffer path
/// (`VideoPlaybackController.attachSurface`) — the card under the lifted
/// preview would go black, and it is the card the flight takes off from if
/// the preview is committed. The cover is the frame the card showed before it
/// played, and a preview is looked at for a second.
///
/// The caption is the card's own overlay (`ForYouCardCaptionOverlay`), so its
/// emotes animate here too (`EmoteLabel`).
///
/// ⚠️ Not `@MainActor` in so many words, for `ForYouRailsView`'s reason: the
/// explicit attribute turns the synchronous `ImagePipeline.cachedImage` read
/// into an error.
final class ForYouPostPreviewViewController: UIViewController {
    let post: GalleryPost
    private let imagePipeline: ImagePipeline
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?

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

    init(post: GalleryPost, imagePipeline: ImagePipeline, width: CGFloat) {
        self.post = post
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSize(for: post, width: width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
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
        let overlay = ForYouCardCaptionOverlay(post: post, placement: isText ? .onCard : .onMedia)
        overlay.pin(to: view)

        guard !isText, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        let pipeline = imagePipeline
        loadTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url), !Task.isCancelled,
                  let self else { return }
            UIView.transition(
                with: imageView, duration: 0.2, options: .transitionCrossDissolve
            ) { self.imageView.image = image }
        }
    }

    #if DEBUG
    var debugShowsCover: Bool { imageView.image != nil }
    #endif
}
