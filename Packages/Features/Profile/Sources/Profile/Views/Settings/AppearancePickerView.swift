import DesignSystem
import UIKit

/// Settings → App and Device → Display → Appearance: System, Light and Dark
/// side by side, each with its symbol above its name and a selection circle
/// below — the layout of iOS's own Display & Brightness, without device
/// previews. A `UIControl` sending `.valueChanged`, so it drops into the same
/// row slot the segmented control used.
final class AppearancePickerView: UIControl {
    private let options = AppearancePreference.allCases
    private var columns: [UIButton] = []

    private(set) var selection: AppearancePreference {
        didSet { updateSelection() }
    }

    init(selection: AppearancePreference) {
        self.selection = selection
        super.init(frame: .zero)
        accessibilityLabel = "Appearance"

        columns = options.map { option in
            let button = UIButton(type: .system)
            button.tintColor = .label
            button.accessibilityLabel = option.title
            button.addAction(UIAction { [weak self] _ in self?.choose(option) }, for: .primaryActionTriggered)
            return button
        }
        let stack = UIStackView(arrangedSubviews: columns)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func choose(_ option: AppearancePreference) {
        guard option != selection else { return }
        HapticSelection().selectionChanged()
        selection = option
        sendActions(for: .valueChanged)
    }

    private func updateSelection() {
        for (option, button) in zip(options, columns) {
            let isSelected = option == selection
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: option.symbolName)
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 28)
            configuration.imagePlacement = .top
            configuration.imagePadding = 8
            var title = AttributedString(option.title)
            // Capped (#482): three columns share the row; at large sizes
            // "System" broke across three lines.
            title.font = .scaledFont(forTextStyle: .subheadline, weight: .regular, maximumPointSize: 19)
            configuration.attributedTitle = title
            configuration.titleAlignment = .center
            configuration.baseForegroundColor = isSelected ? .label : .secondaryLabel
            button.configuration = configuration
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            Self.installMark(isSelected: isSelected, under: button)
        }
    }

    private static let markTag = 0xA77E

    /// The selection circle: filled check when chosen, an empty ring
    /// otherwise. Below the button's content, centred.
    private static func installMark(isSelected: Bool, under button: UIButton) {
        let mark = (button.viewWithTag(markTag) as? UIImageView) ?? {
            let view = UIImageView()
            view.tag = markTag
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            view.preferredSymbolConfiguration = .init(textStyle: .title3)
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            return view
        }()
        mark.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        mark.tintColor = isSelected ? .tintColor : .tertiaryLabel
        button.configuration?.contentInsets.bottom = 34
    }
}
