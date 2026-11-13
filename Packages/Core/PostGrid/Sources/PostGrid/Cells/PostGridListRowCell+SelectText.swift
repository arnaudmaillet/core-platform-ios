import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// Select Text (#1498 §4)
extension PostGridListRowCell {
    // MARK: - Select Text (#1498 §4)


    /// Whether Select Text can act here: a caption is drawn, and it can show
    /// whole — a card of a fixed height (`fixedCaptionLines`) cuts its own
    /// tail, so a selection there would select words nobody sees.
    public var canSelectCaption: Bool {
        !fullCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && fixedCaptionLines == nil && !captionLabel.isHidden
    }

    /// Selects the whole caption with the system's handles and edit menu
    /// (`SelectableTextOverlay`, as comments and messages do). A truncated
    /// caption is revealed first, so the selection is the caption itself,
    /// never its "… Show more".
    public func beginCaptionSelection() {
        guard canSelectCaption else { return }
        if !isCaptionExpanded, showMoreRange != nil {
            revealTapped()
            layoutIfNeeded()
        }
        let overlay = captionSelection ?? SelectableTextOverlay(label: captionLabel, host: card)
        captionSelection = overlay
        overlay.begin()
    }

    public func endCaptionSelection() {
        captionSelection?.end()
    }

    public var isSelectingCaption: Bool { captionSelection?.isActive ?? false }

    /// Whether a touch on `view` belongs to the selection in progress.
    public func captionSelectionContains(_ view: UIView?) -> Bool {
        captionSelection?.contains(view) ?? false
    }

    func revealTapped() {
        guard !isCaptionExpanded else { return }
        isCaptionExpanded = true
        captionLabel.numberOfLines = 0
        showMoreRange = nil
        captionLabel.attributedText = Self.plain(fullCaption, font: captionLabel.font)
        onRevealFullCaption?()
    }

    @objc func captionTapped() {
        revealTapped()
    }

    /// ⚠️ The recognizer must REFUSE every touch that is not on the affordance,
    /// not merely ignore it.
    ///
    /// A gesture recognizer on the label consumes taps on the label whether or
    /// not its action does anything, so a recognizer that simply returned early
    /// for a miss would make the caption — the largest thing on the card —
    /// stop opening the post. Refusing at `shouldBegin` leaves the touch to the
    /// collection view's own selection.
    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let range = showMoreRange, !isCaptionExpanded else { return false }
        return Self.characterIndex(
            at: gesture.location(in: captionLabel), in: captionLabel
        ).map { NSLocationInRange($0, range) } ?? false
    }

    /// Which character of the label's text is under `point`, laid out exactly
    /// as the label lays it out.
    ///
    /// TextKit rather than arithmetic on line heights: the affordance is the
    /// tail of a wrapped line, so its position depends on where the line broke,
    /// which only a real layout knows. The container is configured to match the
    /// label — zero padding, the label's line-break mode and line cap — because
    /// a container that differs in any of those breaks the text somewhere else
    /// and hit-tests a different string.
    ///
    /// Returns nil when the point is outside the laid-out glyphs, so a tap in
    /// the empty tail of the last line is a miss rather than the nearest
    /// character.
    private static func characterIndex(at point: CGPoint, in label: UILabel) -> Int? {
        guard let attributed = label.attributedText, attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = label.lineBreakMode
        container.maximumNumberOfLines = label.numberOfLines
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let index = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        // `glyphIndex(for:)` clamps to the nearest glyph, so a point past the
        // end of a line answers with that line's last character. Rejecting a
        // point outside the glyph's own rect is what turns that clamp back into
        // a miss.
        let glyphRect = manager.boundingRect(
            forGlyphRange: NSRange(location: index, length: 1), in: container
        )
        guard glyphRect.contains(point) else { return nil }
        return manager.characterIndexForGlyph(at: index)
    }
}
