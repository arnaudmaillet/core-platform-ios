import DesignSystem
import UIKit

/// The Rows page's layout (#2170, the profile's History): one post per row,
/// full width, each group its own section — the list's own sections
/// (`NSCollectionLayoutSection.list`), so a row takes the list's trailing
/// swipe.
///
/// - The content inset is `Spacing.lg` both sides; rows stand `Spacing.sm`
///   apart; no separators, no background — the page's ground shows between.
/// - A titled section wears the page's header (`PostGridListLayout
///   .headerElementKind`), NOT pinned — Discover's groups' rule: the host
///   names the group in its bar once the title has gone under it (#1301).
/// - A group followed by another ends on the app's section gap, as
///   Discover's groups do (`PostGridListLayout.sectionGap`).
public enum PostGridRowsLayout {
    /// Between two rows (#2170).
    public static let rowSpacing: CGFloat = Spacing.sm
    /// Either side of the rows (#2170).
    public static let sideMargin: CGFloat = Spacing.lg

    /// `isTitled(section)` puts the group's title over it; `endsGroup(section)`
    /// spends the section gap after it; `trailingSwipe(indexPath)` is the
    /// row's swipe, nil for none.
    public static func layout(
        isTitled: @escaping @MainActor (Int) -> Bool,
        endsGroup: @escaping @MainActor (Int) -> Bool,
        trailingSwipe: @escaping @MainActor (IndexPath) -> UISwipeActionsConfiguration?
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            configuration.headerMode = .none
            configuration.footerMode = .none
            configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
                MainActor.assumeIsolated { trailingSwipe(indexPath) }
            }
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            section.interGroupSpacing = rowSpacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: sideMargin,
                bottom: endsGroup(index) ? PostGridListLayout.sectionGap(traits: environment.traitCollection) : 0,
                trailing: sideMargin
            )
            if isTitled(index) {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                    elementKind: PostGridListLayout.headerElementKind,
                    alignment: .top
                )
                header.zIndex = 2
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }
}
