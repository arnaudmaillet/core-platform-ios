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
    private let searchBar = UISearchBar()
    /// Debounces keystrokes into one query, and lets a superseded search be
    /// cancelled rather than racing the one the user is actually typing.
    private var searchTask: Task<Void, Never>?
    private var isSearching = false
    /// The content column, retained because the detent is measured from IT
    /// rather than from `view` — see `viewDidLayoutSubviews`.
    private let column = UIStackView()

    /// The measured content height the custom detent resolves to. Seeded with
    /// an estimate so the sheet has a sane height for its very first frame,
    /// then replaced by the real measurement (see `viewDidLayoutSubviews`).
    private var contentHeight: CGFloat = 640
    private static let detentIdentifier = UISheetPresentationController.Detent.Identifier("profileShare")
    /// How many people the quick-send row asks for.
    private static let targetLimit = 12
    /// Search results fit a vertical list, so it can afford more than the row.
    private static let searchResultLimit = 30
    /// The ONE inset in this sheet: sheet edge → card on all three visible
    /// sides, the margin every section indents by, and the content inset the
    /// two scrolling rows use. Being a single number is what makes the card's
    /// gaps symmetric and its corner radius derivable (`sheetRadius - margin`),
    /// and what keeps the card's edge aligned with the "Send to" heading's.
    private static let margin = Spacing.lg
    /// The search bar's row, hidden until search is entered.
    private var searchBarSection: UIView?
    /// Everything search mode puts away: the card, the horizontal row, the
    /// actions, and the rules between them. Searching is a focused state —
    /// see `setSearching`.
    private var nonSearchSections: [UIView] = []

    /// Search results, as a standard vertical list.
    ///
    /// Lives OUTSIDE the content column and fills the space beneath it, rather
    /// than being another arranged subview: the column is sized to its content
    /// (that is what drives the detent), and a list wants the opposite — every
    /// point that is left. Its bottom rides `keyboardLayoutGuide`, so the last
    /// row always clears the keyboard.
    private lazy var resultsView: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        // The sheet's glass is the background; a list appearance colour here
        // would paint over it.
        configuration.backgroundColor = .clear
        let list = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        list.backgroundColor = .clear
        list.keyboardDismissMode = .onDrag
        list.delegate = self
        list.isHidden = true
        return list
    }()
    private lazy var resultsSource = makeResultsSource()
    private let emptyResultsLabel = UILabel()

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
        // Two detents, but only one is ever *offered*: the content-sized one
        // the sheet lives at, and `.large()` it moves to while searching —
        // where the keyboard has somewhere to go. Switching between them is
        // driven by `setSearching`, never by the user dragging.
        sheet.detents = [
            .custom(identifier: Self.detentIdentifier) { [weak self] context in
                guard let self else { return context.maximumDetentValue * 0.7 }
                return min(self.contentHeight, context.maximumDetentValue)
            },
            .large()
        ]
        sheet.selectedDetentIdentifier = Self.detentIdentifier
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
        configureResultsList()
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
        // Concentric by construction: a shape inset by `margin` inside a
        // rounded rect keeps a curve parallel to it when its own radius is
        // reduced by exactly that inset. The card is inset by `margin` on
        // every visible side, so this is the radius that makes its corners
        // follow the sheet's rather than merely resemble them.
        cardView.setCornerRadius(max(radius - Self.margin, 8))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Measured from the COLUMN, not from `view`.
        //
        // The column is pinned to the view's top AND bottom, which means any
        // height ≥ the content satisfies the constraints — so asking `view`
        // for its fitting size returns whatever height it currently has, not
        // the smallest that would work. The detent therefore never tightened:
        // it sat at its seeded estimate, the stack stretched to fill, and the
        // slack surfaced as dead space under the action tray. Asking the
        // column (whose height is genuinely content-driven) and re-adding the
        // insets by hand gives the minimum the sheet can actually be.
        guard view.bounds.width > 0 else { return }
        // The column's LAID-OUT height, not a fitting estimate. Now that it is
        // top-anchored only, its frame is exactly its content — and the
        // estimate ran ~16pt high, which the sheet then had to park somewhere
        // (under the tray, naturally).
        let columnHeight = column.bounds.height
        // Symmetric: the same `margin` above the card and below the tray, and
        // nothing else.
        //
        // The safe-area inset used to be added here, and it was the dead space
        // under the chips. A content-sized detent makes this a FLOATING sheet
        // — its bottom edge sits above the screen's, so the home indicator is
        // outside it entirely — while `view.safeAreaInsets.bottom` still
        // reports the window's 34pt. Reserving that inside the sheet paid for
        // the indicator twice.
        let fitted = Self.margin + columnHeight + Self.margin
        guard columnHeight > 0, abs(fitted - contentHeight) > 1 else { return }
        contentHeight = fitted
        #if DEBUG
        // Dev convenience: the sheet's height is derived, not authored, so the
        // numbers behind it are worth being able to read. Sizing bugs here are
        // invisible in a screenshot — the dead space under the tray was two
        // separate ones (a stretched stack, then a double-counted safe area),
        // and both were only obvious from these figures.
        if ProcessInfo.processInfo.arguments.contains("-profile-share-demo") {
            print("SHARE-SHEET-AUDIT column=\(Int(columnHeight)) detent=\(Int(fitted)) "
                + "sheet=\(Int(view.bounds.height)) "
                + "belowColumn=\(Int(view.bounds.height - column.frame.maxY)) "
                + "sections=\(column.arrangedSubviews.map { Int($0.bounds.height.rounded()) })")
        }
        #endif
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
        targetsView.onSelect = { [weak self] target in self?.send(to: target) }
        targetsView.onSearch = { [weak self] in self?.setSearching(true) }
        // No section heading: the row's leading Search bubble and the faces
        // beside it say what it is, and a label over them was the only text in
        // the sheet that named a section rather than an action.
        targetsView.renderSkeletons()

        searchBar.placeholder = "Search profiles"
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.showsCancelButton = true
        searchBar.isHidden = true

        let cardSection = makeCardSection()
        let topDivider = makeDivider()
        let searchSection = inset(searchBar)
        let bottomDivider = makeDivider()
        let actions = makeActionsTray()
        for section in [cardSection, topDivider, searchSection, targetsView, bottomDivider, actions] {
            column.addArrangedSubview(section)
        }
        searchBarSection = searchSection
        searchSection.isHidden = true
        nonSearchSections = [cardSection, topDivider, targetsView, bottomDivider, actions]
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.md
        column.constrain(in: view) { parent in
            // Top gap equals the card's side gap, so the card sits in a
            // symmetric well. The grabber floats in this same strip — it is
            // drawn over the sheet's edge and reserves no space — which is
            // tight but correct; giving the top extra room to clear it is what
            // made the card look off-centre before.
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: Self.margin)
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            // NOT pinned to the bottom — deliberately.
            //
            // Pinning both ends means any height ≥ the content satisfies the
            // layout, so a sheet even slightly taller than its content makes
            // the stack stretch, and `.fill` hands that slack to whichever
            // arranged view hugs least: the two scroll views, which have no
            // intrinsic height at all. The action tray measured 114pt against
            // ~84pt of content that way, and the surplus read as dead space
            // under the chips. Top-anchored only, the column's height is purely
            // its content, and the bottom spacing is whatever the detent below
            // reserves for it.
        }
    }

    /// A native hairline: one physical pixel in the system separator colour,
    /// inset by the sheet's margin so it floats between sections rather than
    /// cutting the sheet in half edge to edge. The scrolling rows still bleed
    /// past it — they are content, the rule is punctuation.
    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(
            equalToConstant: 1 / max(traitCollection.displayScale, 1)
        ).isActive = true
        return inset(divider)
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

    /// The card is inset by `margin` on both sides — the same number the top
    /// gap and every other section use — rather than capped and centred.
    ///
    /// A fixed cap was tried and abandoned: it left the card's side gaps
    /// (whatever the screen happened to leave over) unrelated to its top gap,
    /// so the card never sat squarely in the sheet, and there was no single
    /// inset to derive a concentric radius from. The QR fills the card's width
    /// inside its own quiet zone, so the card's height follows its width —
    /// which is why widening it here is paid for by the tightened top, bottom
    /// and section spacing rather than by shrinking the code.
    private func makeCardSection() -> UIView {
        let container = UIView()
        cardView.constrain(in: container) { parent in
            cardView.topAnchor.constraint(equalTo: parent.topAnchor)
            cardView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            cardView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.margin)
            cardView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.margin)
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
        guard let targeting else {
            targetsView.render([])
            return
        }
        Task { [weak self] in
            let targets = await targeting.shareTargets(limit: Self.targetLimit)
            guard let self, !self.isSearching else { return }
            // Renders even when empty: the row keeps its Search bubble, which
            // is the whole point of it leading the row.
            self.targetsView.render(targets)
        }
    }

    // MARK: - Search

    /// Enters or leaves search. The sheet moves to `.large()` while searching
    /// because the keyboard needs the room; the content-sized detent is
    /// restored on the way out.
    private func setSearching(_ searching: Bool) {
        guard isSearching != searching else { return }
        isSearching = searching
        searchTask?.cancel()
        searchTask = nil

        // Search takes the sheet over: the card, the actions and the rules go
        // away, leaving the field and the results at the top. Keeping the card
        // pushed both of them under the keyboard — the results were on screen
        // in the layout and invisible in practice.
        searchBarSection?.isHidden = !searching
        searchBar.isHidden = !searching
        for section in nonSearchSections {
            section.isHidden = searching
        }
        resultsView.isHidden = !searching
        emptyResultsLabel.isHidden = true
        if !searching {
            applyResults([])
        }
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = searching
                ? .large
                : Self.detentIdentifier
        }

        if searching {
            searchBar.becomeFirstResponder()
        } else {
            searchBar.text = nil
            searchBar.resignFirstResponder()
            // The horizontal row was never torn down, only hidden — but it is
            // re-read so a stale suggestion set can't outlive a long search.
            targetsView.renderSkeletons()
            loadTargets()
        }
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let targeting, !trimmed.isEmpty else {
            applyResults([])
            emptyResultsLabel.isHidden = true
            return
        }
        searchTask = Task { [weak self] in
            // Debounce: a keystroke every ~50ms would otherwise put a search
            // per character on the wire, and the answers would land out of
            // order. The previous results stay on screen meanwhile — blanking
            // the list on every keystroke flickers far worse than a stale row
            // for 250ms.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = await targeting.searchTargets(query: trimmed, limit: Self.searchResultLimit)
            guard let self, !Task.isCancelled, self.isSearching else { return }
            self.applyResults(results)
            self.emptyResultsLabel.isHidden = !results.isEmpty
        }
    }

    // MARK: - Results list

    private func configureResultsList() {
        emptyResultsLabel.text = "No profiles found"
        emptyResultsLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyResultsLabel.adjustsFontForContentSizeCategory = true
        emptyResultsLabel.textColor = .secondaryLabel
        emptyResultsLabel.textAlignment = .center
        emptyResultsLabel.isHidden = true

        resultsView.constrain(in: view) { parent in
            // Directly under the column, which in search mode holds only the
            // search field — so the field stays pinned at the top and the list
            // owns everything below it.
            resultsView.topAnchor.constraint(equalTo: column.bottomAnchor, constant: Spacing.sm)
            resultsView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            resultsView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            resultsView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
        emptyResultsLabel.constrain(in: view) { parent in
            emptyResultsLabel.topAnchor.constraint(equalTo: resultsView.topAnchor, constant: Spacing.xxl)
            emptyResultsLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.margin)
            emptyResultsLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.margin)
        }
    }

    private enum ResultsSection { case results }

    private func makeResultsSource() -> UICollectionViewDiffableDataSource<ResultsSection, ProfileShareTarget> {
        let registration = UICollectionView.CellRegistration<ProfileSearchResultCell, ProfileShareTarget> {
            [imagePipeline] cell, _, target in
            cell.configure(with: target, imagePipeline: imagePipeline)
        }
        return UICollectionViewDiffableDataSource(collectionView: resultsView) { collection, indexPath, target in
            collection.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: target
            )
        }
    }

    private func applyResults(_ targets: [ProfileShareTarget]) {
        var snapshot = NSDiffableDataSourceSnapshot<ResultsSection, ProfileShareTarget>()
        snapshot.appendSections([.results])
        snapshot.appendItems(targets)
        resultsSource.apply(snapshot, animatingDifferences: true)
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
    func qaCancelSearch() { setSearching(false) }
    /// Goes through the real delegate + data-source lookup, not a shortcut
    /// around them — selecting a row is the path under test.
    func qaSelectFirstResult() {
        let first = IndexPath(item: 0, section: 0)
        guard resultsSource.itemIdentifier(for: first) != nil else { return }
        collectionView(resultsView, didSelectItemAt: first)
    }
    func qaBeginSearch(_ query: String) {
        setSearching(true)
        searchBar.text = query
        runSearch(query)
    }
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

extension ProfileShareViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        runSearch(searchText)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        setSearching(false)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        // Dismiss the keyboard but stay in search: the results are the point,
        // and they are behind the keyboard on the smaller phones.
        searchBar.resignFirstResponder()
    }
}

extension ProfileShareViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let target = resultsSource.itemIdentifier(for: indexPath) else { return }
        // Exactly the quick-send path: dismiss, then open the thread with the
        // link pre-typed. A result and a suggestion are the same act.
        send(to: target)
    }
}
