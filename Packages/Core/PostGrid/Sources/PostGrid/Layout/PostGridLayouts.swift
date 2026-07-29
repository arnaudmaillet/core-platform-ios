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
