import UIKit

// MARK: - Geometry

/// The whole scroll's tiling: every slice, placed, snapped and stacked.
///
/// Pure geometry, no UIKit state — which is what lets the layout compute it in
/// `prepare()` and the *host* compute the same thing to decide arrangement,
/// with no risk of the two disagreeing about what shape slot 37 is.
public struct ChaoticSliceStack: Sendable {
    /// Absolute item frames, indexed by item. Snapped to the pixel grid and
    /// gutter-free — the layout applies the gutter as an inset so the snapped
    /// edges stay the shared ones.
    public let frames: [CGRect]
    /// One entry per slice: the items it holds and the vertical band it spans,
    /// so `layoutAttributesForElements` can binary-search instead of scanning.
    public let slices: [Slice]
    public let contentHeight: CGFloat
    /// Slot shape per item, for the arrangement pass.
    public let slotMetrics: [SlotMetrics]

    public struct Slice: Sendable {
        public let itemRange: Range<Int>
        public let minY: CGFloat
        public let maxY: CGFloat
    }
}

public extension ChaoticSliceEngine {
    /// Walks the feed slice by slice, generating and placing each one.
    ///
    /// **Every slice is seeded by its own index and generated at the full
    /// `cellsPerSlice`, whatever the item count is.** That is the whole of the
    /// immutability guarantee: a slice's plan is a function of
    /// `(sliceIndex, contentWidth, sliceHeight, cellsPerSlice)` and of nothing
    /// else, so appending items cannot alter a slice that already exists. It
    /// can only fill holes in the last one and add new ones after it.
    ///
    /// This is what the previous shape got wrong. Generating the tail at the
    /// exact number of items left — and giving it a proportionally shorter band
    /// — meant a page landing re-planned it at a new count and a new height, so
    /// every tile in the last slice moved while the viewer was looking at it.
    /// A partial slice now simply leaves its later blocks empty.
    ///
    /// Blocks are placed in **reading order** rather than generation order (the
    /// engine emits largest-first). Two things depend on it: a partial slice
    /// fills from the top so its holes are at the bottom where they read as
    /// "more coming" rather than as scattered gaps, and item order down the
    /// feed matches what the eye follows.
    func stack(
        itemCount: Int,
        contentWidth: CGFloat,
        sliceHeight: CGFloat,
        cellsPerSlice: Int,
        pixelScale: CGFloat
    ) -> ChaoticSliceStack {
        guard itemCount > 0, contentWidth > 0, sliceHeight > 0, cellsPerSlice > 0 else {
            return ChaoticSliceStack(frames: [], slices: [], contentHeight: 0, slotMetrics: [])
        }
        let scale = pixelScale > 0 ? pixelScale : 3
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let size = CGSize(width: contentWidth, height: sliceHeight)

        var frames: [CGRect] = []
        var slices: [ChaoticSliceStack.Slice] = []
        var metrics: [SlotMetrics] = []
        frames.reserveCapacity(itemCount)
        metrics.reserveCapacity(itemCount)

        var item = 0
        var sliceIndex = 0
        var originY: CGFloat = 0
        var occupiedHeight: CGFloat = 0

        while item < itemCount {
            let plan = plan(cellCount: cellsPerSlice, sliceSize: size, seed: UInt64(sliceIndex))
            // The engine always returns at least the undivided block, so this
            // cannot spin; the guard is here so a future change to that contract
            // fails as a short feed rather than as a hang.
            guard !plan.blocks.isEmpty else { break }
            // Sorted before truncation, so which blocks a partial slice uses is
            // decided by position and never by generation order.
            let ordered = Self.readingOrder(of: plan.blocks)
            let taken = Swift.min(ordered.count, itemCount - item)

            let sliceTop = originY
            // Snapped once, and used for BOTH the band and the next slice's
            // origin. Deriving them separately — a raw `sliceTop + height` for
            // the band, a snapped one for the origin — leaves the band a
            // fraction of a point off the frames it is supposed to contain, so
            // the bisection in `layoutAttributesForElements` and the content
            // size disagree with the tiles by a rounding error.
            let sliceBottom = snap(sliceTop + sliceHeight)
            for block in ordered.prefix(taken) {
                // Snap EDGES, not origin-plus-size. Two neighbouring blocks share
                // an edge value exactly, so rounding the edges rounds both sides
                // of the seam identically and the frames stay flush. Rounding a
                // width independently is what puts hairline gaps between tiles.
                let minX = snap(block.minX * size.width)
                let maxX = snap(block.maxX * size.width)
                let minY = sliceTop + snap(block.minY * size.height)
                let maxY = sliceTop + snap(block.maxY * size.height)
                frames.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
                occupiedHeight = Swift.max(occupiedHeight, maxY)
            }
            let sliceAspect = contentWidth / sliceHeight
            metrics.append(contentsOf: ordered.prefix(taken).map { block in
                SlotMetrics(
                    aspect: block.height > 0 ? (block.width * sliceAspect) / block.height : 1,
                    relativeArea: block.width * block.height
                )
            })
            slices.append(.init(itemRange: item..<(item + taken), minY: sliceTop, maxY: sliceBottom))

            item += taken
            // Every slice therefore starts on the pixel grid, which is what
            // keeps the per-block snapping above grid-aligned too.
            originY = sliceBottom
            sliceIndex += 1
        }
        // The OCCUPIED extent, not the last slice's bottom. A partial final
        // slice has empty blocks below its filled ones, and reserving scroll
        // room for them would hang a screenful of background off the end of the
        // feed. Growing this as holes fill moves nothing already placed.
        return ChaoticSliceStack(
            frames: frames, slices: slices, contentHeight: occupiedHeight, slotMetrics: metrics
        )
    }

