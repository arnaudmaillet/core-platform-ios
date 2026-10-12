import CacheKit
import CoreGraphics
import Synchronization

/// The overlay pictures `OverlayRasterizer` has already drawn, the least
/// recently used dropped first once they outgrow a byte budget.
///
/// ⚠️ **A TEXT ON A VIDEO IS THE SAME PICTURE ON EVERY FRAME.** The compositor
/// asks for it thirty or sixty times a second, and laying out and drawing a
/// paragraph each time would be the most expensive stage of a frame that
/// changes nothing. Text and emoji are therefore drawn once per content and
/// size. Sticker frames are NOT kept here: they change with time, and their
/// strip keeps its own decoded frame.
///
/// ⚠️ **A LOCK FOR THE BOOKS, AND THE DRAWING HAPPENS OUTSIDE IT.** The
/// compositor's queue, a detached photo bake and the editor's overlay views can
/// all ask at once. Holding the lock while a paragraph is drawn would make each
/// of them wait for the others' typesetting; drawing outside it means two
/// callers that miss the same picture at the same moment may both draw it —
/// the same pixels twice, which is cheaper than a queue.
///
/// ⚠️ **A BUDGET IN BYTES, NOT A COUNT.** One export-sized paragraph can weigh as
/// much as a hundred small ones; a count would bound nothing that matters on a
/// 3 GB phone.
final class OverlayRasterCache: Sendable {
    /// What a picture depends on.
    ///
    /// ⚠️ **THE CONTENT IS SPELLED, NOT HASHED** — for the reason
    /// `MediaEdits.signature` gives in Upload: a collision here is not a slow
    /// path but the previous text drawn in place of the new one. A spelled value
    /// cannot collide, and it grows with `FrameOverlay.Content` by itself.
    struct Key: Hashable, Sendable {
        let content: String
        /// The size the content is drawn at, in pixels of the finished frame —
        /// a text's point size or an emoji's side.
        let size: Double

        init(_ content: FrameOverlay.Content, size: Double) {
            self.content = String(describing: content)
            self.size = size
        }
    }

    /// The process's cache: 64 MB of pixels.
    ///
    /// ⚠️ **MEGABYTES, NOT THE PLAN'S "64 MEGAPIXELS".** Sixty-four megapixels of
    /// RGBA is 256 MB — a twelfth of an iPhone SE's memory spent on text. A
    /// paragraph at 1080p export size is about a fifth of a megapixel, so 64 MB
    /// still holds some three hundred of them.
    ///
    /// Announced to the device cache (#894): its budget and trims are the
    /// coordinator's, so a memory warning frees these pictures as it frees
    /// the feed's, and a logout drops the previous viewer's texts.
    static let shared: OverlayRasterCache = {
        let cache = OverlayRasterCache(budget: 64 * 1024 * 1024)
        UIAssetCaches.shared.adopt(cache.entries)
        return cache
    }()

    /// The device cache's name for these pictures. `viewer`: they spell the
    /// viewer's own drafts, so a logout or a switch drops them.
    ///
    /// ⚠️ `persistent`, the UI assets' class, NOT `standard`. An export goes on
    /// in the background, and the background pauses a `standard` memory
    /// cache's admissions and empties it: every frame of the export would then
    /// lay its paragraph out again, the cost this cache exists to remove. The
    /// class gives up only what was never drawn on a warning or the background,
    /// and the rest on a CRITICAL warning.
    static let namespace = CacheNamespace("editing.overlays", category: .other, scope: .viewer, priorityClass: .persistent)

    /// The most bytes of pixels kept at once, until a coordinator sets its own.
    let budget: Int
    /// The pictures, least recently used dropped first past the budget.
    let entries: MemoryCache<Key, OverlayRasterizer.Raster>
    private let drawings = Mutex(0)

    init(budget: Int) {
        self.budget = budget
        entries = MemoryCache(
            namespace: Self.namespace,
            budget: .fixed(bytes: budget),
            limits: CacheLimits(bytes: budget, speculativeShare: CacheCoordinator.speculativeShare)
        )
    }

    /// How many times this cache has had a picture drawn — every miss, whether
    /// the drawing produced a picture or not.
    var renders: Int {
        drawings.withLock { $0 }
    }

    /// How many bytes of pixels are kept now.
    var cost: Int {
        entries.usage.bytes
    }

    /// The picture for `key`: the kept one, or what `render` draws — which is
    /// then kept, unless it alone is bigger than the whole budget.
    func raster(
        for key: Key, render: () -> OverlayRasterizer.Raster?
    ) -> OverlayRasterizer.Raster? {
        if let kept = entries.value(for: key) { return kept }
        let drawn = render()
        drawings.withLock { $0 += 1 }
        guard let drawn else { return nil }
        entries.insert(drawn, for: key, cost: drawn.image.bytesPerRow * drawn.image.height)
        return drawn
    }
}
