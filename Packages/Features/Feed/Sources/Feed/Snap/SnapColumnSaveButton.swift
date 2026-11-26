import DesignSystem
import ThreadKit
import UIKit

/// The action column's save star under `-snap-layout-v2` (#2408): the
/// toolbar's ☆ moved into the column, in a bubble of the column's size. The
/// star is `SaveStar`'s, the one contract (#1190): an outline in the column's
/// ink at rest, filled in the save gold once saved. No count.
///
/// The button draws no glass: the column's one glass (`SnapGlassColumn`)
/// draws its bubble and frames it on its station, as it does the like pill
/// and the sound.
final class SnapColumnSaveButton: UIButton {
    /// A tap: the host toggles the post's saved state and draws it back
    /// (`setSaved`).
    var onTap: (() -> Void)?

    /// What the star draws now.
    private(set) var isSaved = false

    /// The star's size: the share glyph's beside it (`SnapSoundBubbleButton`),
    /// so the two bubbles read as one family.
    static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        var face = UIButton.Configuration.plain()
        face.baseForegroundColor = .label
        face.contentInsets = .zero
        configuration = face
        accessibilityIdentifier = SnapFooterToolbar.ID.save
        maximumContentSizeCategory = .large
        showsLargeContentViewer = true
        scalesLargeContentImage = true
        applyFace()
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the post's saved state: the star's fill and its label.
    func setSaved(_ saved: Bool) {
        guard saved != isSaved else { return }
        isSaved = saved
        applyFace()
    }

    private func applyFace() {
        configuration?.image = SaveStar.image(saved: isSaved, Self.glyphConfiguration)
        // "Save" and "Saved" are different offers, as on the toolbar's star.
        accessibilityLabel = isSaved ? "Saved" : "Save"
        largeContentTitle = accessibilityLabel
    }
}