    /// Top-to-bottom, then leading-to-trailing. A total order — no two blocks in
    /// a partition share an origin — so it is stable without relying on the
    /// sort being stable.
    private static func readingOrder(of blocks: [CGRect]) -> [CGRect] {
        blocks.sorted {
            $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX
        }
    }
}

// MARK: - Layout

/// The For You grid's layout: a stack of BSP-tiled slices, full bleed, no gaps.
///
/// **Why a custom layout and not a compositional one.** The tiling has to vary
/// per slice or the feed repeats the same picture down the scroll, and varying
/// it needs the slice's index as a seed. `NSCollectionLayoutGroup.custom` hands
/// its item provider an `NSCollectionLayoutEnvironment` and nothing else — there
/// is no group index to seed from. The alternative, one section per slice, would
/// push `IndexPath` churn through the feed page, the zoom source and the
/// playback coordinator, all of which address items as `(item:, section: 0)`.
/// A custom layout keeps the single-section addressing those depend on and
/// leaves the hero and autoplay machinery untouched.
public final class ChaoticSliceLayout: UICollectionViewLayout {
    /// Items per full slice. The tail slice holds whatever is left.
    public var cellsPerSlice: Int = 11 {
        didSet { if cellsPerSlice != oldValue { invalidateLayout() } }
    }

    /// Slice height as a multiple of the viewport's. A little over one screenful
    /// so a slice's composition is never fully visible at once — the tiling
    /// reads as continuous rather than as a repeating card.
    public var sliceHeightMultiple: CGFloat = 1.15 {
        didSet { if sliceHeightMultiple != oldValue { invalidateLayout() } }
    }

    /// The gap between tiles, and the tile rounding it is paired with.
    ///
    /// **These two are one decision, which is why they live together.** The
    /// mosaic's 1.5pt hairline works precisely because its bricks are barely
    /// rounded: at 10pt corners and a 1.5pt gap, four tiles meeting at a point
    /// leave a small pinched star of background, and the corners read as damage
    /// to a continuous surface rather than as separate cards. Opening the gap
    /// without opening the radius reads as a grid that has come apart; opening
    /// the radius without the gap makes the pinch worse. Moved together, the
    /// tiles read as a deck of cards.
    ///
    /// 8pt against a 16pt radius — a gap half the corner's curve, so the
    /// background between two tiles is about as wide as the curve is deep.
    public static let harmonisedGutter: CGFloat = 8
    public static let harmonisedCornerRadius: CGFloat = 16

    public var gutter: CGFloat = ChaoticSliceLayout.harmonisedGutter {
        didSet { if gutter != oldValue { invalidateLayout() } }
    }

