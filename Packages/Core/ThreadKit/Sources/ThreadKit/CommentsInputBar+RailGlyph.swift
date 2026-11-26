import DesignSystem
import UIKit

/// The rail slot's glyph faces: Share, the repost, the bookmark, the way back.
extension CommentsInputBar {
    /// `button`'s configuration wearing `symbol` (#2581): the column's 15 pt,
    /// and Share as the page's own Share bubble draws it (`ShareBubbleGlyph`):
    /// the heart's size by its drawn ink, centred by its ink's centre of mass
    /// through the glass's insets. Every other face sits at the glass's own
    /// insets.
    static func railGlyph(_ symbol: String, of button: UIButton) -> UIButton.Configuration? {
        guard var configuration = button.configuration else { return nil }
        let resting = UIButton.Configuration.glass().contentInsets
        guard symbol == shareRailSymbol, let share = ShareBubbleGlyph.image() else {
            configuration.image = UIImage.symbol(named: symbol, configuration: glyphConfiguration)
            configuration.contentInsets = resting
            return configuration
        }
        configuration.image = share
        configuration.contentInsets = ShareBubbleGlyph.contentInsets(
            resting, for: share, direction: button.effectiveUserInterfaceLayoutDirection
        )
        return configuration
    }
}
