import DesignSystem
import UIKit

/// The Discover list: full-width rows with pieces of the chaotic mosaic set
/// between them — the shape `MosaicChunkPlanner` decides, one section per
/// stretch (`DiscoverSegment`).
///
/// **Compositional, one section per stretch — and not a custom layout like the
/// feed mosaic's.** The rows SELF-SIZE (a caption, a carousel, a collapsed
/// band all change a row's height), which a compositional list does for free
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
/// none at the edges — so its outer tiles line up with the rows' words above
/// and below it, and its foot is one straight line (`MosaicChunk.frames`). Under
/// it, a "View all" footer.
///
/// `@MainActor` because the gutter is `ChaoticSliceLayout`'s, whose statics a
/// `UICollectionViewLayout` subclass isolates to the main actor.
@MainActor
public enum DiscoverListLayout {
    /// The element kind of a chunk's "View all" footer.
    public static let viewAllElementKind = "DiscoverListLayout.viewAll"
    /// The footer's height at `displayScale` (#2342): what its two gaps and
    /// the next post's line need — `DiscoverViewAllFooterView.preferredHeight`.
    ///
    /// It starts FLUSH WITH THE CHUNK'S FOOT (no inset between them): the
    /// words stand `titleTopInset` (12pt) under the tiles and the next
    /// post's line `gapBelowTitle` (16pt) under the words — the line a row
    /// draws half the rows' gap over its head, inside this footer. Shorter
    /// than 44pt at the default text size; the control's target still is
    /// 44pt, reaching up over the chunk's foot.
    public static func viewAllHeight(displayScale: CGFloat) -> CGFloat {
        DiscoverViewAllFooterView.preferredHeight(displayScale: displayScale)
    }
    /// The feed mosaic's gutter, so a chunk reads as a window onto the same
    /// wall — see `ChaoticSliceLayout.harmonisedGutter`.
    public static let gutter: CGFloat = ChaoticSliceLayout.harmonisedGutter
    /// The flat lists' air on each side of a line (#2289, #2342): 16pt from
    /// a line to the tiles under it, and from the tiles' foot to the line
    /// under them.
    public static let gapAtLine: CGFloat = 16
    /// Air between the last row of a run and the chunk (or the pairs) under
    /// it, and under a chunk without "View all" or a block of pairs: the
    /// line a row draws stands half the rows' gap
    /// (`PostGridListRowCell.separatorOffset`) outside it, so the tiles keep
    /// `gapAtLine` from that line — 20pt, the value it had when the rows
    /// were cards 10pt apart.
    public static let gapAboveChunk: CGFloat = gapAtLine + PostGridListLayout.rowSpacing / 2
    /// The top inset of the list's FIRST stretch when it is tiles or paired
    /// cards (#2342): what keeps them `gapAtLine` under the line a hero
    /// page's header draws half the rows' gap over its foot
    /// (`HeroHeaderView.drawsFootHairline`) — 4pt before, on the profile.
    ///
    /// Only the first: any other media stretch follows a run of rows, whose
    /// trailing `gapAboveChunk` already keeps it there, or another media
    /// stretch, whose spacing stays. Under a lead (For You's rows, a shelf
    /// and its list's title) or at a bare list's top, the same 12pt stands
    /// the tiles where a first row's words stand (its own padding). Not
    /// under a section's title: a title is not a line, and it keeps its own
    /// gap.
    public static let leadingMediaInset: CGFloat = gapAtLine - PostGridListLayout.rowSpacing / 2

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
    /// `PostGridListLayout.cardSpacing`, the cards' own gap. It was the list's
    /// row spacing when the rows were cards too; the rows are flat now
    /// (#2290) and the pairs keep the value (#2289 may revisit it).
    public static let pairGutter: CGFloat = PostGridListLayout.cardSpacing

