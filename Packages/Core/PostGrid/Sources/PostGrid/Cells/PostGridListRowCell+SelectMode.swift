import DesignSystem
import UIKit

// The select mode on a list's card (the profile's Saved, the owner 2026-11-28)
extension PostGridListRowCell {
    // MARK: - The select mode (the profile's Saved, 2026-11-28)

    /// The circle's place and the card's slide, as on History's rows
    /// (`PostHistoryRowCell.selectionMarkSide` / `selectionMarkGap`, the
    /// owner 2026-11-28: "the same behaviour as History"): the circle at the
    /// row's leading edge, the gap after it, and the whole card slid by both.
    public static var selectionShift: CGFloat {
        PostHistoryRowCell.selectionMarkSide + PostHistoryRowCell.selectionMarkGap
    }

    /// The circle at the row's leading edge, centred on the card's height —
    /// where the slid card leaves room for it.
    func buildSelectionMark() {
        selectionMark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionMark)
        NSLayoutConstraint.activate([
            selectionMark.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectionMark.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            selectionMark.widthAnchor.constraint(equalToConstant: RowSelectionMark.side),
            selectionMark.heightAnchor.constraint(equalToConstant: RowSelectionMark.side)
        ])
    }

    /// The select mode is the list's editing, as on History's rows
    /// (`PostHistoryRowCell`, the owner 2026-11-28): the WHOLE CARD slides
    /// toward the trailing edge by `selectionShift` and the circle comes in
    /// at the leading edge, with History's spring; its far edge runs past
    /// the row, as a Mail row's does. The card also RESTS: its media, the
    /// author, the "...", the caption's links and Show more, the voice, the
    /// showcase and every action on the closing line stop taking touches,
    /// so a tap anywhere on the card reaches the list, which selects the
    /// row. Leaving slides it back and gives them back.
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
        let sign: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        let slide = { [card] in
            card.transform = selecting ? CGAffineTransform(translationX: Self.selectionShift * sign, y: 0) : .identity
        }
        let animated = window != nil && !MotionPreference.reducesMotion
        selectionMark.setShown(selecting, animated: animated, alongside: slide)
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

    /// How far the card is slid toward the trailing edge now. Tests.
    public var debugCardSlide: CGFloat { card.transform.tx }
}

/// A list card's selection circle: History's (`RowSelectionMark`), at the
/// row's leading edge on the page, where the slid card left room — nothing
/// under it, as on History's rows (the owner, 2026-11-28).
final class CardSelectionMark: UIView {
    let mark = RowSelectionMark()
    /// Whether it stands shown — the mode — whatever its fade is doing.
    private(set) var isShown = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: RowSelectionMark.side, height: RowSelectionMark.side))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        addSubview(mark)
        applyPlacement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        mark.bounds = bounds
        mark.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Fades and grows in (or out) with History's spring, `alongside` (the
    /// card's slide) in the same animation; at once when not `animated`.
    func setShown(_ shown: Bool, animated: Bool, alongside: @escaping () -> Void = {}) {
        guard shown != isShown else { return }
        isShown = shown
        let change = { self.applyPlacement(); alongside() }
        guard animated else { return change() }
        UIView.animate(
            springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState],
            animations: change
        )
    }

    private func applyPlacement() {
        alpha = isShown ? 1 : 0
        transform = isShown ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
    }
}
