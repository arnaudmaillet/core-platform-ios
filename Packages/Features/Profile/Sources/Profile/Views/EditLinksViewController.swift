import DesignSystem
import UIKit

/// Editor for the profile's ordered custom links (label + url pairs), pushed
/// from the Edit Profile list. Each link is its own inset card with a title and
/// URL field plus a remove control; "Add link" appends a blank card. Inline
/// fields are fine here — the "no inline editing" rule governs the main list,
/// and this dedicated screen IS the link field's editor. Save enables when the
/// links changed and every kept row has both a title and a URL.
final class EditLinksViewController: UIViewController {
    private let initialLinks: [ProfileLink]
    private let onSave: ([ProfileLink]) -> Void

    private let scrollView = UIScrollView()
    private let rowsStack = UIStackView()
    private var rowViews: [LinkRowView] = []

    private lazy var saveButton = UIBarButtonItem(
        title: "Save",
        style: .done,
        target: self,
        action: #selector(saveTapped)
    )

    init(links: [ProfileLink], onSave: @escaping ([ProfileLink]) -> Void) {
        self.initialLinks = links
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Links"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = saveButton
        configureLayout()
        for link in initialLinks { appendRow(link) }
        refreshState()
    }

    // MARK: - Setup

    private func configureLayout() {
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        rowsStack.axis = .vertical
        rowsStack.spacing = Spacing.md
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(rowsStack)

        let addButton = UIButton(configuration: {
            var config = UIButton.Configuration.plain()
            config.title = "Add link"
            config.image = UIImage(systemName: "plus.circle.fill")
            config.imagePadding = Spacing.sm
            config.contentInsets = NSDirectionalEdgeInsets(top: Spacing.md, leading: 0, bottom: Spacing.md, trailing: 0)
            return config
        }())
        addButton.contentHorizontalAlignment = .leading
        addButton.addAction(UIAction { [weak self] _ in self?.addLinkTapped() }, for: .touchUpInside)

        let addRow = UIStackView(arrangedSubviews: [addButton])
        addRow.isLayoutMarginsRelativeArrangement = true
        addRow.layoutMargins = UIEdgeInsets(top: 0, left: Spacing.md, bottom: 0, right: Spacing.md)
        rowsStack.addArrangedSubview(addRow)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            rowsStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.lg),
            rowsStack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Spacing.lg),
            rowsStack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Spacing.lg),
            rowsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.lg)
        ])
    }

    // MARK: - Rows

    private func appendRow(_ link: ProfileLink) {
        let row = LinkRowView(link: link)
        row.onChange = { [weak self] in self?.refreshState() }
        row.onRemove = { [weak self] in self?.removeRow(row) }
        rowViews.append(row)
        // Insert above the trailing "Add link" row (always the last arranged view).
        rowsStack.insertArrangedSubview(row, at: rowsStack.arrangedSubviews.count - 1)
    }

    private func removeRow(_ row: LinkRowView) {
        rowViews.removeAll { $0 === row }
        row.removeFromSuperview()
        refreshState()
    }

    private func addLinkTapped() {
        appendRow(ProfileLink(label: "", url: ""))
        rowViews.last?.focusLabel()
        refreshState()
    }

    // MARK: - State

    /// Non-empty rows only — a row with neither a title nor a URL is discarded.
    private var collectedLinks: [ProfileLink] {
        rowViews.map(\.link).filter { !$0.label.isEmpty || !$0.url.isEmpty }
    }

    /// A half-filled row (title without URL, or the reverse) blocks saving.
    private var hasIncompleteRow: Bool {
        rowViews.map(\.link).contains { link in
            let hasLabel = !link.label.isEmpty
            let hasURL = !link.url.isEmpty
            return hasLabel != hasURL
        }
    }

    private func refreshState() {
        saveButton.isEnabled = !hasIncompleteRow && collectedLinks != initialLinks
    }

    @objc private func saveTapped() {
        guard saveButton.isEnabled else { return }
        view.endEditing(true)
        onSave(collectedLinks)
        navigationController?.popViewController(animated: true)
    }
}

/// One inset card editing a single link: a title field over a URL field, with a
/// remove control. Trims its fields into `link` and reports edits via `onChange`.
private final class LinkRowView: UIView {
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?

    private let labelField = UITextField()
    private let urlField = UITextField()

    var link: ProfileLink {
        ProfileLink(
            label: (labelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    init(link: ProfileLink) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12

        configure(labelField, placeholder: "Title", keyboard: .default, autocap: .words)
        labelField.text = link.label
        configure(urlField, placeholder: "https://", keyboard: .URL, autocap: .none)
        urlField.autocorrectionType = .no
        urlField.text = link.url

        let removeButton = UIButton(configuration: {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "minus.circle.fill")
            config.baseForegroundColor = .systemRed
            return config
        }())
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .touchUpInside)

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let fields = UIStackView(arrangedSubviews: [labelField, divider, urlField])
        fields.axis = .vertical
        fields.spacing = Spacing.sm

        let row = UIStackView(arrangedSubviews: [fields, removeButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: Spacing.md, left: Spacing.md, bottom: Spacing.md, right: Spacing.sm)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusLabel() { labelField.becomeFirstResponder() }

    private func configure(_ field: UITextField, placeholder: String, keyboard: UIKeyboardType, autocap: UITextAutocapitalizationType) {
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = keyboard
        field.autocapitalizationType = autocap
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
    }

    @objc private func fieldChanged() { onChange?() }
}
