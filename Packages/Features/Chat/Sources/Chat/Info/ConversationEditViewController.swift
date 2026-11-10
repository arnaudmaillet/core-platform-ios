import DesignSystem
import MediaCore
import UIKit

/// A group's or a channel's editing sheet (#2237), from the header's Edit:
/// its photo, its name and its description on one sheet, where an alert
/// held two fields.
///
/// ⚠️ THE PHOTO IS SHOWN, NOT CHANGED YET: nothing in the app uploads a
/// picture for a conversation (`GroupCreationViewModel`'s note), so the
/// sheet keeps the photo it has; the picker goes here once one does.
final class ConversationEditViewController: UIViewController {
    struct Fields: Equatable {
        var name: String
        var description: String
    }

    private let initial: Fields
    private let photoURL: URL?
    private let imagePipeline: ImagePipeline?
    /// A channel keeps a name; a group's may be empty (named by its members).
    private let requiresName: Bool
    private let namePlaceholder: String
    private let photo = AvatarView(diameter: GroupNameViewController.discDiameter, size: .px256)
    private let nameField = UITextField()
    private let descriptionView = UITextView()
    private lazy var saveItem = BarItems.title(id: "conversation.edit.save", title: "Save", prominent: true) { [weak self] in
        self?.save()
    }

    /// Save: the fields as typed. The sheet closes itself either way.
    var onSave: ((Fields) -> Void)?

    init(
        title: String, fields: Fields, photoURL: URL?, imagePipeline: ImagePipeline?,
        requiresName: Bool, namePlaceholder: String
    ) {
        initial = fields
        self.photoURL = photoURL
        self.imagePipeline = imagePipeline
        self.requiresName = requiresName
        self.namePlaceholder = namePlaceholder
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page the cards lie on, a step below them — see `Surface`.
        view.backgroundColor = Surface.page
        navigationItem.leftBarButtonItem = BarItems.title(id: "conversation.edit.cancel", title: "Cancel") { [weak self] in
            _ = self?.closePresentation()
        }
        navigationItem.rightBarButtonItem = saveItem

        photo.setMonogram(MonogramAvatarView.monogram(name: initial.name, handle: ""))
        photo.setPicture(photoURL, pipeline: imagePipeline)
        photo.isAccessibilityElement = true
        photo.accessibilityLabel = "Photo"

        nameField.placeholder = namePlaceholder
        nameField.text = initial.name
        nameField.font = .appFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.autocapitalizationType = .sentences
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.addAction(UIAction { [weak self] _ in self?.applySaveAvailability() }, for: .editingChanged)

        descriptionView.text = initial.description
        descriptionView.font = .appFont(forTextStyle: .body)
        descriptionView.adjustsFontForContentSizeCategory = true
        descriptionView.backgroundColor = .clear
        descriptionView.isScrollEnabled = false
        descriptionView.textContainerInset = .zero
        descriptionView.textContainer.lineFragmentPadding = 0
        descriptionView.accessibilityLabel = "Description"

        // The disc, centred over the fields.
        let photoRow = UIView()
        photo.translatesAutoresizingMaskIntoConstraints = false
        photoRow.addSubview(photo)
        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: photoRow.topAnchor),
            photo.bottomAnchor.constraint(equalTo: photoRow.bottomAnchor),
            photo.centerXAnchor.constraint(equalTo: photoRow.centerXAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [
            photoRow, card(titled: "Name", holding: nameField), card(titled: "Description", holding: descriptionView),
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.lg
        stack.setCustomSpacing(Spacing.xl, after: photoRow)
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.pin(to: view)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
            descriptionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
        applySaveAvailability()
    }

    /// A field under its caption, on a card.
    private func card(titled title: String, holding field: UIView) -> UIView {
        let caption = UILabel()
        caption.text = title
        caption.font = .appFont(forTextStyle: .footnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        let ground = UIView()
        // The card contract's tone, corner and edge (#1497).
        Surface.dressCard(ground)
        field.pin(to: ground, insets: NSDirectionalEdgeInsets(top: Spacing.md, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md))
        let column = UIStackView(arrangedSubviews: [caption, ground])
        column.axis = .vertical
        column.spacing = Spacing.xs
        return column
    }

    private var typed: Fields {
        Fields(name: nameField.text ?? "", description: descriptionView.text ?? "")
    }

    private func applySaveAvailability() {
        let hasName = !(nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveItem.isEnabled = hasName || !requiresName
    }

    private func save() {
        let fields = typed
        _ = closePresentation { [weak self] in
            guard let self, fields != initial else { return }
            onSave?(fields)
        }
    }

    #if DEBUG
    /// Types into the fields and saves, as a finger would. Tests.
    func debugSave(name: String, description: String) {
        nameField.text = name
        descriptionView.text = description
        onSave?(typed)
    }
    #endif
}
