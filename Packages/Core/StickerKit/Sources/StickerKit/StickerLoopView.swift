import Lottie
import UIKit

/// A sticker playing on screen, round and round, for as long as the view
/// lives — what a sticker laid over a video shows in the editor.
///
/// It fills its bounds, aspect-fit, and takes no touches: whatever hosts it
/// owns the gestures and the accessibility element.
///
/// ⚠️ **`loadAnimation(from:)` RESETS `loopMode`** to what the dotLottie
/// manifest declares, and these files declare a single pass. A loop set before
/// the load is silently overwritten: the sticker plays once and then sits on its
/// last frame, which looks exactly like a still. The loop is set AFTER the load.
///
/// ⚠️ **NOT FRAME-LOCKED TO A FILM.** It runs on its own clock; the export reads
/// baked frames by the film's time instead (`StickerArtwork`).
public final class StickerLoopView: UIView {
    public let sticker: Sticker
    /// Core Animation engine (`StickerKit.onScreenEngine`): the loop is compiled
    /// once and run by the render server, not redrawn on the main thread.
    let player = LottieAnimationView(configuration: LottieConfiguration(renderingEngine: StickerKit.onScreenEngine))
    /// False until the file is read and the loop has started. The file is read
    /// off the main thread, so a new view is empty for a moment.
    public private(set) var isLooping = false

    public init(sticker: Sticker) {
        self.sticker = sticker
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        player.contentMode = .scaleAspectFit
        player.backgroundBehavior = .pauseAndRestore
        player.isUserInteractionEnabled = false
        player.frame = bounds
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(player)

        Task { [weak self] in
            guard let file = await StickerCatalog.file(for: sticker) else { return }
            self?.start(with: file)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func start(with file: DotLottieFile) {
        player.loadAnimation(from: file)
        // AFTER the load — see the type's note.
        player.loopMode = .loop
        player.play()
        isLooping = true
    }
}
