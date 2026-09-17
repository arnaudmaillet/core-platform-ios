import Lottie

/// Stickers any feature can lay down: the catalogue (`StickerCatalog`), the
/// view that loops one on screen (`StickerLoopView`), the frames baked for a
/// compositor that cannot run Lottie (`StickerFrameBaker`, `StickerStrip`,
/// `StickerArtwork`), and the emoji a picker offers beside them
/// (`EmojiCatalog`).
///
/// ⚠️ **FEATURES CANNOT IMPORT EACH OTHER**, which is why the stickers Chat
/// shipped first live here: Chat's favourites strip and the upload editor both
/// read this package.
public enum StickerKit {
    /// The engine a sticker playing ON SCREEN is drawn with.
    ///
    /// ⚠️ **CORE ANIMATION, NOT `.mainThread`.** The chat strip plays its
    /// favourites this way so a row of looping stickers costs the render server
    /// and not the main thread; `.mainThread` is for drawing single frames,
    /// which is what baking asks for (`StickerFrameBaker`).
    public static var onScreenEngine: RenderingEngineOption { .coreAnimation }
}
