import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The dress: a list's row, or a shelf's card (#2243, #2290)
extension PostGridListRowCell {
    // MARK: - The dress: a list's row, or a shelf's card (#2243, #2290)

    /// What this cell is drawn as.
    ///
    /// ⚠️ TWO DRESSES, ONE CELL — and not the A/B #2290 removed. The post
    /// lists draw every text post as a ROW (no ground, no corner, no edge, a
    /// hairline between posts and a wash under a press); a horizontal
    /// shelf's text card (`PostShelfSection`) is this same cell dressed as a
    /// CARD, and the window's stand-in (`RevealDismissCardView`) builds one
    /// too. The list's page sets `.row`; everything else keeps the card.
    public enum Dress: Equatable, Sendable {
        /// A shelf's card: the card's tone, its corner and its edge.
        case card
        /// A post list's row (#2243): the page shows through.
        case row
    }



    /// The hairline sits mid-gap between two rows, outside the row's bounds:
    /// half the rows' spacing below its foot (and above its head).
    public static var separatorOffset: CGFloat { PostGridListLayout.rowSpacing / 2 }



    func buildRowChrome() {
        for rule in [topRule, bottomRule] {
            rule.backgroundColor = .separator
            rule.isUserInteractionEnabled = false
            rule.isHidden = true
            addSubview(rule)
        }
        pressWash.backgroundColor = .label
        pressWash.alpha = 0
        pressWash.isUserInteractionEnabled = false
        insertSubview(pressWash, at: 0)
    }

    /// The dress for the current traits: a card's tone, corner and edge, or
    /// none of them on a row.
    func applyDress() {
        let row = dress == .row
        card.backgroundColor = row ? .clear : Self.cardFillColor
        card.layer.cornerRadius = row ? .zero : Self.cardCornerRadius
        card.layer.borderWidth = row ? .zero : Surface.hairline(for: traitCollection)
        card.layer.borderColor = Surface.cardEdge.resolvedColor(with: traitCollection).cgColor
        if showsCarousel {
            mediaView.backgroundColor = rowGround
            carousel?.backgroundColor = rowGround
        }
        if !row { pressWash.alpha = 0 }
        setNeedsLayout()
    }
}
