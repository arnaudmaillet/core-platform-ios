#if DEBUG
import UIKit

/// `-haptic-catalog` (#1882): every role of the haptic map, to feel and tune
/// on a device — the simulator has no Taptic Engine.
///
/// - One row per role: its recipe and when the hand gets it; a tap plays it.
/// - "Burst": ten `step`s 30 ms apart — fewer play, which is the pacing.
/// - "Fling": a strip of detents on a real scroll view, through
///   `DetentFeedback` — drag it slowly, then flick it.
public final class HapticCatalogViewController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let strip = UIScrollView()
    private let detents = DetentFeedback(role: .step)
    private static let detentSpacing: CGFloat = 56
    private static let detentCount = 30

    public init() {
        super.init(nibName: nil, bundle: nil)
        title = "Haptics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Spacing.sm
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        if !HapticPreference.isOn {
            column.addArrangedSubview(Self.note("Haptics is off in Settings: nothing will play."))
        }
        for role in Haptic.allCases {
            column.addArrangedSubview(row(
                title: "\(role)", detail: "\(Self.describe(role.recipe)) — \(Self.when(role))"
            ) { Haptics.play(role) })
        }
        column.addArrangedSubview(row(
            title: "Burst", detail: "Ten steps 30 ms apart: fewer play — the pacing (60 ms)"
        ) {
            for index in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.030 * Double(index)) { Haptics.play(.step) }
            }
        })
        column.addArrangedSubview(Self.note("Fling: one step per detent, while dragged and gliding."))
        column.addArrangedSubview(makeStrip())
    }

    private func row(title: String, detail: String, action: @escaping () -> Void) -> UIView {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.subtitle = detail
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in Haptics.prepare(.step) }, for: .touchDown)
        return button
    }

    private func makeStrip() -> UIView {
        strip.delegate = self
        strip.showsHorizontalScrollIndicator = false
        strip.decelerationRate = .fast
        strip.layer.cornerRadius = 12
        strip.backgroundColor = .secondarySystemFill
        strip.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let spacing = Self.detentSpacing
        for index in 0..<Self.detentCount {
            let label = UILabel(frame: CGRect(x: CGFloat(index) * spacing, y: 0, width: spacing, height: 72))
            label.text = "\(index)"
            label.textAlignment = .center
            label.font = .appFont(forTextStyle: .headline)
            strip.addSubview(label)
        }
        strip.contentSize = CGSize(width: spacing * CGFloat(Self.detentCount), height: 72)
        detents.reset(to: 0)
        return strip
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        detents.prepare()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        detents.update(
            position: scrollView.contentOffset.x, spacing: Self.detentSpacing, count: Self.detentCount,
            isDriven: scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        )
    }

    private static func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .appFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        return label
    }

    private static func describe(_ recipe: HapticRecipe) -> String {
        switch recipe {
        case .selection: return "selection"
        case .impact(let style, let intensity):
            let name: String = switch style {
            case .light: "light"
            case .medium: "medium"
            case .heavy: "heavy"
            case .soft: "soft"
            case .rigid: "rigid"
            @unknown default: "impact"
            }
            return intensity < 1 ? "impact .\(name) at \(intensity)" : "impact .\(name)"
        case .notification(let type):
            return switch type {
            case .success: "notification .success"
            case .warning: "notification .warning"
            case .error: "notification .error"
            @unknown default: "notification"
            }
        }
    }

    private static func when(_ role: Haptic) -> String {
        switch role {
        case .tick: "a fine step: a ruler, the dial, a choice in a list"
        case .step: "a coarse step: a page scrubbed, an emote past the wheel's detent"
        case .held: "a custom long press recognised"
        case .armed: "a drag crosses its commit point: a pull, the trash, the lock"
        case .grab: "a custom drag lifts an item"
        case .drop: "the item lands in a new place"
        case .boundary: "a scrub, ruler or dial reaches its end or centre"
        case .toggleOn: "a state turned on: follow, repost, bookmark"
        case .commit: "a weighty action: a stake, the shutter, recording"
        case .success: "an action of the viewer's succeeded"
        case .warning: "it happened, with a catch"
        case .error: "an action of the viewer's failed"
        }
    }
}
#endif
