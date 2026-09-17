import Foundation
import Lottie
import UIKit

/// The bundled stickers, in the order Chat's favourites strip shows them, and
/// the ways to read one.
///
/// A real "favourites" list would come from the profile service; there is no
/// such field in the contract today, so this ships as a fixed, on-device set —
/// swapping the source later only changes where `stickers` is read from, not
/// how anything draws them.
public enum StickerCatalog {
    public static let stickers: [Sticker] = [
        Sticker(id: "LMAO", emoji: "🤣", label: "Laughing"),
        Sticker(id: "Idea", emoji: "💡", label: "Idea"),
        Sticker(id: "Money", emoji: "💰", label: "Money"),
        Sticker(id: "Book", emoji: "📚", label: "Books"),
        Sticker(id: "Laptop", emoji: "💻", label: "Laptop"),
        Sticker(id: "iPhone", emoji: "📱", label: "Phone"),
        Sticker(id: "Cars", emoji: "🚗", label: "Car"),
        Sticker(id: "Taxi", emoji: "🚕", label: "Taxi"),
        Sticker(id: "Snake", emoji: "🐍", label: "Snake"),
        Sticker(id: "Weather", emoji: "⛅", label: "Weather"),
        Sticker(id: "Temperature", emoji: "🌡️", label: "Temperature"),
        Sticker(id: "NoEntry", emoji: "⛔", label: "No Entry")
    ]

    /// The sticker an overlay names, or nil for an identifier this build does
    /// not ship.
    public static func sticker(id: String) -> Sticker? {
        stickers.first { $0.id == id }
    }

    /// The folder `.copy` put in the bundle, preserved as a directory.
    ///
    /// ⚠️ **`Bundle.module` IS STICKERKIT'S BUNDLE.** The files moved here from
    /// Chat; a feature asking its own `Bundle.module` for them finds nothing,
    /// which is why every read goes through this type.
    private static let subdirectory = "Stickers"

    /// The decoded animation, or nil when the file is missing or corrupt.
    ///
    /// Unzipping and JSON-decoding a dotLottie is real work, so Lottie does it
    /// on its own queue; its shared `DotLottieCache` means each sticker pays
    /// that cost once per launch, not once per view.
    public static func file(for sticker: Sticker) async -> DotLottieFile? {
        try? await DotLottieFile.named(sticker.id, bundle: .module, subdirectory: subdirectory)
    }

    /// `file(for:)` for callers that need the answer in the same turn when it
    /// is cached, handed back on the main thread.
    ///
    /// Callers still have to guard against reuse — the callback can outlive a
    /// cell's current binding.
    public static func load(_ sticker: Sticker, completion: @escaping (DotLottieFile?) -> Void) {
        DotLottieFile.named(sticker.id, bundle: .module, subdirectory: subdirectory) { result in
            switch result {
            case .success(let file):
                completion(file)
            case .failure:
                // A missing or corrupt sticker is a bundling mistake, not a
                // runtime condition to surface: callers keep their emoji
                // stand-in and stay usable.
                completion(nil)
            }
        }
    }

    /// First frame of a sticker, flattened to a bitmap at the screen's scale.
    ///
    /// This is what Chat's strip shows at rest. A paused `LottieAnimationView`
    /// costs no CPU, but it still hands the compositor a deep vector layer tree
    /// per cell, and twelve of those is what makes a strip judder when it
    /// scrolls. One `UIImage` per sticker is one texture.
    ///
    /// Rendered once per sticker and size, and cached for the process; a cached
    /// frame is handed back before this returns.
    @MainActor
    public static func firstFrame(
        for sticker: Sticker,
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
            let image = StickerFrameDrawer(file: file, size: size)
                .image(atSeconds: 0, format: .preferred())
            frameCache.setObject(image, forKey: key)
            completion(image)
        }
    }

    /// Main-actor isolated, matching `firstFrame`: the cache is only ever read
    /// or written from the render path, so it needs no locking of its own.
    @MainActor
    private static let frameCache = NSCache<NSString, UIImage>()
}
