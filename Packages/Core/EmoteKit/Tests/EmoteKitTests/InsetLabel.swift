import UIKit
@testable import EmoteKit

/// Draws its text 20 pt in from the left, as a padded pill does.
final class InsetLabel: EmoteLabel {
    static let inset: CGFloat = 20

    override func drawText(in rect: CGRect) {
        super.drawText(in: emoteTextRect(forBounds: rect))
    }

    override func emoteTextRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: UIEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: 0))
    }
}
