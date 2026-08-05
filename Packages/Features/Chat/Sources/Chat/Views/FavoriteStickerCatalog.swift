import Foundation
import Lottie
import UIKit

/// One entry in the composer's favorites strip: an animated dotLottie sticker
/// bundled with the app, plus the emoji it stands for.
///
/// The emoji is not decoration — it is what a tap actually inserts. `chat.v1`
/// `SendMessage` carries a text body and nothing else (no sticker id, no media
/// ref), so a sticker cannot travel the wire as itself. These twelve are all
/// animated renderings of standard emoji, which gives an honest mapping: the
/// strip is a rich picker over a plain-text channel, and what the recipient
/// receives is exactly what the sender saw themselves compose.
struct FavoriteSticker: Hashable, Sendable, Identifiable {
    /// Resource name inside `Resources/Stickers`, without the extension.
    let id: String
    /// Inserted into the composer on tap.
    let emoji: String
    /// Spoken name, for VoiceOver.
    let label: String
}

/// The bundled favorites, in strip order. A real "favorites" list would come
/// from the profile service; there is no such field in the contract today, so
/// this ships as a fixed, on-device set — swapping the source later only
/// changes where `favorites` is read from, not how the strip renders.
enum FavoriteStickerCatalog {
    static let favorites: [FavoriteSticker] = [
        FavoriteSticker(id: "LMAO", emoji: "🤣", label: "Laughing"),
        FavoriteSticker(id: "Idea", emoji: "💡", label: "Idea"),
        FavoriteSticker(id: "Money", emoji: "💰", label: "Money"),
        FavoriteSticker(id: "Book", emoji: "📚", label: "Books"),
        FavoriteSticker(id: "Laptop", emoji: "💻", label: "Laptop"),
        FavoriteSticker(id: "iPhone", emoji: "📱", label: "Phone"),
        FavoriteSticker(id: "Cars", emoji: "🚗", label: "Car"),
        FavoriteSticker(id: "Taxi", emoji: "🚕", label: "Taxi"),
        FavoriteSticker(id: "Snake", emoji: "🐍", label: "Snake"),
        FavoriteSticker(id: "Weather", emoji: "⛅", label: "Weather"),
        FavoriteSticker(id: "Temperature", emoji: "🌡️", label: "Temperature"),
        FavoriteSticker(id: "NoEntry", emoji: "⛔", label: "No Entry")
    ]

    /// The folder `.copy` put in the bundle, preserved as a directory.
    private static let subdirectory = "Stickers"

    /// Hands back the decoded animation on the main thread.
    ///
    /// Unzipping and JSON-decoding a dotLottie is real work, so Lottie does it
    /// on its own queue; the shared `DotLottieCache` means the strip pays that
    /// cost once per sticker per launch, not once per cell dequeue. Callers
    /// still have to guard against reuse — the callback can outlive the cell's
    /// current binding.
    static func load(_ sticker: FavoriteSticker, completion: @escaping (DotLottieFile?) -> Void) {
        DotLottieFile.named(sticker.id, bundle: .module, subdirectory: subdirectory) { result in
            switch result {
            case .success(let file):
                completion(file)
            case .failure:
                // A missing or corrupt sticker is a bundling mistake, not a
                // runtime condition to surface: the cell keeps its emoji
                // fallback and the strip stays usable.
                completion(nil)
            }
        }
    }

    /// First frame of a sticker, flattened to a bitmap.
    ///
    /// This is what the strip shows at rest. A paused `LottieAnimationView`
    /// costs no CPU, but it still hands the compositor a deep vector layer
    /// tree per cell, and twelve of those is what makes the strip judder when
    /// it scrolls. One `UIImage` per sticker is one texture.
    ///
    /// Rendered once per sticker and cached for the process: the work is a
    /// few milliseconds at 28pt and only ever happens on a cold strip.
    @MainActor
    static func firstFrame(
        for sticker: FavoriteSticker,
        size: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        let key = "\(sticker.id)@\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = frameCache.object(forKey: key) {
            completion(cached)
            return
        }
        load(sticker) { file in
            guard let file else {
                completion(nil)
                return
            }
            // The MAIN THREAD engine, deliberately, and only here: it draws the
            // frame into its own layer, which `render(in:)` can capture. The
            // Core Animation engine expresses frames as CAAnimations over a
            // sublayer tree, and snapshotting that offscreen yields an empty
            // image. Playback still uses Core Animation (see the cell).
            let renderer = LottieAnimationView(
                configuration: LottieConfiguration(renderingEngine: .mainThread)
            )
            renderer.loadAnimation(from: file)
            renderer.contentMode = .scaleAspectFit
            renderer.frame = CGRect(origin: .zero, size: size)
            renderer.currentProgress = 0
            renderer.layoutIfNeeded()
            renderer.forceDisplayUpdate()

            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                renderer.layer.render(in: context.cgContext)
            }
            frameCache.setObject(image, forKey: key)
            completion(image)
        }
    }

    /// Main-actor isolated, matching `firstFrame`: the cache is only ever read
    /// or written from the render path, so it needs no locking of its own.
    @MainActor
    private static let frameCache = NSCache<NSString, UIImage>()
}
