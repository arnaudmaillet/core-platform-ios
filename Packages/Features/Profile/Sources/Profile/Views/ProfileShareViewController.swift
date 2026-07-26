import CoreNavigation
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

    /// The sheet's own Liquid Glass surface. UIKit gives a `.pageSheet` an
    /// opaque background; this replaces it, so the profile underneath stays
    /// present as a blurred backdrop instead of being painted over.
    private let glassBackdrop = UIVisualEffectView(effect: nil)
    private let cardView: ProfileQRCardView
    private let targetsView: ProfileShareTargetsView
    private let targetsHeading = UILabel()
    private var targetsSection: UIStackView?
    private var targetsDivider: UIView?

    /// The measured content height the custom detent resolves to. Seeded with
    /// an estimate so the sheet has a sane height for its very first frame,
    /// then replaced by the real measurement (see `viewDidLayoutSubviews`).
    private var contentHeight: CGFloat = 640
    private static let detentIdentifier = UISheetPresentationController.Detent.Identifier("profileShare")
    /// How many people the quick-send row asks for.
    private static let targetLimit = 12
    /// Ceiling on the card's width; it centres below that on wider screens.
    private static let cardMaxWidth: CGFloat = 296
    /// The sheet's horizontal margin. Tighter than the app's page margin: a
    /// sheet this size is content, not a page, and the full-bleed rows need
    /// the width more than the edges need the air.
    private static let margin = Spacing.lg

    init(
        card: ProfileViewModel.ShareCard,
        imagePipeline: ImagePipeline,
        targeting: (any ProfileShareTargeting)?
    ) {
        self.card = card
        self.imagePipeline = imagePipeline
        self.targeting = targeting
        cardView = ProfileQRCardView(imagePipeline: imagePipeline)
        targetsView = ProfileShareTargetsView(imagePipeline: imagePipeline, inset: Self.margin)
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Cleared, not coloured: the glass backdrop below IS the surface. A
        // background colour here would sit over the blur and defeat it — and
        // semantic colours resolve translucent inside an iOS 26 sheet anyway
        // (the trap `ProfileQRCardView` documents).
        view.backgroundColor = .clear
        glassBackdrop.pin(to: view)
        configureViews()
        cardView.configure(with: card)
        loadTargets()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        materializeGlass()
        matchSheetCornersToDevice()
    }

    /// Materialized on window attach, never in init: building a real effect
    /// off-screen contacts the render server and stalls the main actor for
    /// tens of seconds on headless CI simulators (the rule `ChatInputBar`,
    /// `SearchDockView`, and `ToastView` all follow).
    private func materializeGlass() {
        guard view.window != nil, glassBackdrop.effect == nil else { return }
        glassBackdrop.effect = UIGlassEffect(style: .regular)
    }

    /// Rounds the sheet to the physical display's own corner radius, so its
    /// shoulders sit concentric with the bezel rather than close-but-not-quite.
    /// Reading the radius needs a window, hence `viewDidAppear`.
    private func matchSheetCornersToDevice() {
        let radius = ScreenGeometry.cornerRadius(behind: view)
        guard radius > 0, sheetPresentationController?.preferredCornerRadius != radius else { return }
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.preferredCornerRadius = radius
        }
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

    // MARK: - Layout

    /// Three sections separated by hairlines, in a column pinned EDGE TO EDGE.
    ///
    /// The margin is applied per section rather than to the column, because
    /// the two scrolling rows have to reach the sheet's edges: their content
    /// insets do the visual indenting, so an avatar or a chip scrolls in from
    /// under the corner instead of being clipped against a margin. Sections
    /// that don't scroll inset themselves.
    private func configureViews() {
        targetsHeading.text = "Send to"
        targetsHeading.font = .preferredFont(forTextStyle: .footnote)
        targetsHeading.adjustsFontForContentSizeCategory = true
        targetsHeading.textColor = .secondaryLabel
        targetsView.onSelect = { [weak self] target in self?.send(to: target) }

        let targets = UIStackView(arrangedSubviews: [inset(targetsHeading), targetsView])
        targets.axis = .vertical
        targets.alignment = .fill
        targets.spacing = Spacing.sm
        // Hidden — divider and all — until the row has someone in it. The
        // heading must not stand alone over an empty strip while the graph
        // read is in flight.
        targets.isHidden = true
        targetsSection = targets

        let divider = makeDivider()
        divider.isHidden = true
        targetsDivider = divider

        let column = UIStackView(arrangedSubviews: [
            makeCardSection(), divider, targets, makeDivider(), makeActionsTray()
        ])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.lg
        column.constrain(in: view) { parent in
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xxl)
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            column.bottomAnchor.constraint(
                equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg
            )
        }
    }

    /// A native hairline: one physical pixel in the system separator colour,
    /// full-bleed like the sections it divides.
    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(
            equalToConstant: 1 / max(traitCollection.displayScale, 1)
        ).isActive = true
        return divider
    }

    /// Wraps a view in the sheet's horizontal margin, for sections that don't
    /// bleed to the edges.
    private func inset(_ content: UIView) -> UIView {
        let container = UIView()
        content.constrain(in: container) { parent in
            content.topAnchor.constraint(equalTo: parent.topAnchor)
            content.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            content.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.margin)
            content.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.margin)
        }
        return container
    }

    /// The card is centred and capped rather than full-bleed: at full sheet
    /// width the code alone runs past 300pt, which pushes everything below it
    /// so far down the sheet swallows the screen. A QR only has to be big
    /// enough to scan.
    private func makeCardSection() -> UIView {
        let container = UIView()
        let cardWidth = cardView.widthAnchor.constraint(equalToConstant: Self.cardMaxWidth)
        // Yields to the sheet's width on a screen too narrow for it, so the
        // cap can never force a horizontal overflow.
        cardWidth.priority = .defaultHigh
        cardView.constrain(in: container) { parent in
            cardView.topAnchor.constraint(equalTo: parent.topAnchor)
            cardView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            cardView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: parent.leadingAnchor, constant: Self.margin)
            cardWidth
        }
        return container
    }

    /// The actions tray: the system share sheet's own shape — a Liquid Glass
    /// circle per action with its label beneath — on a full-bleed horizontal
    /// scroll view, so further actions land without a re-layout.
    private func makeActionsTray() -> UIView {
        let actions = UIStackView(arrangedSubviews: [
            ProfileShareActionChip(
                title: "Share", symbol: "square.and.arrow.up", prominent: true
            ) { [weak self] in self?.handOffToSystemShare() },
            ProfileShareActionChip(title: "Copy Link", symbol: "link", prominent: false) { [weak self] in
                self?.copyLink()
            }
        ])
        actions.axis = .horizontal
        // Top-aligned: a chip whose caption wraps to two lines must not push
        // its neighbours' circles out of line.
        actions.alignment = .top
        actions.spacing = Spacing.md

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        // The inset is the visual margin; the scroll view itself reaches the
        // sheet's edges, so a chip scrolls in from under the corner rather
        // than stopping against a margin.
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.margin, bottom: 0, right: Self.margin)
        // Off, so a chip's glass edge isn't shaved at the tray's bounds.
        scrollView.clipsToBounds = false
        actions.constrain(in: scrollView) { parent in
            actions.topAnchor.constraint(equalTo: parent.topAnchor)
            actions.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            actions.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            actions.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            actions.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        }
        return scrollView
    }

    // MARK: - Targets

    private func loadTargets() {
        guard let targeting else { return }
        Task { [weak self] in
            let targets = await targeting.shareTargets(limit: Self.targetLimit)
            guard let self, !targets.isEmpty else { return }
            self.targetsView.render(targets)
            self.targetsSection?.isHidden = false
            self.targetsDivider?.isHidden = false
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
