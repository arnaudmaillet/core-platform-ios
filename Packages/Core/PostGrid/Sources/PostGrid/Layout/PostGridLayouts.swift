import UIKit

/// The two shapes a post grid page can take, as bare compositional layouts.
///
/// Layouts are format-bound: Media is the asymmetric mosaic, Activity and
/// Short are a 1-column timeline. Vended as free-standing layouts rather than
/// baked into a view because the two consumers host them very differently —
/// the profile's gallery page is a *non-scrolling* self-sizing collection
/// view (its outer scroll view owns all vertical motion), while a discovery
/// root is a real scrolling collection view with cell reuse and pagination.
/// The pattern is shared; the host is not.
public enum PostGridMosaic {
    /// The mosaic's hairline gutter between bricks.
    public static let gutter: CGFloat = 1.5

    /// One full pattern is 8 bricks — the count a skeleton page renders so the
    /// loading state already has the shape content will hydrate into.
    public static let patternLength = 8

    /// The shape of each brick in the repeating pattern, read off the groups
    /// built in `layout()`. Position decides shape; the media does not.
    public enum SlotShape: Equatable, Sendable {
        case portrait
        case landscape
        case square

        /// Whether a moving image reads well here. Squares are the pattern's
        /// filler: four of the eight, the smallest bricks, and clustered — so
        /// they carry stills and the larger bricks carry motion.
        public var suitsMotion: Bool { self != .square }

        /// Whether a brick of this shape is the natural home for media of
        /// `shape`. Square media never autoplays, so only the two elongated
        /// shapes ever match.
        func matches(_ shape: GalleryPost.Shape) -> Bool {
            switch (self, shape) {
            case (.portrait, .portrait), (.landscape, .landscape): true
            default: false
            }
        }
    }

    /// Indexed by position within the pattern. Mirrors the diagram above:
    /// half A is portrait, landscape, square, square; half B is its mirror.
    public static let slotShapes: [SlotShape] = [
        .portrait, .landscape, .square, .square,
        .square, .square, .landscape, .portrait
    ]

    public static func slotShape(at index: Int) -> SlotShape {
        slotShapes[((index % patternLength) + patternLength) % patternLength]
    }

    /// Places `posts` into the consecutive grid slots starting at
    /// `absoluteIndex`, preferring the non-square bricks for posts that can
    /// autoplay.
    ///
    /// **Why this is done here and not in the seed data.** Videos are every
    /// third post and the pattern is eight bricks; `lcm(3, 8) = 24`, so over
    /// any 24 posts the videos land on all eight slots equally and exactly
    /// half of them end up in squares. Fixing that upstream is impossible
    /// anyway: For You defaults to the `.trending` source, which re-sorts the
    /// corpus client-side, so no dataset can predict which slot a post will
    /// occupy. Slot shape is knowable only once the display order exists,
    /// which is here.
    ///
    /// **Stability.** Placement is a pure function of the absolute slot index,
    /// so an item never moves once placed and a later page cannot disturb an
    /// earlier one. That is what lets the caller keep expressing a page landing
    /// as an insert rather than a reload.
    ///
    /// Order is preserved within each SHAPE, not across all motion. Stills keep
    /// their sequence outright; videos keep theirs relative to others of the
    /// same shape, because portrait bricks are filled from portrait clips
    /// first. That is the deliberate cost of shape matching, and a small one
    /// once the mosaic is permuting order anyway.
    /// Nothing is dropped or duplicated: when motion posts outnumber the
    /// non-square slots the surplus spills into squares, and vice versa.
    public static func arrangedForMotion(
        _ posts: [GalleryPost], startingAt absoluteIndex: Int
    ) -> [GalleryPost] {
        guard !posts.isEmpty else { return [] }
        var motion = posts.filter(\.autoplaysInGrid)
        var stills = posts.filter { !$0.autoplaysInGrid }
        guard !motion.isEmpty, !stills.isEmpty else { return posts }
        // A block that covers only squares — slots 2…5 are four in a row — has
        // nowhere better to put a video, so leave the order alone. Without this
        // the passes below still shuffle stills to the front, which reorders
        // the page for no gain.
        var placed = [GalleryPost?](repeating: nil, count: posts.count)
        guard placed.indices.contains(where: { slotShape(at: absoluteIndex + $0).suitsMotion })
        else { return posts }
        // SHAPE-MATCHED first: a portrait video into a portrait brick, a
        // landscape one into a landscape brick.
        //
        // This is what keeps the zoom calm. `resizeAspectFill` crops by the
        // difference between the media's aspect and its container's, so a 9:16
        // clip sitting in a 2:1 brick shows a thin horizontal band and then
        // reveals the whole frame on the way to a 9:16 page — a large change,
        // continuous but jarring. Matching the brick to the media keeps the
        // tile's crop small, so the flight only has the page's own aspect to
        // travel.
        for shape in [GalleryPost.Shape.portrait, .landscape] {
            for offset in placed.indices
            where placed[offset] == nil && slotShape(at: absoluteIndex + offset).matches(shape) {
                guard let index = motion.firstIndex(where: { $0.shape == shape }) else { break }
                placed[offset] = motion.remove(at: index)
            }
        }
        // Then any motion left over takes whatever motion brick remains — a
        // mismatched brick still beats a square.
        for offset in placed.indices
        where placed[offset] == nil && slotShape(at: absoluteIndex + offset).suitsMotion {
            if motion.isEmpty { break }
            placed[offset] = motion.removeFirst()
        }
        for offset in placed.indices where !slotShape(at: absoluteIndex + offset).suitsMotion {
            if stills.isEmpty { break }
            placed[offset] = stills.removeFirst()
        }
        // Whatever is left over fills the holes in order — the surplus case.
        var remainder = motion + stills
        for offset in placed.indices where placed[offset] == nil {
            placed[offset] = remainder.removeFirst()
        }
        return placed.compactMap(\.self)
    }

