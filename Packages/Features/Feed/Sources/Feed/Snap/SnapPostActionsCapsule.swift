import DesignSystem
import UIKit

/// (#1681): save and share UPRIGHT in the action column,
/// between the like pill and the sound bubble — what the post's toolbar
/// held, on the For You root where the tab bar has taken the bottom.
///
/// ```
///   ╭♥╮   the like pill
///   │900│
///   ╰─╯
///   ╭★╮   this capsule: save on top, share under it (#1710: it was
///   │↪│   repost)
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
    /// Share — the share sheet (#1710).
    var onShare: (() -> Void)?

    private let glass = UIVisualEffectView(effect: nil)
    let saveButton = UIButton(configuration: .plain())
    let shareButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ⚠️ INTERACTIVE, like the like pill's `.glass()` button (#1703, the
        // owner): the buttons ride in the glass's content so the touch that
        // fires them is the glass's too, and it answers it as UIKit's does.
        addSubview(glass)
        let symbols = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        for button in [saveButton, shareButton] {
            var config = UIButton.Configuration.plain()
            config.contentInsets = .zero
            config.baseForegroundColor = .label
            config.preferredSymbolConfigurationForImage = symbols
            button.configuration = config
            glass.contentView.addSubview(button)
        }
        saveButton.configuration?.image = SaveStar.image(saved: false, symbols)
        saveButton.accessibilityLabel = "Save"
        saveButton.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .primaryActionTriggered)
        shareButton.configuration?.image = UIImage.symbol(named: PostActionSymbol.share)
        shareButton.accessibilityLabel = "Share"
        shareButton.addAction(UIAction { [weak self] _ in self?.onShare?() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the capsule wears its own glass — off in the page's action
    /// column (#1872), which is one glass for all its bubbles.
    var drawsGlass = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The glass materializes on window attach, like the like pill's.
        if drawsGlass, window != nil, glass.effect == nil {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            glass.effect = effect
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.width / 2
        glass.clipsToBounds = true
        let side = bounds.width
        saveButton.frame = CGRect(x: 0, y: 0, width: side, height: bounds.height / 2)
        shareButton.frame = CGRect(x: 0, y: bounds.height / 2, width: side, height: bounds.height / 2)
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
        shareButton.isEnabled = enabled
    }
}
