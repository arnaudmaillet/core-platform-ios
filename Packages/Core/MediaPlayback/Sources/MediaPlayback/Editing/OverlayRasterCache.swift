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
/// ⚠️ **A `Mutex` FOR THE BOOKS, AND THE DRAWING HAPPENS OUTSIDE IT.** The
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
    static let shared = OverlayRasterCache(budget: 64 * 1024 * 1024)

    private struct Entry {
        let raster: OverlayRasterizer.Raster
        let cost: Int
        var lastUse: UInt64
    }

    private struct Books {
        var entries: [Key: Entry] = [:]
        var cost = 0
        var clock: UInt64 = 0
        var renders = 0
    }

    /// The most bytes of pixels kept at once.
    let budget: Int
    private let books = Mutex(Books())

    init(budget: Int) {
        self.budget = budget
    }

    /// How many times this cache has had a picture drawn — every miss, whether
    /// the drawing produced a picture or not.
    var renders: Int {
        books.withLock { $0.renders }
    }

    /// How many bytes of pixels are kept now.
    var cost: Int {
        books.withLock { $0.cost }
    }

    /// The picture for `key`: the kept one, or what `render` draws — which is
    /// then kept, unless it alone is bigger than the whole budget.
    func raster(
        for key: Key, render: () -> OverlayRasterizer.Raster?
    ) -> OverlayRasterizer.Raster? {
        let kept = books.withLock { books -> OverlayRasterizer.Raster? in
            guard var entry = books.entries[key] else { return nil }
            books.clock += 1
            entry.lastUse = books.clock
            books.entries[key] = entry
            return entry.raster
        }
        if let kept { return kept }

        let drawn = render()
        books.withLock { books in
            books.renders += 1
            guard let drawn else { return }
            let cost = drawn.image.bytesPerRow * drawn.image.height
            guard cost <= budget else { return }
            books.clock += 1
            if let previous = books.entries[key] { books.cost -= previous.cost }
            books.entries[key] = Entry(raster: drawn, cost: cost, lastUse: books.clock)
            books.cost += cost
            // ⚠️ A SCAN, NOT A LINKED LIST. The cache holds tens of pictures,
            // rarely hundreds, and an eviction is rare next to a hit.
            while books.cost > budget,
                  let oldest = books.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                books.entries[oldest.key] = nil
                books.cost -= oldest.value.cost
            }
        }
        return drawn
    }
}