    /// The Media mosaic: a repeating 8-item pattern on a 3-column unit grid,
    /// mixing 1×1 squares with 1×2 portrait and 2×1 landscape blocks. Two
    /// mirrored halves keep the rhythm organic instead of stripey:
    ///
    ///     ┌───┐┌───────┐      ┌───────┐┌───┐
    ///     │ 0 ││   1   │      │ 4 │ 5 ││   │
    ///     │   │├───┬───┤      ├───┴───┤│ 7 │
    ///     │   ││ 2 │ 3 │      │   6   ││   │
    ///     └───┘└───┴───┘      └───────┘└───┘
    ///
    /// Gutters come from uniform per-item insets (half the gutter each side),
    /// the one recipe that stays even across nested groups; the outer edges
    /// bleed the same half-gutter, invisible against full-bleed margins.
    public static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let inset = NSDirectionalEdgeInsets(
                top: gutter / 2, leading: gutter / 2, bottom: gutter / 2, trailing: gutter / 2
            )
            func item(width: CGFloat, height: CGFloat) -> NSCollectionLayoutItem {
                let item = NSCollectionLayoutItem(layoutSize: .init(
                    widthDimension: .fractionalWidth(width),
                    heightDimension: .fractionalHeight(height)
                ))
                item.contentInsets = inset
                return item
            }

            // Half A: portrait column leading, landscape + square pair trailing.
            let pairA = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(0.5)),
                subitems: [item(width: 0.5, height: 1), item(width: 0.5, height: 1)]
            )
            let stackA = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(2.0 / 3.0), heightDimension: .fractionalHeight(1)),
                subitems: [item(width: 1, height: 0.5), pairA]
            )
            let halfA = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(2.0 / 3.0)),
                subitems: [item(width: 1.0 / 3.0, height: 1), stackA]
            )

            // Half B: the mirror — square pair + landscape leading, portrait trailing.
            let pairB = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(0.5)),
                subitems: [item(width: 0.5, height: 1), item(width: 0.5, height: 1)]
            )
            let stackB = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(2.0 / 3.0), heightDimension: .fractionalHeight(1)),
                subitems: [pairB, item(width: 1, height: 0.5)]
            )
            let halfB = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(2.0 / 3.0)),
                subitems: [stackB, item(width: 1.0 / 3.0, height: 1)]
            )

            let pattern = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(4.0 / 3.0)),
                subitems: [halfA, halfB]
            )
            return NSCollectionLayoutSection(group: pattern)
        }
    }
}

/// The 1-column timeline shape (Activity, Short): rows self-size to
/// their content, with reading margins instead of the grid's full bleed.
public enum PostGridListLayout {
    public static func layout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(88)
            ))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(88)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 10
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            return section
        }
    }
}
