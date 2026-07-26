import DesignSystem
import MediaCore
import UIKit

/// The unified profile share surface: a QR card over two actions, presented as
/// a sheet at a detent sized to its own content.
///
/// Reached from the header tray's QR bubble AND from the "..." menu's Share —
/// one destination, so "share this profile" means the same thing wherever it
/// is invoked. The system share sheet is downstream of this one, not parallel
/// to it.
///
/// Presented bare rather than nav-wrapped (the app's other two sheets wrap
/// because they need bar items to dock into): there is nothing to title and
/// nothing to navigate to, so the grabber plus swipe-down is the whole
/// dismissal story and the card gets the full sheet.
final class ProfileShareViewController: UIViewController {
    private let card: ProfileViewModel.ShareCard
    private let imagePipeline: ImagePipeline

    private let cardView: ProfileQRCardView
    private let shareButton = UIButton(configuration: .prominentGlass())
    private let copyButton = UIButton(configuration: .glass())

    /// The measured content height the custom detent resolves to. Seeded with
    /// an estimate so the sheet has a sane height for its very first frame,
    /// then replaced by the real measurement (see `viewDidLayoutSubviews`).
    private var contentHeight: CGFloat = 520
    private static let detentIdentifier = UISheetPresentationController.Detent.Identifier("profileShare")

    init(card: ProfileViewModel.ShareCard, imagePipeline: ImagePipeline) {
        self.card = card
        self.imagePipeline = imagePipeline
        cardView = ProfileQRCardView(imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        configureDetent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One detent, sized to the content — not `.medium()`, which is a fixed
    /// fraction of the screen and would park a fixed-height card above a dead
    /// gap. Nothing here scrolls or expands, so a second detent would only
    /// offer the user a worse version of this one.
    private func configureDetent() {
        guard let sheet = sheetPresentationController else { return }
        sheet.detents = [.custom(identifier: Self.detentIdentifier) { [weak self] context in
            guard let self else { return context.maximumDetentValue * 0.7 }
            return min(self.contentHeight, context.maximumDetentValue)
        }]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 32
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        cardView.configure(with: card)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Measure what the content actually wants — Dynamic Type moves this,
        // so it can't be a constant — and re-resolve the detent when it
        // changes. `invalidateDetents` is the only way to make a custom
        // detent re-ask its resolver.
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard fitted > 0, abs(fitted - contentHeight) > 1 else { return }
        contentHeight = fitted
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.invalidateDetents()
        }
    }

    private func configureViews() {
        shareButton.configuration?.title = "Share…"
        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.configuration?.imagePadding = Spacing.sm
        shareButton.configuration?.cornerStyle = .capsule
        shareButton.configuration?.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: Spacing.lg, bottom: 14, trailing: Spacing.lg
        )
        shareButton.addAction(UIAction { [weak self] _ in self?.presentActivitySheet() }, for: .primaryActionTriggered)

        copyButton.configuration?.title = "Copy Link"
        copyButton.configuration?.image = UIImage(systemName: "link")
        copyButton.configuration?.imagePadding = Spacing.sm
        copyButton.configuration?.cornerStyle = .capsule
        copyButton.configuration?.contentInsets = shareButton.configuration?.contentInsets ?? .init()
        copyButton.addAction(UIAction { [weak self] _ in self?.copyLink() }, for: .primaryActionTriggered)

        let actions = UIStackView(arrangedSubviews: [shareButton, copyButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = Spacing.md

        let column = UIStackView(arrangedSubviews: [cardView, actions])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xl
        // The grabber needs headroom, and the sheet's bottom safe area is
        // already inside `layoutMarginsGuide` on the safe-area side below.
        column.constrain(in: view) { parent in
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xxl)
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.xl)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.xl)
            column.bottomAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.xl
            )
        }
    }

    // MARK: - Actions

    /// Hands off to the system sheet with two items: the link (carrying the
    /// metadata that gives the sheet a branded header) and the rendered card.
    /// The image is what makes "Save Image", Instagram Stories, and pasting
    /// into a message work — which is why this feature has no Save chip of its
    /// own, and needs no photo-library permission.
    private func presentActivitySheet() {
        let image = ProfileShareCard.render(
            ProfileQRCardView(imagePipeline: imagePipeline).configured(with: card),
            width: 320,
            scale: traitCollection.displayScale
        )
        let source = ProfileShareItemSource(card: card, icon: image)
        let activity = UIActivityViewController(activityItems: [source, image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    #if DEBUG
    /// Test hook for `-profile-share-demo activity` — the Share button is
    /// behind a tap the simulator can't inject.
    func qaPresentActivitySheet() { presentActivitySheet() }
    #endif

    private func copyLink() {
        UIPasteboard.general.url = card.url
        UIPasteboard.general.string = card.url.absoluteString
        ToastView.present("Link copied", symbol: "link", in: view)
    }
}

private extension ProfileQRCardView {
    /// Configures and returns self, so a throwaway card can be built inline
    /// for rasterization without a local binding.
    func configured(with card: ProfileViewModel.ShareCard) -> ProfileQRCardView {
        configure(with: card)
        return self
    }
}
