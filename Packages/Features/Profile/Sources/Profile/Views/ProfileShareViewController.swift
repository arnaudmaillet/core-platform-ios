import DesignSystem
import MediaCore
import UIKit

/// The unified profile share surface: a QR card, a row of people to send it
/// to, and a tray of actions — presented as a sheet at a detent sized to its
/// own content.
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
///
/// **This controller never presents anything itself.** Both escape hatches —
/// the system share sheet and a DM — are published as callbacks the presenter
/// handles *after dismissing this sheet*. Presenting a share sheet from a
/// sheet stacks two cards and shrinks the one underneath; routing to a thread
/// from a sheet would push behind it. See `onSystemShare` / `onSendToTarget`.
final class ProfileShareViewController: UIViewController {
    /// Fires after this sheet has been dismissed, with the rendered share card
    /// — the presenter opens `UIActivityViewController` with it.
    var onSystemShare: ((ProfileViewModel.ShareCard, UIImage) -> Void)?
    /// Fires after this sheet has been dismissed: send the profile to someone.
    var onSendToTarget: ((ProfileShareTarget, ProfileViewModel.ShareCard) -> Void)?

    private let card: ProfileViewModel.ShareCard
    private let imagePipeline: ImagePipeline
    private let targeting: (any ProfileShareTargeting)?

    private let cardView: ProfileQRCardView
    private let targetsView: ProfileShareTargetsView
    private let targetsHeading = UILabel()
    private let actionsScrollView = UIScrollView()

    /// The measured content height the custom detent resolves to. Seeded with
    /// an estimate so the sheet has a sane height for its very first frame,
    /// then replaced by the real measurement (see `viewDidLayoutSubviews`).
    private var contentHeight: CGFloat = 640
    private static let detentIdentifier = UISheetPresentationController.Detent.Identifier("profileShare")
    /// How many people the quick-send row asks for.
    private static let targetLimit = 12
    /// Ceiling on the card's width; it centres below that on wider screens.
    private static let cardMaxWidth: CGFloat = 300

