import Foundation
import Lottie
import StickerKit
import UIKit

/// One entry in the composer's favorites strip — a StickerKit `Sticker`.
///
/// The emoji is what a tap actually inserts: `chat.v1` `SendMessage` carries a
/// text body and nothing else, so a sticker cannot travel the wire as itself
/// (see `Sticker`).
typealias FavoriteSticker = Sticker

/// The composer's favorites, read from StickerKit.
///
/// ⚠️ **THE STICKERS LIVE IN STICKERKIT NOW**, files and all, so the upload
/// editor can lay the same ones over a picture — features cannot import each
/// other. Chat's `Bundle.module` no longer holds them; this shim is the only
/// way the strip reaches them.
enum FavoriteStickerCatalog {
    static var favorites: [FavoriteSticker] { StickerCatalog.stickers }

    /// Hands back the decoded animation on the main thread
    /// (`StickerCatalog.load`).
    static func load(_ sticker: FavoriteSticker, completion: @escaping (DotLottieFile?) -> Void) {
        StickerCatalog.load(sticker, completion: completion)
    }

    /// The first frame the strip shows at rest (`StickerCatalog.firstFrame`).
    @MainActor
    static func firstFrame(
        for sticker: FavoriteSticker,
        size: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        StickerCatalog.firstFrame(for: sticker, size: size, completion: completion)
    }
}
