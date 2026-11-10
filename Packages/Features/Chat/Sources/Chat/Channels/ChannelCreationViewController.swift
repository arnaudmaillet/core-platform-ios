import CoreModels
import DesignSystem
import UIKit

/// The new channel's sheet (#2215): what a channel is, in two lines
/// (#2230), where its photo will go (its initials, no picker yet —
/// `ChannelCreationViewModel`), its name, its description, who may join —
/// Public or On request, each said in a line — and "Create".
///
/// Opened from the "+" menu and the inbox search (#2230): with the
/// Channels tab gone, nothing around it says what a channel is any more,
/// so its header does — the words the empty tab said.
///
/// With the showcases (#2216), creating ends on a last step: the channel is
/// ready, "Share as a Post" (prominent: a new channel's first readers come
/// from its showcase) and "Open Channel".
final class ChannelCreationViewController: UIViewController {
    private let viewModel: ChannelCreationViewModel

    /// Cancel: the host dismisses the sheet.
    var onCancel: (() -> Void)?
    /// The created step's "Open Channel" (#2216): the host lands in it.
    var onOpen: ((ConversationID) -> Void)?
    /// The created step's "Share as a Post" (#2216): the host lands in the
    /// channel and opens the Text Post screen with its card.
    var onShareAsPost: ((ConversationID, PostEmbed) -> Void)?

    private let scrollView = UIScrollView()
    /// What a channel is (#2230), over everything else.
    private let introLabel = UILabel()
    private let disc = MonogramAvatarView(diameter: GroupNameViewController.discDiameter)
    private let nameField = UITextField()
    private let descriptionField = UITextField()
    private let visibilityControl = UISegmentedControl()
    private let visibilityNote = UILabel()
    private let errorLabel = UILabel()
    private let createButton = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Create"))
    // The created step (#2216).
    private let createdTitle = UILabel()
    private let createdNote = UILabel()
    private let shareButton = AppButton(
        aspect: .pill(.prominent), size: .form,
        content: AppButton.Content(title: ChannelShowcase.shareTitle, symbol: ChannelShowcase.shareSymbol)
    )
    private let openButton = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Open Channel"))

