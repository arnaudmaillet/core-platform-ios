import DesignSystem
import UIKit

/// A slider that rests on a few NOTCHES, each named under the track
/// (Settings' player pool, #702: Less / Normal / More). It snaps to the
/// nearest notch when let go and sends `.valueChanged` when the notch
/// changes; `selectedIndex` is the notch.
final class NotchedSlider: UIControl {
    private let slider = UISlider()
    private let labels: [UILabel]
    private(set) var selectedIndex: Int

    init(notches: [String], selected: Int) {
        precondition(notches.count >= 2, "a notched slider needs two notches")
        selectedIndex = min(max(selected, 0), notches.count - 1)
        labels = notches.map { title in
            let label = UILabel()
            label.text = title
            label.font = .appFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            return label
        }
        super.init(frame: .zero)

        slider.minimumValue = 0
        slider.maximumValue = Float(notches.count - 1)
        slider.value = Float(selectedIndex)
        slider.addAction(UIAction { [weak self] _ in self?.track() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.snap() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let names = UIStackView(arrangedSubviews: labels)
        names.axis = .horizontal
        names.distribution = .equalSpacing
        let stack = UIStackView(arrangedSubviews: [slider, names])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLabels()
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool {
        didSet { slider.isEnabled = isEnabled }
    }

    override var accessibilityValue: String? {
        get { labels[selectedIndex].text }
        set {}
    }

    override func accessibilityIncrement() { select(selectedIndex + 1) }
    override func accessibilityDecrement() { select(selectedIndex - 1) }

    /// Moves to `index` as a viewer would: the thumb snaps and, when the
    /// notch changed, `.valueChanged` is sent.
    func select(_ index: Int) {
        let index = min(max(index, 0), labels.count - 1)
        slider.setValue(Float(index), animated: true)
        commit(index)
    }

    /// While dragging, the notch under the thumb is the one named.
    private func track() {
        let index = Int(slider.value.rounded())
        if index != selectedIndex { commit(index) }
    }

    private func snap() {
        let index = Int(slider.value.rounded())
        slider.setValue(Float(index), animated: true)
        commit(index)
    }

    private func commit(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        refreshLabels()
        HapticSelection().selectionChanged()
        sendActions(for: .valueChanged)
    }

    private func refreshLabels() {
        for (offset, label) in labels.enumerated() {
            label.textColor = offset == selectedIndex ? .label : .secondaryLabel
        }
    }

    #if DEBUG
    var debugNotchTitles: [String] { labels.compactMap(\.text) }
    #endif
}
