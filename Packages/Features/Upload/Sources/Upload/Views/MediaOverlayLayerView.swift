import UIKit

/// The layer a page's overlays are drawn in: one view per overlay, over the
/// picture.
///
/// ⚠️ **EMPTY FOR NOW, AND INERT.** The overlay slice (S9) fills it with one
/// item view per overlay, drawn from the same rasteriser the export uses, and
/// makes them take touches only while Text or Stickers is open. Until then it
/// holds nothing and passes every touch through — so the page's play/pause tap
/// and the canvas's paging behave exactly as they did without it.
@MainActor
final class MediaOverlayLayerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
