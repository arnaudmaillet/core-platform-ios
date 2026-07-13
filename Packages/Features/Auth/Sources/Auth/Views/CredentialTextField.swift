import UIKit

/// Bare text field for inset-grouped form rows: no chrome of its own (the
/// cell supplies margins and background), with an optional secure-entry
/// reveal toggle in `rightView`.
final class CredentialTextField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Turns the field into a password field with an eye button that toggles
    /// `isSecureTextEntry`.
    func enableSecureEntryReveal() {
        isSecureTextEntry = true
        rightView = makeRevealButton()
        rightViewMode = .always
        updateRevealButton()
    }

    private func makeRevealButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .body, scale: .small
        )
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.addAction(
            UIAction { [weak self] _ in self?.toggleSecureEntry() },
            for: .primaryActionTriggered
        )
        return button
    }

    private func toggleSecureEntry() {
        let wasFirstResponder = isFirstResponder
        isSecureTextEntry.toggle()
        // Re-securing while focused makes UIKit wipe the text on the next
        // keystroke; re-inserting it preserves what was typed.
        if wasFirstResponder, isSecureTextEntry, let existing = text, !existing.isEmpty {
            text = ""
            insertText(existing)
        }
        updateRevealButton()
    }

    private func updateRevealButton() {
        guard let button = rightView as? UIButton else { return }
        button.configuration?.image = UIImage(systemName: isSecureTextEntry ? "eye" : "eye.slash")
        button.accessibilityLabel = isSecureTextEntry
            ? String(localized: "Show password")
            : String(localized: "Hide password")
    }
}
