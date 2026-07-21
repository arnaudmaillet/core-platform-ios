import DesignSystem
import UIKit

/// A focused, single-purpose editor for one profile field, pushed from the Edit
/// Profile list (never edited inline there). Shows one auto-focused text control
/// inside an inset card, an optional live character counter, and helper text.
/// The trailing Save enables only when the value both changed and passes
/// validation; on save it hands the trimmed value back via `Config.onSave` and
/// pops itself.
final class EditFieldViewController: UIViewController {
    /// Everything that makes one field's editor distinct — so a single screen
    /// serves Name, Username, Bio, Website, etc. without subclassing.
    struct Config {
        var title: String
        var initialValue: String
        var placeholder: String
        var multiline: Bool = false
        var characterLimit: Int?
        var keyboardType: UIKeyboardType = .default
        var autocapitalization: UITextAutocapitalizationType = .sentences
        var autocorrection: UITextAutocorrectionType = .default
        /// A fixed leading glyph shown inside the field, e.g. "@" for username.
        var prefix: String?
        var helperText: String?
        /// Returns an error message when the value is invalid, or nil when valid.
        var validate: ((String) -> String?)?
        /// Receives the trimmed, valid value when the user saves.
        var onSave: (String) -> Void
    }

    private let config: Config

    private let card = UIView()
    private let singleLineField = UITextField()
    private let multiLineView = UITextView()
    private let footerLabel = UILabel()
    private let counterLabel = UILabel()

    private lazy var saveButton = UIBarButtonItem(
        title: "Save",
        style: .done,
        target: self,
        action: #selector(saveTapped)
    )

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = config.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = saveButton
        configureInput()
        configureFooter()
        layout()
        currentText = config.initialValue
        refreshState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Focus immediately — the whole point of a dedicated screen is that the
        // keyboard is already up when it lands.
        activeControl.becomeFirstResponder()
    }

    // MARK: - Value

    /// The live value, abstracting over field vs. view.
    private var currentText: String {
        get { config.multiline ? multiLineView.text : (singleLineField.text ?? "") }
        set {
            if config.multiline { multiLineView.text = newValue }
            else { singleLineField.text = newValue }
        }
    }

    private var activeControl: UIResponder { config.multiline ? multiLineView : singleLineField }

    // MARK: - Setup

    private func configureInput() {
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12

        if config.multiline {
            multiLineView.font = .preferredFont(forTextStyle: .body)
            multiLineView.adjustsFontForContentSizeCategory = true
            multiLineView.backgroundColor = .clear
            multiLineView.textContainerInset = UIEdgeInsets(
                top: Spacing.md, left: Spacing.md - 5, bottom: Spacing.md, right: Spacing.md - 5
            )
            multiLineView.keyboardType = config.keyboardType
            multiLineView.autocapitalizationType = config.autocapitalization
            multiLineView.autocorrectionType = config.autocorrection
            multiLineView.delegate = self
        } else {
            singleLineField.font = .preferredFont(forTextStyle: .body)
            singleLineField.adjustsFontForContentSizeCategory = true
            singleLineField.placeholder = config.placeholder
            singleLineField.keyboardType = config.keyboardType
            singleLineField.autocapitalizationType = config.autocapitalization
            singleLineField.autocorrectionType = config.autocorrection
            singleLineField.clearButtonMode = .whileEditing
            singleLineField.returnKeyType = .done
            singleLineField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
            singleLineField.addTarget(self, action: #selector(saveTapped), for: .editingDidEndOnExit)
            if let prefix = config.prefix {
                let label = UILabel()
                label.text = prefix
                label.font = .preferredFont(forTextStyle: .body)
                label.textColor = .secondaryLabel
                label.sizeToFit()
                // Pad the glyph off the card's leading edge.
                let container = UIView(frame: CGRect(
                    x: 0, y: 0, width: label.bounds.width + Spacing.md, height: label.bounds.height
                ))
                label.frame.origin.x = Spacing.md
                container.addSubview(label)
                singleLineField.leftView = container
                singleLineField.leftViewMode = .always
            }
        }
    }

    private func configureFooter() {
        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.textColor = .secondaryLabel
        footerLabel.numberOfLines = 0
        footerLabel.text = config.helperText

        counterLabel.font = .preferredFont(forTextStyle: .footnote)
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textColor = .secondaryLabel
        counterLabel.textAlignment = .right
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.isHidden = config.characterLimit == nil
    }

    private func layout() {
        let input: UIView = config.multiline ? multiLineView : singleLineField
        input.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(input)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: card.topAnchor),
            input.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            input.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: config.multiline ? Spacing.xs : Spacing.md),
            input.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: config.multiline ? -Spacing.xs : -Spacing.md)
        ])
        if !config.multiline {
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        } else {
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }

        let footerRow = UIStackView(arrangedSubviews: [footerLabel, counterLabel])
        footerRow.axis = .horizontal
        footerRow.alignment = .firstBaseline
        footerRow.spacing = Spacing.sm

        let stack = UIStackView(arrangedSubviews: [card, footerRow])
        stack.axis = .vertical
        stack.spacing = Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Spacing.lg)
        ])
    }

    // MARK: - State

    @objc private func textChanged() { refreshState() }

    private func refreshState() {
        enforceLimit()
        let value = currentText
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTrimmed = config.initialValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let validationError = config.validate?(trimmed)
        let changed = trimmed != initialTrimmed
        saveButton.isEnabled = changed && validationError == nil && !(trimmed.isEmpty && !allowsEmpty)

        if let limit = config.characterLimit {
            counterLabel.text = "\(limit - value.count)"
            counterLabel.textColor = value.count > limit ? .systemRed : .secondaryLabel
        }
        // Surface a validation message in place of the helper text while invalid.
        if changed, let validationError {
            footerLabel.text = validationError
            footerLabel.textColor = .systemRed
        } else {
            footerLabel.text = config.helperText
            footerLabel.textColor = .secondaryLabel
        }
    }

    /// Whether an empty value is a legitimate save (clearing an optional field
    /// like bio/website) vs. one that must stay filled (name/username).
    private var allowsEmpty: Bool { config.validate == nil }

    /// Hard-caps input at the limit so the counter can't go negative — matches
    /// the native "you physically can't type past the limit" behavior.
    private func enforceLimit() {
        guard let limit = config.characterLimit, currentText.count > limit else { return }
        currentText = String(currentText.prefix(limit))
    }

    @objc private func saveTapped() {
        guard saveButton.isEnabled else { return }
        view.endEditing(true)
        config.onSave(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
        navigationController?.popViewController(animated: true)
    }
}

extension EditFieldViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { refreshState() }
}