    init(
        card: ProfileViewModel.ShareCard,
        imagePipeline: ImagePipeline,
        targeting: (any ProfileShareTargeting)?
    ) {
        self.card = card
        self.imagePipeline = imagePipeline
        self.targeting = targeting
        cardView = ProfileQRCardView(imagePipeline: imagePipeline)
        targetsView = ProfileShareTargetsView(imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        configureDetent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One detent, sized to the content — not `.medium()`, which is a fixed
    /// fraction of the screen and would park a fixed-height card above a dead
    /// gap. Nothing here scrolls vertically or expands, so a second detent
    /// would only offer the user a worse version of this one.
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
        // `.withAlphaComponent(1)` is load-bearing, not decoration: inside an
        // iOS 26 sheet the semantic background colours resolve TRANSLUCENT, so
        // a plain `.systemBackground` let the profile's banner wash through as
        // an uneven colour band behind the quick-send row (verified in-sim —
        // the same trap `ProfileQRCardView` documents). Forcing alpha keeps the
        // dynamic light/dark resolution while making the surface solid.
        view.backgroundColor = .systemBackground.withAlphaComponent(1)
        configureViews()
        cardView.configure(with: card)
        loadTargets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Measure what the content actually wants — Dynamic Type and the
        // quick-send row's arrival both move this — and re-resolve the detent
        // when it changes. `invalidateDetents` is the only way to make a
        // custom detent re-ask its resolver.
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
        targetsHeading.text = "Send to"
        targetsHeading.font = .preferredFont(forTextStyle: .footnote)
        targetsHeading.adjustsFontForContentSizeCategory = true
        targetsHeading.textColor = .secondaryLabel
        targetsView.onSelect = { [weak self] target in self?.send(to: target) }

        let targets = UIStackView(arrangedSubviews: [targetsHeading, targetsView])
        targets.axis = .vertical
        targets.alignment = .fill
        targets.spacing = Spacing.sm
        // Hidden until the row has someone in it — the heading must not stand
        // alone over an empty strip while the graph read is in flight.
        targets.isHidden = true

        // The card is centred and capped rather than full-bleed: at full sheet
        // width the code alone runs past 300pt, which pushed the quick-send row
        // and the tray so far down the sheet swallowed the screen. A QR only
        // has to be big enough to scan.
        let cardRow = UIView()
        // The cap yields to the row's width on a screen too narrow for it, so
        // it can never force a horizontal overflow.
        let cardWidth = cardView.widthAnchor.constraint(equalToConstant: Self.cardMaxWidth)
        cardWidth.priority = .defaultHigh
        cardView.constrain(in: cardRow) { parent in
            cardView.topAnchor.constraint(equalTo: parent.topAnchor)
            cardView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            cardView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            cardView.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor)
            cardWidth
        }

        let column = UIStackView(arrangedSubviews: [cardRow, targets, makeActionsTray()])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.xl
        column.constrain(in: view) { parent in
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xxl)
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.xl)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.xl)
            column.bottomAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.xl
            )
        }
        targetsSection = targets
    }

    private var targetsSection: UIStackView?

    /// The actions tray: Liquid Glass capsules on a horizontal scroll view.
    ///
    /// Scrollable even though today's two actions fit — the tray is where
    /// further actions land, and a row that grows into scrolling is one that
    /// never has to be re-laid-out to make room. The buttons carry glass
    /// because they sit on the sheet's own background, not inside a
    /// system-supplied capsule: the double-material trap this app documents is
    /// about nesting inside the system's material, not about owning one.
    private func makeActionsTray() -> UIView {
        let actions = UIStackView(arrangedSubviews: [
            makeActionButton(
                title: "Share via…", symbol: "square.and.arrow.up", prominent: true
            ) { [weak self] in self?.handOffToSystemShare() },
            makeActionButton(title: "Copy Link", symbol: "link", prominent: false) { [weak self] in
                self?.copyLink()
            }
        ])
        actions.axis = .horizontal
        actions.alignment = .fill
        actions.spacing = Spacing.md

        actionsScrollView.showsHorizontalScrollIndicator = false
        // Clipping off so a capsule's glass edge isn't shaved at the tray's
        // bounds while it scrolls.
        actionsScrollView.clipsToBounds = false
        actions.constrain(in: actionsScrollView) { parent in
            actions.topAnchor.constraint(equalTo: parent.topAnchor)
            actions.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            actions.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            actions.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            actions.heightAnchor.constraint(equalTo: actionsScrollView.frameLayoutGuide.heightAnchor)
            // Fills the tray when the actions are narrower than it, and
            // overflows into scrolling when they aren't.
            actions.widthAnchor.constraint(
                greaterThanOrEqualTo: actionsScrollView.frameLayoutGuide.widthAnchor
            )
        }
        return actionsScrollView
    }

    private func makeActionButton(
        title: String, symbol: String, prominent: Bool, action: @escaping () -> Void
    ) -> UIButton {
        var configuration: UIButton.Configuration = prominent ? .prominentGlass() : .glass()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = Spacing.sm
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: Spacing.lg, bottom: 14, trailing: Spacing.lg
        )
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    // MARK: - Targets

    private func loadTargets() {
        guard let targeting else { return }
        Task { [weak self] in
            let targets = await targeting.shareTargets(limit: Self.targetLimit)
            guard let self, !targets.isEmpty else { return }
            self.targetsView.render(targets)
            // The row's arrival grows the sheet; animate the detent change so
            // it settles rather than jumping.
            self.targetsSection?.isHidden = false
            self.view.setNeedsLayout()
        }
    }

    // MARK: - Actions

    /// Dismisses first, then asks the presenter to open the system sheet.
    ///
    /// Presenting it from here would stack a second sheet on this one — iOS
    /// pushes the underlying card back and shrinks it, so the viewer watches
    /// the QR they just opened slide away behind the thing they asked for.
    /// The card image is rendered BEFORE dismissing: after it, this controller
    /// is on its way out and its trait collection (which supplies the render
    /// scale) is no longer meaningful.
    private func handOffToSystemShare() {
        let image = ProfileShareCard.render(
            ProfileQRCardView(imagePipeline: imagePipeline).configured(with: card),
            width: 320,
            scale: traitCollection.displayScale
        )
        let card = card
        dismiss(animated: true) { [onSystemShare] in
            onSystemShare?(card, image)
        }
    }

    /// Same handoff shape as the system share: the thread is pushed onto the
    /// stack this sheet is covering, so the sheet has to be gone first.
    private func send(to target: ProfileShareTarget) {
        let card = card
        dismiss(animated: true) { [onSendToTarget] in
            onSendToTarget?(target, card)
        }
    }

    private func copyLink() {
        UIPasteboard.general.url = card.url
        UIPasteboard.general.string = card.url.absoluteString
        // Stays put: copying is done, and the sheet is still useful (the QR is
        // right there). Only the actions that LEAVE dismiss first.
        ToastView.present("Link copied", symbol: "link", in: view)
    }

    #if DEBUG
    /// Test hooks — these actions are behind taps the simulator can't inject.
    func qaHandOffToSystemShare() { handOffToSystemShare() }
    func qaSendToFirstTarget() {
        guard let targeting else { return }
        Task { [weak self] in
            guard let target = await targeting.shareTargets(limit: 1).first else { return }
            self?.send(to: target)
        }
    }
    #endif
}

private extension ProfileQRCardView {
    /// Configures and returns self, so a throwaway card can be built inline
    /// for rasterization without a local binding.
    func configured(with card: ProfileViewModel.ShareCard) -> ProfileQRCardView {
        configure(with: card)
        return self
    }
}
