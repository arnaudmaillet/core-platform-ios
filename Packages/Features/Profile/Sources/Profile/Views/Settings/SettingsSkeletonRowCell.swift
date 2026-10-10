import DesignSystem
import UIKit

/// One loading row of a Settings list (charter P8/P9): the row it stands for,
/// redacted. The cell is handed the SAME list content configuration the real
/// row will wear — a sample title, a sample subtitle, the symbol — renders it
/// with clear ink, and lays a shimmering bone over each of its parts through
/// `UIListContentView`'s layout guides.
///
/// Built this way, the skeleton's row heights, insets and Dynamic Type sizing
/// are the real row's by construction, not by copied constants: when the
/// content cross-fades in, nothing moves. The sample strings only decide how
/// wide each bone is.
final class SettingsSkeletonRowCell: UICollectionViewListCell {
    private let listView = UIListContentView(configuration: .cell())
    private let imageBone = SkeletonBoneView(rounding: .fixed(6))
    private let textBone = SkeletonBoneView(rounding: .capsule)
    private let secondaryBone = SkeletonBoneView(rounding: .capsule)
    private var boneConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        listView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: contentView.topAnchor),
            listView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        for bone in [imageBone, textBone, secondaryBone] {
            bone.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bone)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `content` — the real row's configuration with sample text — as
    /// bones.
    func configure(redacting content: UIListContentConfiguration) {
        var ink = content
        ink.textProperties.color = .clear
        ink.secondaryTextProperties.color = .clear
        ink.imageProperties.tintColor = .clear
        listView.configuration = ink
        accessories = []

        NSLayoutConstraint.deactivate(boneConstraints)
        boneConstraints = []
        place(imageBone, over: content.image == nil ? nil : listView.imageLayoutGuide, filling: true)
        place(textBone, over: content.text == nil ? nil : listView.textLayoutGuide, filling: false)
        place(secondaryBone, over: content.secondaryText == nil ? nil : listView.secondaryTextLayoutGuide, filling: false)
        NSLayoutConstraint.activate(boneConstraints)
    }

    /// A text bone spans its line's width at most of its height (a line box
    /// carries leading the glyphs don't fill); the image bone fills its slot.
    private func place(_ bone: SkeletonBoneView, over guide: UILayoutGuide?, filling: Bool) {
        guard let guide else {
            bone.isHidden = true
            return
        }
        bone.isHidden = false
        boneConstraints += [
            bone.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bone.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bone.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            bone.heightAnchor.constraint(equalTo: guide.heightAnchor, multiplier: filling ? 1 : 0.6)
        ]
    }
}

extension UICollectionView {
    /// Leaves a skeleton for its content (charter P10): `apply` swaps the
    /// rows inside one cross-dissolve of the list, at the settled skeleton
    /// fade duration, so the bones melt into the values instead of popping.
    /// Off screen there is nothing to see, and the swap is immediate.
    func crossfadeFromSkeleton(_ apply: @escaping () -> Void) {
        guard window != nil else {
            apply()
            return
        }
        UIView.transition(with: self, duration: UIView.skeletonFadeDuration, options: .transitionCrossDissolve, animations: apply)
    }
}