    /// The rounding the host applies to its cells. Vended here rather than
    /// hardcoded on the cell because `PostGridTileCell` is shared with the
    /// profile gallery, which keeps the mosaic's tighter 1.5pt/10pt pairing.
    public var tileCornerRadius: CGFloat = ChaoticSliceLayout.harmonisedCornerRadius

    public var engine: ChaoticSliceEngine = .standard {
        didSet { invalidateLayout() }
    }

    /// Fired when the slot shapes have changed — a rotation or any other resize
    /// that alters the slice's own aspect and therefore what each block looks
    /// like. The host re-runs its arrangement against the new shapes.
    ///
    /// Delivered asynchronously on purpose: it lands during `prepare()`, and a
    /// synchronous callback would let the host reload the collection view from
    /// inside its own layout pass.
    public var onPlanInvalidated: (() -> Void)?

    private var stack = ChaoticSliceStack(frames: [], slices: [], contentHeight: 0, slotMetrics: [])
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var cacheKey: CacheKey?

    private struct CacheKey: Equatable {
        let width: CGFloat
        let sliceHeight: CGFloat
        let itemCount: Int
        let cellsPerSlice: Int
        let gutter: CGFloat
    }

    // MARK: Geometry resolution

    /// The width and slice height the current collection view implies, or nil
    /// before it has been laid out.
    ///
    /// Height comes from raw `bounds`, deliberately *not* from the inset
    /// viewport: the For You page freezes and thaws its content inset around
    /// every hero flight, and a slice height that tracked the inset would re-tile
    /// the entire feed mid-transition.
    /// The margin down each side of the grid.
    ///
    /// Equal to the gutter, so the background showing beside an outer tile is
    /// exactly as wide as the background between two inner ones. The grid then
    /// reads as evenly spaced all the way across instead of as full-bleed
    /// content that happens to have gaps in it.
    private var sideMargin: CGFloat { gutter }

    /// `width` is the CANVAS — the drawable area inside the side margins, which
    /// is what the tiling is generated against.
    ///
    /// Taking the margins out of the canvas rather than off the outer tiles
    /// keeps every block the proportion the engine chose for it. Insetting the
    /// outer tiles instead would shave a full margin off one side of each edge
    /// block and leave it a different shape from the plan — which is precisely
    /// the distortion `aspectBounds` exists to prevent.
    private func resolvedGeometry() -> (width: CGFloat, sliceHeight: CGFloat)? {
        guard let collectionView else { return nil }
        let insets = collectionView.adjustedContentInset
        let available = collectionView.bounds.width - insets.left - insets.right
        let width = available - sideMargin * 2
        let height = collectionView.bounds.height
        guard width > 0 else { return nil }
        // A host with no height of its own (a self-sizing, non-scrolling one)
        // would otherwise get a zero slice; fall back to a width-relative slice,
        // which is device-independent anyway.
        let viewport = height > 0 ? height : width * 2
        return (width, viewport * sliceHeightMultiple)
    }

    /// The shape of each slot for a feed of `count` items, so the host can place
    /// posts into slots whose aspect suits their media.
    ///
    /// Computed from the same walk `prepare()` uses rather than read off the
    /// cached attributes, because the host asks *before* applying its data —
    /// there are no attributes for items the collection view has not been told
    /// about yet. Returns an empty array when the view has no geometry, which
    /// the host reads as "arrange later", and `onPlanInvalidated` brings it back.
    public func slotMetrics(forItemCount count: Int) -> [SlotMetrics] {
        guard count > 0, let geometry = resolvedGeometry() else { return [] }
        if count == stack.slotMetrics.count, cacheKey?.width == geometry.width,
           cacheKey?.sliceHeight == geometry.sliceHeight {
            return stack.slotMetrics
        }
        return engine.stack(
            itemCount: count,
            contentWidth: geometry.width,
            sliceHeight: geometry.sliceHeight,
            cellsPerSlice: cellsPerSlice,
            pixelScale: pixelScale
        ).slotMetrics
    }

    private var pixelScale: CGFloat {
        let scale = collectionView?.traitCollection.displayScale ?? 0
        return scale > 0 ? scale : 3
    }

    // MARK: UICollectionViewLayout

