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
    /// The footer's height — a control's 44pt, which is its hit target.
    ///
    /// It starts FLUSH WITH THE CHUNK'S FOOT (no inset between them) and its
    /// control draws its title at its top (`DiscoverViewAllFooterView`), so
    /// the words sit just under the tiles they belong to and the rest of the
    /// 44pt is the air before the next card — no separate gap below.
    public static let viewAllHeight: CGFloat = 44
    /// The feed mosaic's gutter, so a chunk reads as a window onto the same
    /// wall — see `ChaoticSliceLayout.harmonisedGutter`.
    public static let gutter: CGFloat = ChaoticSliceLayout.harmonisedGutter
    /// Air between the last card of a run and the chunk under it: more than
    /// two cards keep between them, so the chunk reads as a shelf of its own
    /// rather than as one more card.
    public static let gapAboveChunk: CGFloat = 20

    /// The element kind of the list's LEADING header — whatever a host puts
    /// above the first stretch (For You's Friends and Following rows).
    ///
    /// A layout-wide boundary item rather than a section of its own, on
    /// purpose: every index path, chunk plan and flight on the list counts in
    /// its SECTIONS, and a header that scrolls with them changes none of that
    /// arithmetic.
    public static let leadElementKind = "DiscoverListLayout.lead"

    /// Sizes the leading header — zero removes it. Setting the configuration
    /// is what invalidates the layout, so this is also how a host that grew
    /// or shrank its header says so.
    public static func setLeadHeight(_ height: CGFloat, on layout: UICollectionViewCompositionalLayout) {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = layout.configuration.scrollDirection
        configuration.interSectionSpacing = layout.configuration.interSectionSpacing
        if height > 0 {
            configuration.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    elementKind: leadElementKind,
                    alignment: .top
                )
            ]
        }
        layout.configuration = configuration
    }

    /// The gap between the two cards of a pair, and between two rows of pairs:
    /// the list's own row spacing, so a block reads as the same list folded
    /// in two rather than as a grid of its own.
    public static let pairGutter: CGFloat = PostGridListLayout.rowSpacing

    /// A paired card's height over its width: 3:4, the For You FOLLOWING
    /// card's own shape (`ForYouRailsView.Metrics.cardAspect`, which a Feed
    /// test pins to this) — a paired card IS that card, at half the list's
    /// width. Every paired post is taller than 4:5, so the box only ever crops
    /// height, and one fixed box is what makes a pair one row.
    public static let pairCardHeightRatio: CGFloat = 4.0 / 3.0

    /// One half-width card's width in a list `containerWidth` wide.
    public static func pairCardWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, (containerWidth - PostGridListLayout.sideMargin * 2 - pairGutter) / 2)
    }

    /// One half-width card's size in a list `containerWidth` wide, on whole
    /// points.
    public static func pairCardSize(containerWidth: CGFloat) -> CGSize {
        let width = pairCardWidth(containerWidth: containerWidth)
        return CGSize(width: width, height: (width * pairCardHeightRatio).rounded())
    }

    /// `chunk(section)` answers the chunk a section holds, or nil for a run of
    /// cards (and for any section the model does not know — a skeleton, a
    /// reload in flight — which is laid out as cards). `isPairs(section)` says
    /// a section is a block of paired half-width cards (see
    /// `DiscoverSegment.pairs`).
    public static func layout(
        chunk: @escaping @MainActor (Int) -> MosaicChunk?,
        isPairs: @escaping @MainActor (Int) -> Bool = { _ in false }
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            let margin = PostGridListLayout.sideMargin
            if isPairs(index) {
                return pairsSection(environment: environment)
            }
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
            // Nothing between the chunk's foot and its footer; the footer
            // spans the chunk's width, margin to margin, so a control on its
            // trailing edge ends where the tiles do.
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: margin, bottom: 0, trailing: margin
            )
            section.supplementariesFollowContentInsets = true
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

    /// A block of paired cards: rows of two half-width cards, `pairGutter`
    /// between them, on the cards' own margins — so a pair's outer edges line
    /// up with the full-width cards above and below it.
    ///
    /// FIXED sizes, not self-sizing: a paired card is a Following card, all
    /// picture with its words over it, so its size is a function of the width
    /// alone (`pairCardSize`) and a row's two feet are one line by
    /// construction.
    private static func pairsSection(
        environment: any NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let margin = PostGridListLayout.sideMargin
        let size = pairCardSize(containerWidth: environment.container.effectiveContentSize.width)
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(size.width),
            heightDimension: .absolute(size.height)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(size.height)),
            subitems: [item, item]
        )
        group.interItemSpacing = .fixed(pairGutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = PostGridListLayout.rowSpacing
        // The gap to whatever follows on the TRAILING edge, as a run's — see
        // the cards' section above.
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: margin, bottom: gapAboveChunk, trailing: margin
        )
        return section
    }
}
