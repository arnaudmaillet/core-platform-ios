import DesignSystem
import UIKit

/// EXPERIMENTAL (#1681): save and repost UPRIGHT in the action column,
/// between the like pill and the sound bubble — what the post's toolbar
/// held, on the For You root where the tab bar has taken the bottom.
///
/// ```
///   ╭♥╮   the like pill
///   │900│
///   ╰─╯
///   ╭★╮   this capsule: save on top, repost under it
///   │⇄│
///   ╰─╯
///   [◉]   the sound bubble
/// ```
///
/// One Liquid Glass capsule (the system's, `UIGlassEffect`, made when the
/// view joins a window — as the column's other bubbles are), two glyphs
/// each one bubble square. Page chrome, not a bar: its controls are the
/// page's own.
final class SnapPostActionsCapsule: UIView {
    /// The capsule's height: two bubbles, one per action.
    @MainActor static var height: CGFloat { SnapActionColumn.bubbleSize * 2 }
    /// What the column grows by to hold it: the capsule and the gap above it.
    @MainActor static var columnExtent: CGFloat { height + SnapActionColumn.gap }

    var onSave: (() -> Void)?
    var onRepost: (() -> Void)?

    private let glass = UIVisualEffectView(effect: nil)
    let saveButton = UIButton(configuration: .plain())
    let repostButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        let symbols = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        for button in [saveButton, repostButton] {
            var config = UIButton.Configuration.plain()
            config.contentInsets = .zero
            config.baseForegroundColor = .label
            config.preferredSymbolConfigurationForImage = symbols
            button.configuration = config
            addSubview(button)
        }
        saveButton.configuration?.image = SaveStar.image(saved: false, symbols)
        saveButton.accessibilityLabel = "Save"
        saveButton.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .primaryActionTriggered)
        repostButton.configuration?.image = UIImage.symbol(named: PostActionSymbol.repost)
        repostButton.accessibilityLabel = "Repost"
        // ⚠️ No action yet: `PostComposer` takes no parent, so there is no
        // client path to publish a repost (the toolbar's same posture).
        repostButton.addAction(UIAction { [weak self] _ in self?.onRepost?() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The glass materializes on window attach, like the like pill's.
        if window != nil, glass.effect == nil { glass.effect = UIGlassEffect() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.width / 2
        glass.clipsToBounds = true
        let side = bounds.width
        saveButton.frame = CGRect(x: 0, y: 0, width: side, height: bounds.height / 2)
        repostButton.frame = CGRect(x: 0, y: bounds.height / 2, width: side, height: bounds.height / 2)
    }

    /// The star for the post on show: outline, or gold once saved.
    func setSaved(_ saved: Bool) {
        saveButton.configuration?.image = SaveStar.image(
            saved: saved, UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        saveButton.accessibilityLabel = saved ? "Saved" : "Save"
    }

    /// Off on a post no one may act on (#1409).
    func setActionsEnabled(_ enabled: Bool) {
        saveButton.isEnabled = enabled
        repostButton.isEnabled = enabled
    }
}