    override public func prepare() {
        super.prepare()
        guard let collectionView, let geometry = resolvedGeometry() else { return }
        let count = collectionView.numberOfSections > 0
            ? collectionView.numberOfItems(inSection: 0)
            : 0
        let key = CacheKey(
            width: geometry.width, sliceHeight: geometry.sliceHeight,
            itemCount: count, cellsPerSlice: cellsPerSlice, gutter: gutter
        )
        guard key != cacheKey else { return }
        // A changed item count leaves every existing slot's shape alone — only
        // the geometry can re-shape slots, and only that is worth a re-arrange.
        let reshaped = cacheKey.map { $0.width != key.width || $0.sliceHeight != key.sliceHeight } ?? false
        cacheKey = key

        stack = engine.stack(
            itemCount: count,
            contentWidth: geometry.width,
            sliceHeight: geometry.sliceHeight,
            cellsPerSlice: cellsPerSlice,
            pixelScale: pixelScale
        )
        attributes = stack.frames.enumerated().map { item, frame in
            let attribute = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: item, section: 0)
            )
            // Canvas-relative frames: inset the seams, then slide the whole
            // grid over by the side margin.
            attribute.frame = gutterInset(frame, within: key.width, by: stack.contentHeight)
                .offsetBy(dx: sideMargin, dy: 0)
            return attribute
        }
        if reshaped {
            DispatchQueue.main.async { [weak self] in self?.onPlanInvalidated?() }
        }
    }

    /// Takes half the gutter off each edge a tile SHARES with a neighbour, and
    /// nothing off the edges that lie on the canvas boundary.
    ///
    /// Half from each side of a seam adds up to one full gutter between tiles.
    /// The canvas edges are left alone because the margin beside them is
    /// already provided by `sideMargin` — insetting there as well would make
    /// the outer margin one and a half gutters wide while inner seams stayed at
    /// one.
    private func gutterInset(_ frame: CGRect, within width: CGFloat, by height: CGFloat) -> CGRect {
        let half = gutter / 2
        // Half a point of slack: frames are snapped to the pixel grid, so an
        // outer edge lands ON the boundary rather than near it, but the
        // accumulated slice origin can leave the last row a rounding step short.
        let slack: CGFloat = 0.5
        let leading = frame.minX <= slack ? 0 : half
        let trailing = frame.maxX >= width - slack ? 0 : half
        let top = frame.minY <= slack ? 0 : half
        let bottom = frame.maxY >= height - slack ? 0 : half
        return CGRect(
            x: frame.minX + leading,
            y: frame.minY + top,
            width: max(0, frame.width - leading - trailing),
            height: max(0, frame.height - top - bottom)
        )
    }

    override public var collectionViewContentSize: CGSize {
        // Read from the cache key rather than the collection view, so the size
        // always describes the attributes that were actually built. The key
        // holds the CANVAS width, so the margins go back on here — the content
        // is as wide as the grid plus the background either side of it.
        guard let cacheKey else { return .zero }
        return CGSize(width: cacheKey.width + sideMargin * 2, height: stack.contentHeight)
    }

    override public func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override public func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !stack.slices.isEmpty else { return [] }
        // Slices are stacked and non-overlapping, so the first one reaching into
        // the rect can be found by bisection and the rest read off in order.
        var low = 0
        var high = stack.slices.count - 1
        var first = stack.slices.count
        while low <= high {
            let mid = (low + high) / 2
            if stack.slices[mid].maxY > rect.minY {
                first = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        var found: [UICollectionViewLayoutAttributes] = []
        var index = first
        while index < stack.slices.count, stack.slices[index].minY < rect.maxY {
            for item in stack.slices[index].itemRange where attributes.indices.contains(item) {
                // A slice's band overlapping the rect does not mean every tile in
                // it does — the band is up to a screenful tall.
                if attributes[item].frame.intersects(rect) { found.append(attributes[item]) }
            }
            index += 1
        }
        return found
    }

    override public func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // Size only. A scroll changes `bounds.origin`, and re-preparing on every
        // frame of a scroll would rebuild the whole stack 120 times a second.
        guard let collectionView else { return false }
        return newBounds.size != collectionView.bounds.size
    }
}