    /// A paired card's height over its width: 3:4, the For You FOLLOWING
    /// card's own shape (`LeadRowMetrics.cardAspect`, which a Feed
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
    /// rows (and for any section the model does not know — a skeleton, a
    /// reload in flight — which is laid out as rows). `isPairs(section)` says
    /// a section is a block of paired half-width cards (see
    /// `DiscoverSegment.pairs`).
    ///
    /// `isTitled(section)` puts a title over the section — the first
    /// stretch of a titled group (the profile's History, #1344, by date);
    /// `showsViewAll` keeps or drops the chunks' "View all" footers, and
    /// `endsGroup(section)` spends the app's section gap after the last
    /// stretch of a group, before the next one's title.
    ///
    /// A run's rows stand `PostGridListLayout.rowInset` from the screen's
    /// edges, `rowSpacing` apart (#2243); the chunks and the pairs keep the
    /// page's margin, so a row's words and the tiles under it stand on one
    /// edge.
    public static func layout(
        chunk: @escaping @MainActor (Int) -> MosaicChunk?,
        isPairs: @escaping @MainActor (Int) -> Bool = { _ in false },
        isTitled: @escaping @MainActor (Int) -> Bool = { _ in false },
        endsGroup: @escaping @MainActor (Int) -> Bool = { _ in false },
        showsViewAll: @escaping @MainActor () -> Bool = { true }
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            let section = stretch(
                index, environment: environment, chunk: chunk, isPairs: isPairs, showsViewAll: showsViewAll()
            )
            // A media stretch first in the list stands `gapAtLine` under the
            // header's line (#2342). Its trailing gap is unchanged.
            if index == 0, !isTitled(index), isPairs(index) || chunk(index) != nil {
                var insets = section.contentInsets
                insets.top = leadingMediaInset
                section.contentInsets = insets
            }
            if endsGroup(index) {
                var insets = section.contentInsets
                insets.bottom = PostGridListLayout.sectionGap(traits: environment.traitCollection)
                section.contentInsets = insets
            }
            if isTitled(index) {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                    elementKind: PostGridListLayout.headerElementKind,
                    alignment: .top
                )
                // ⚠️ NOT PINNED: a group spans several sections, so a pinned
                // header would leave with its first stretch anyway — and the
                // host names the group in its bar once the title has gone
                // under it (the Messages inbox's rule, #1301).
                header.zIndex = 2
                // A run's title stays on the page's margin although the run's
                // own insets narrow for its rows (#2243); a chunk's and a
                // block of pairs' stand on the margin already.
                let isRun = chunk(index) == nil && !isPairs(index)
                header.contentInsets = isRun ? PostGridListLayout.headerInsets : .zero
                section.boundarySupplementaryItems.insert(header, at: 0)
            }
            return section
        }
    }

    /// One stretch's section: a run of rows, a block of pairs, or a chunk.
    private static func stretch(
        _ index: Int,
        environment: any NSCollectionLayoutEnvironment,
        chunk: @MainActor (Int) -> MosaicChunk?,
        isPairs: @MainActor (Int) -> Bool,
        showsViewAll: Bool
    ) -> NSCollectionLayoutSection {
        do {
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
                let side = PostGridListLayout.rowInset
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: 0, leading: side, bottom: gapAboveChunk, trailing: side
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
                top: 0, leading: margin, bottom: showsViewAll ? 0 : gapAboveChunk, trailing: margin
            )
            section.supplementariesFollowContentInsets = true
            if showsViewAll {
                let footer = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(viewAllHeight(displayScale: scale))
                    ),
                    elementKind: viewAllElementKind,
                    alignment: .bottom
                )
                // Over the tiles: the control's 44pt target reaches up over
                // the chunk's foot when the footer is shorter (#2342), and a
                // tile under it would take the touch first.
                footer.zIndex = 1
                section.boundarySupplementaryItems = [footer]
            }
            return section
        }
    }

    /// A block of paired cards: rows of two half-width cards, `pairGutter`
    /// between them, on the page's margin — so a pair's outer edges line up
    /// with the rows' words above and below it.
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
        section.interGroupSpacing = pairGutter
        // The gap to whatever follows on the TRAILING edge, as a run's — see
        // the rows' section above.
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: margin, bottom: gapAboveChunk, trailing: margin
        )
        return section
    }
}
