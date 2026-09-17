import Lottie

/// Stickers any feature can lay down: the catalogue, the view that loops one on
/// screen, and the frames baked for a compositor that cannot run Lottie.
///
/// ⚠️ **A SKELETON FOR NOW.** The sticker slice (S4) moves Chat's twelve
/// `.lottie` files and its catalogue here, and adds the looping view, the frame
/// baker and the emoji catalogue. This file exists so the package, its Lottie
/// dependency and the packages that depend on it resolve and build before that
/// work starts.
///
/// ⚠️ **FEATURES CANNOT IMPORT EACH OTHER**, which is why the stickers Chat
/// already ships have to move to a package before the media editor can use
/// them.
public enum StickerKit {
    /// The engine a sticker playing ON SCREEN is drawn with.
    ///
    /// ⚠️ **CORE ANIMATION, NOT `.mainThread`.** The chat strip plays its
    /// favourites this way so a row of looping stickers costs the render server
    /// and not the main thread; `.mainThread` is for drawing a single still
    /// frame, which is what baking asks for.
    public static var onScreenEngine: RenderingEngineOption { .coreAnimation }
}
