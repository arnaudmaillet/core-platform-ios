import DesignSystem
import UIKit

/// The album before the library has answered: a grid of bones laid out
/// exactly where the tiles will be.
///
/// ⚠️ **IT REPLACES A SPINNER, AND THE REASON IS THE CHARTER'S P8.** A large
/// activity indicator centred in an empty sheet says "something is happening"
/// and nothing else; a grid of tiles says what is about to be here, and when
/// the photographs land they land INTO it — same gutter, same tile side, same
/// corner — so the swap moves nothing. The wait it stands in for is not
/// always ours (the system's permission sheet can be up in front of it), and
/// a shape the viewer recognises reads better through that sheet than a wheel.
///
/// Manual layout rather than a collection view: there is nothing to scroll,
/// nothing to select, and the bones are cheap. Enough rows are made to cover
/// the view's height and no more; a one-row sheet at rest shows one row, the
/// expanded sheet shows them all.
final class MediaAlbumSkeletonView: UIView {
    private var bones: [SkeletonBoneView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutter = MediaAlbumPageView.gutter
        let columns = Int(MediaAlbumPageView.columns)
        let side = MediaAlbumPageView.tileSide(forWidth: bounds.width)
        guard side > 0, bounds.height > 0 else { return }
        // The top inset is the picker's notice reserve at most; the bones
        // start where the grid's first row starts, under the bar.
        let top = safeAreaInsets.top + gutter
        let rows = Int(((bounds.height - top) / (side + gutter)).rounded(.up))
        let needed = max(0, rows * columns)
        while bones.count < needed {
            let bone = SkeletonBoneView(rounding: .fixed(MediaPickerGridCell.Metrics.corner))
            addSubview(bone)
            bones.append(bone)
        }
        while bones.count > needed {
            bones.removeLast().removeFromSuperview()
        }
        for (index, bone) in bones.enumerated() {
            let column = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            bone.frame = CGRect(
                x: gutter + column * (side + gutter),
                y: top + row * (side + gutter),
                width: side, height: side
            )
        }
    }
}
