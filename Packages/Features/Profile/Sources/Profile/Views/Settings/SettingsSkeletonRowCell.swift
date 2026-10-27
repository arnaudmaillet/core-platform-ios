import DesignSystem
import UIKit

/// One loading row of a Settings list (charter P8/P9): the row it stands for,
/// redacted — DesignSystem's `SkeletonRowConfiguration` (#1769), worn by a
/// list cell. See there for how the bones take the real row's metrics.
final class SettingsSkeletonRowCell: UICollectionViewListCell {
    /// Shows `content` — the real row's configuration with sample text — as
    /// bones.
    func configure(redacting content: UIListContentConfiguration) {
        contentConfiguration = SkeletonRowConfiguration(redacting: content)
        accessories = []
    }
}