    init(viewModel: ChannelCreationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "New Channel"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel?() }
        )
        introLabel.text = ChannelCopy.whatItIs
        introLabel.font = .appFont(forTextStyle: .subheadline)
        introLabel.textColor = .secondaryLabel
        introLabel.numberOfLines = 0
        introLabel.textAlignment = .center
        introLabel.adjustsFontForContentSizeCategory = true
        disc.setMonogram(MonogramAvatarView.monogram(name: "Channel", handle: ""))
        disc.accessibilityLabel = "Channel photo"

        configure(nameField, placeholder: "Channel name", font: .title3, label: "Channel name")
        nameField.textAlignment = .center
        nameField.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        nameField.addAction(UIAction { [weak self] _ in self?.descriptionField.becomeFirstResponder() }, for: .editingDidEndOnExit)
        nameField.returnKeyType = .next

        configure(descriptionField, placeholder: "Description (optional)", font: .body, label: "Description")
        descriptionField.textAlignment = .center
        descriptionField.returnKeyType = .done
        descriptionField.addAction(UIAction { [weak self] _ in
            self?.viewModel.descriptionChanged(self?.descriptionField.text ?? "")
        }, for: .editingChanged)
        descriptionField.addAction(UIAction { [weak self] _ in self?.descriptionField.resignFirstResponder() }, for: .editingDidEndOnExit)

        for (index, choice) in ChannelCopy.choosableVisibilities.enumerated() {
            visibilityControl.insertSegment(withTitle: ChannelCopy.visibilityTitle(choice), at: index, animated: false)
        }
        visibilityControl.selectedSegmentIndex = ChannelCopy.choosableVisibilities.firstIndex(of: viewModel.visibility) ?? 0
        visibilityControl.accessibilityLabel = "Who can join"
        visibilityControl.addAction(UIAction { [weak self] _ in self?.visibilityChanged() }, for: .valueChanged)
        visibilityNote.font = .appFont(forTextStyle: .footnote)
        visibilityNote.textColor = .secondaryLabel
        visibilityNote.numberOfLines = 0
        visibilityNote.textAlignment = .center
        visibilityNote.adjustsFontForContentSizeCategory = true

        errorLabel.font = .appFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true

        createButton.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)
        // The inputs grey only once the load shows (#2270).
        createButton.onLoadShownChange = { [weak self] shown in self?.setInputsGreyed(shown) }

        createdTitle.font = .appFont(forTextStyle: .title2)
        createdTitle.textAlignment = .center
        createdTitle.numberOfLines = 0
        createdNote.font = .appFont(forTextStyle: .subheadline)
        createdNote.textColor = .secondaryLabel
        createdNote.textAlignment = .center
        createdNote.numberOfLines = 0
        createdNote.text = Self.createdNoteText
        for label in [createdTitle, createdNote] {
            label.adjustsFontForContentSizeCategory = true
            label.isHidden = true
        }
        shareButton.isHidden = true
        openButton.isHidden = true
        shareButton.addAction(UIAction { [weak self] _ in self?.shareAsPost() }, for: .primaryActionTriggered)
        openButton.addAction(UIAction { [weak self] _ in self?.openCreated() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [
            introLabel, disc, nameField, descriptionField, visibilityControl, visibilityNote, errorLabel, createButton,
            createdTitle, createdNote, shareButton, openButton,
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.lg
        stack.setCustomSpacing(Spacing.sm, after: visibilityControl)
        stack.setCustomSpacing(Spacing.xl, after: visibilityNote)
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.pin(to: view)
        let scroll = scrollView
        stack.constrain(in: scrollView) { _ in
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl)
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl)
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg)
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg)
            introLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            descriptionField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            visibilityControl.widthAnchor.constraint(equalTo: stack.widthAnchor)
            visibilityNote.widthAnchor.constraint(equalTo: stack.widthAnchor)
            createButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            createdTitle.widthAnchor.constraint(equalTo: stack.widthAnchor)
            createdNote.widthAnchor.constraint(equalTo: stack.widthAnchor)
            shareButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            openButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onCanCreateChange = { [weak self] can in self?.createButton.isEnabled = can }
        createButton.isEnabled = viewModel.canCreate
        renderVisibility()
        render(viewModel.phase)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    private func configure(_ field: UITextField, placeholder: String, font: UIFont.TextStyle, label: String) {
        field.placeholder = placeholder
        field.font = .appFont(forTextStyle: font)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .sentences
        field.accessibilityLabel = label
    }

    private func nameChanged() {
        let text = nameField.text ?? ""
        viewModel.nameChanged(text)
        let shown = text.trimmingCharacters(in: .whitespaces).isEmpty ? "Channel" : text
        disc.setMonogram(MonogramAvatarView.monogram(name: shown, handle: ""))
    }

    private func visibilityChanged() {
        let index = visibilityControl.selectedSegmentIndex
        guard ChannelCopy.choosableVisibilities.indices.contains(index) else { return }
        viewModel.visibilityChanged(ChannelCopy.choosableVisibilities[index])
        renderVisibility()
    }

    private func renderVisibility() {
        visibilityNote.text = ChannelCopy.visibilityExplanation(viewModel.visibility)
    }

    private func create() {
        view.endEditing(true)
        viewModel.create()
    }

    /// ⚠️ THE INPUTS ARE LOCKED AT ONCE, GREY ONLY ONCE THE LOAD SHOWS
    /// (#2270): a fast answer shows nothing but the press. The answer — the
    /// created step, an error — waits for the load it ends.
    private func render(_ phase: ChannelCreationViewModel.Phase) {
        let animated = view.window != nil
        guard phase != .creating else {
            setInputsLocked(true)
            errorLabel.isHidden = true
            createButton.setPhase(.loading, animated: animated)
            return
        }
        createButton.setPhase(.content, animated: animated) { [weak self] in
            guard let self else { return }
            setInputsLocked(false)
            if case .created = phase { return showCreated() }
            if case .failed(let message) = phase {
                errorLabel.text = message
                errorLabel.isHidden = false
            } else {
                errorLabel.isHidden = true
            }
        }
    }

    private var inputs: [UIView] { [nameField, descriptionField, visibilityControl] }

    private func setInputsLocked(_ locked: Bool) {
        for input in inputs { input.isUserInteractionEnabled = !locked }
    }

    private func setInputsGreyed(_ greyed: Bool) {
        nameField.isEnabled = !greyed
        descriptionField.isEnabled = !greyed
        visibilityControl.isEnabled = !greyed
    }
}

// MARK: - The created step (#2216)

extension ChannelCreationViewController {
    static let createdNoteText = "Share it as a post so people find it in the feed and on the map."

    /// The channel exists: the form steps aside for its two ways on. No
    /// Cancel — there is nothing left to cancel; a swipe down leaves it on
    /// Chats, which lists it. The intro goes too (#2230): it says what a
    /// channel is to someone about to make one, and this one exists.
    private func showCreated() {
        view.endEditing(true)
        createButton.setPhase(.content, animated: false)
        let form: [UIView] = [introLabel, nameField, descriptionField, visibilityControl, visibilityNote, errorLabel, createButton]
        for part in form {
            part.isHidden = true
        }
        createdTitle.text = "\(viewModel.draft.name) is ready"
        for part in [createdTitle, createdNote, shareButton, openButton] as [UIView] {
            part.isHidden = false
        }
        navigationItem.leftBarButtonItem = nil
        UIAccessibility.post(notification: .screenChanged, argument: createdTitle)
    }

    private func shareAsPost() {
        guard case .created(let id) = viewModel.phase, let embed = viewModel.showcaseEmbed else { return }
        onShareAsPost?(id, embed)
    }

    private func openCreated() {
        guard case .created(let id) = viewModel.phase else { return }
        onOpen?(id)
    }

    #if DEBUG
    /// Whether the created step shows, with "Share as a Post".
    var debugOffersShareAsPost: Bool { !shareButton.isHidden }
    func debugShareAsPost() { shareAsPost() }
    func debugOpenCreated() { openCreated() }
    #endif
}

// MARK: - How it is left (#1144)

extension ChannelCreationViewController: StackScreen {
    /// A sheet's root: its Cancel, or the sheet's swipe down.
    var leaving: ScreenLeaving { .controlsOnly }
}
