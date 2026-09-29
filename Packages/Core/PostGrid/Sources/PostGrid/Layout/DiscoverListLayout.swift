import UIKit

/// The Discover list: full-width cards with pieces of the chaotic mosaic set
/// between them — the shape `MosaicChunkPlanner` decides, one section per
/// stretch (`DiscoverSegment`).
///
/// **Compositional, one section per stretch — and not a custom layout like the
/// feed mosaic's.** The cards SELF-SIZE (a caption, a carousel, a collapsed
/// band all change a card's height), which a compositional list does for free
/// and a custom `UICollectionViewLayout` would have to re-implement through
/// preferred-attributes invalidation. The reason the feed mosaic could not be
/// compositional does not apply here: a chunk's tiling is seeded by its
/// ORDINAL, which the page's model already carries, so the section provider
/// is handed the finished chunk rather than having to derive a seed from an
/// index it is not given. The cost — `IndexPath`s that span sections — stays
/// inside `ForYouGridPage`, which already translated between flat indices and
/// index paths for its "New"/"Recent" split.
///
/// A chunk section is a single custom group: the chunk's own frames, at the
/// width the list's margins leave, with the mosaic's gutter between tiles and
/// none at the edges — so its outer tiles line up with the cards above and
/// below it, and its foot is one straight line (`MosaicChunk.frames`). Under
/// it, a "View all" footer.
///
/// `@MainActor` because the gutter is `ChaoticSliceLayout`'s, whose statics a
/// `UICollectionViewLayout` subclass isolates to the main actor.
@MainActor
public enum DiscoverListLayout {
    /// The element kind of a chunk's "View all" footer.
    public static let viewAllElementKind = "DiscoverListLayout.viewAll"
    /// The footer's height — the sound sheet's "View all" row's.
    public static let viewAllHeight: CGFloat = 44
    /// The feed mosaic's gutter, so a chunk reads as a window onto the same
    /// wall — see `ChaoticSliceLayout.harmonisedGutter`.
    public static let gutter: CGFloat = ChaoticSliceLayout.harmonisedGutter
    /// Air between the last card of a run and the chunk under it: more than
    /// two cards keep between them, so the chunk reads as a shelf of its own
    /// rather than as one more card.
    public static let gapAboveChunk: CGFloat = 20
    /// Below the "View all" footer, before the next card. The footer's own
    /// height already carries most of the air; this is the remainder.
    public static let gapBelowChunk: CGFloat = 4

    /// `chunk(section)` answers the chunk a section holds, or nil for a run of
    /// cards (and for any section the model does not know — a skeleton, a
    /// reload in flight — which is laid out as cards).
    public static func layout(
        chunk: @escaping @MainActor (Int) -> MosaicChunk?
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            let margin = PostGridListLayout.sideMargin
            guard let chunk = chunk(index) else {
                let item = NSCollectionLayoutItem(layoutSize: .init(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(88)
                ))
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(88)),
                    subitems: [item]
                )
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = PostGridListLayout.rowSpacing
                // The gap to whatever follows goes on the TRAILING edge of
                // this section — `PostGridListLayout` measured why a leading
                // inset on the next one misbehaves.
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: 0, leading: margin, bottom: gapAboveChunk, trailing: margin
                )
                return section
            }
            let width = max(0, environment.container.effectiveContentSize.width - margin * 2)
            let scale = environment.traitCollection.displayScale
            let height = chunk.height(forWidth: width, pixelScale: scale)
            let frames = chunk.frames(width: width, gutter: gutter, pixelScale: scale)
            let group = NSCollectionLayoutGroup.custom(
                layoutSize: .init(widthDimension: .absolute(width), heightDimension: .absolute(height))
            ) { _ in
                frames.map { NSCollectionLayoutGroupCustomItem(frame: $0) }
            }
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: margin, bottom: gapBelowChunk, trailing: margin
            )
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(viewAllHeight)
                    ),
                    elementKind: viewAllElementKind,
                    alignment: .bottom
                )
            ]
            return section
        }
    }
}
