import DesignSystem
import UIKit

// The select mode on a list's card (the profile's Saved, the owner 2026-11-28)
extension PostGridListRowCell {
    // MARK: - The select mode (the profile's Saved, 2026-11-28)

    /// How far the circle stands in from the card's top and trailing edges.
    public static let selectionMarkInset: CGFloat = 12

    /// The circle over the card's top-trailing corner, above everything the
    /// card draws, its media included.
    func buildSelectionMark() {
        selectionMark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionMark)
        NSLayoutConstraint.activate([
            selectionMark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.selectionMarkInset),
            selectionMark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.selectionMarkInset),
            selectionMark.widthAnchor.constraint(equalToConstant: RowSelectionMark.side),
            selectionMark.heightAnchor.constraint(equalToConstant: RowSelectionMark.side)
        ])
    }

    /// The select mode is the list's editing, as on History's rows
    /// (`PostHistoryRowCell`): the card does not slide — the circle comes
    /// over its corner — and the WHOLE CARD RESTS. Its media (the carousel's
    /// tap, pan and hold), the author, the "...", the caption's links and
    /// Show more, the voice, the showcase and every action on the closing
    /// line stop taking touches, so a tap anywhere on the card reaches the
    /// list, which selects the row. Leaving gives them back.
    func applySelectMode(_ state: UICellConfigurationState) {
        let selecting = state.isEditing
        card.isUserInteractionEnabled = !selecting
        let checked = selecting && state.isSelected
        selectionMark.mark.setChecked(checked, animated: window != nil && selecting)
        // While selecting, the card is ONE element for VoiceOver — its
        // words, a button the list selects, `.selected` once chosen — and
        // its parts rest, as they do under a finger.
        isAccessibilityElement = selecting
        accessibilityTraits = selecting ? (checked ? [.button, .selected] : .button) : .none
        defer { refreshSelectionLabel() }
        guard selecting != selectionMark.isShown else { return }
        // A caption selection in progress is the post's, not the mode's.
        if selecting { endCaptionSelection() }
        // Laid out first, outside any animation: the circle is where it
        // belongs before it fades and grows in — never grown from the
        // corner by a pass inside the list's own transition.
        UIView.performWithoutAnimation { contentView.layoutIfNeeded() }
        selectionMark.setShown(selecting, animated: window != nil)
    }

    /// The card's words for VoiceOver while selecting, nil otherwise —
    /// re-read whenever the caption changes, so a recycled card never
    /// speaks the last post's.
    func refreshSelectionLabel() {
        accessibilityLabel = selectionMark.isShown ? (fullCaption.isEmpty ? "Post" : fullCaption) : nil
    }

    /// Whether the circle shows, and checked. Tests.
    public var debugSelectionMark: (shown: Bool, checked: Bool) {
        (selectionMark.isShown && selectionMark.alpha > 0, selectionMark.mark.isChecked)
    }

    /// The circle's frame in the cell's space, as laid out. Tests.
    public var debugSelectionMarkFrame: CGRect {
        layoutIfNeeded()
        return selectionMark.convert(selectionMark.bounds, to: self)
    }

    /// Whether the card takes touches now. Tests.
    public var debugCardTakesTouches: Bool { card.isUserInteractionEnabled }
}

/// A list card's selection circle: History's (`RowSelectionMark`) on a soft
/// ground and a light shadow, since it stands over the media as often as
/// over the page — the empty circle in `.tertiaryLabel` alone vanished on a
/// bright photograph. The ground sits inside the ring, so on a row's page
/// it is the page; under the check it is the tick's ink.
final class CardSelectionMark: UIView {
    /// The ground's side: inside the ring's stroke, so its edge never shows
    /// past the circle.
    static let groundSide: CGFloat = 18

    let mark = RowSelectionMark()
    private let ground = UIView()
    /// Whether it stands shown — the mode — whatever its fade is doing.
    private(set) var isShown = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: RowSelectionMark.side, height: RowSelectionMark.side))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        ground.backgroundColor = .systemBackground.withAlphaComponent(0.85)
        ground.layer.cornerRadius = Self.groundSide / 2
        ground.isUserInteractionEnabled = false
        addSubview(ground)
        addSubview(mark)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        applyPlacement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        mark.bounds = bounds
        mark.center = middle
        ground.bounds = CGRect(x: 0, y: 0, width: Self.groundSide, height: Self.groundSide)
        ground.center = middle
        // The shadow of the circle, not of the layer's content: no
        // offscreen pass per card.
        let ring = bounds.insetBy(dx: 2, dy: 2)
        layer.shadowPath = UIBezierPath(ovalIn: ring).cgPath
    }

    /// Fades and grows in (or out) with History's spring, unless the viewer
    /// reduces motion.
    func setShown(_ shown: Bool, animated: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        guard animated, !MotionPreference.reducesMotion else { return applyPlacement() }
        UIView.animate(
            springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState],
            animations: applyPlacement
        )
    }

    private func applyPlacement() {
        alpha = isShown ? 1 : 0
        transform = isShown ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
    }
}
