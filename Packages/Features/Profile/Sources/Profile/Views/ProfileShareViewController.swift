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
    private let deviceCornerRadius: CGFloat

    /// The sheet's own Liquid Glass surface. UIKit gives a `.pageSheet` an
    /// opaque background; this replaces it, so the profile underneath stays
    /// present as a blurred backdrop instead of being painted over.
    private let glassBackdrop = UIVisualEffectView(effect: nil)
    private let cardView: ProfileQRCardView
    private let targetsView: ProfileShareTargetsView
    private let searchBar = UISearchBar()
    /// Our own Cancel, not `UISearchBar.showsCancelButton`.
    ///
    /// ⚠️ UIKit DISABLES the built-in cancel button whenever the search bar is
    /// not first responder, and there is no public API to override it —
    /// `setShowsCancelButton` controls visibility, not enablement. Lowering the
    /// keyboard interactively therefore left the only exit from search dead.
    /// A button we own cannot be disabled behind our back.
    private let cancelSearchButton = UIButton(type: .system)
    /// The Close button's Liquid Glass lens. A real `UIGlassEffect` rather than
    /// `UIButton.Configuration.glass()`, so its tint can be set — see
    /// `materializeGlass`.
    private let cancelGlass = UIVisualEffectView(effect: nil)
    /// Debounces keystrokes into one query, and lets a superseded search be
    /// cancelled rather than racing the one the user is actually typing.
    private var searchTask: Task<Void, Never>?
    private var isSearching = false
    /// The content column, retained because the detent is measured from IT
    /// rather than from `view` — see `viewDidLayoutSubviews`.
    private let column = UIStackView()

    /// Fallback used only before the content can be measured — see
    /// `fittedContentHeight`.
    private let contentHeight: CGFloat = 640
    /// The presenter's width, for the same frames.
    private let fallbackWidth: CGFloat
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
    /// The search row's fixed height. Fixed on purpose: it makes the list's
    /// top inset a constant the view controller can set declaratively, instead
    /// of a measurement taken during layout.
    private static let searchRowHeight: CGFloat = 44
    private static let cancelDiameter: CGFloat = 34
    /// The search bar's row, hidden until search is entered.
    private var searchBarSection: UIView?
    /// Everything search mode puts away: the card, the horizontal row, the
    /// actions, and the rules between them. Searching is a focused state —
    /// see `setSearching`.
    private var nonSearchSections: [UIView] = []

    /// Search results, as a standard vertical list.
    ///
    /// Lives OUTSIDE the content column and fills the WHOLE sheet, rather than
    /// being another arranged subview: the column is sized to its content (that
    /// is what drives the detent), and a list wants the opposite — every point
    /// there is. The search row floats over it; insets, not constraints, keep
    /// the rows clear of that row and of the keyboard.
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
        // `.interactive`, not `.onDrag`: dragging the results carries the
        // keyboard down with the finger instead of snapping it away. It is the
        // gesture people actually reach for, and it lets them clear the
        // keyboard WITHOUT leaving search — which matters more now that the
        // sheet itself is locked while searching.
        list.keyboardDismissMode = .interactive
        list.delegate = self
        list.isHidden = true
        return list
    }()
    private lazy var resultsSource = makeResultsSource()
    /// Keyboard overlap, in this view's coordinates. Applied as the list's
    /// bottom content inset rather than a constraint — see `configureResultsList`.
    private var keyboardOverlap: CGFloat = 0
    private let emptyResultsLabel = UILabel()
    private let resultsSpinner = UIActivityIndicatorView(style: .medium)
    /// The suggestion set, retained so entering search can show it instantly.
    /// An empty list behind a blinking cursor reads as "no one to send to";
    /// the people you'd most likely pick are already in hand.
    private var suggestedTargets: [ProfileShareTarget] = []
    /// Set when the graph answers WHILE searching, where the horizontal row is
    /// hidden and skips its render. Leaving search then owes it one — and only
    /// then, which is what keeps the ordinary return free of any re-render.
    private var suggestionsAwaitingRender = false

    /// - Parameter deviceCornerRadius: the physical display's corner radius,
    ///   read by the PRESENTER (which has a window) and handed in.
    ///
    ///   This used to be read here, in `viewDidAppear`, from
    ///   `ScreenGeometry.cornerRadius(behind: view)` — and that is too late by
    ///   construction: the sheet has no window until it is on screen, so the
    ///   whole presentation animated with UIKit's default radius and the
    ///   corners snapped to the device's the instant it finished. Taking it as
    ///   an input means `preferredCornerRadius` is set before the first frame.
    init(
        card: ProfileViewModel.ShareCard,
        imagePipeline: ImagePipeline,
        targeting: (any ProfileShareTargeting)?,
        deviceCornerRadius: CGFloat,
        fallbackWidth: CGFloat
    ) {
        self.card = card
        self.imagePipeline = imagePipeline
        self.targeting = targeting
        self.deviceCornerRadius = deviceCornerRadius
        self.fallbackWidth = fallbackWidth
        cardView = ProfileQRCardView(imagePipeline: imagePipeline)
        targetsView = ProfileShareTargetsView(imagePipeline: imagePipeline, inset: Self.margin)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        configureDetent()
        // Concentric by construction, and settled before presentation for the
        // same reason: a shape inset by `margin` inside a rounded rect keeps a
        // curve parallel to it when its radius is reduced by exactly that.
        if deviceCornerRadius > 0 {
            cardView.setCornerRadius(max(deviceCornerRadius - Self.margin, 8))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One detent, sized to the content — not `.medium()`, which is a fixed
    /// fraction of the screen and would park a fixed-height card above a dead
    /// gap. Nothing here scrolls vertically or expands, so a second detent
    /// would only offer the user a worse version of this one.
    /// The content-sized detent. Rebuilt per install because changing modes
    /// replaces the whole `detents` array.
    private func contentDetent() -> UISheetPresentationController.Detent {
        .custom(identifier: Self.detentIdentifier) { [weak self] context in
            guard let self else { return context.maximumDetentValue * 0.7 }
            return min(self.fittedContentHeight(), context.maximumDetentValue)
        }
    }

    private func configureDetent() {
        guard let sheet = sheetPresentationController else { return }
        // EXACTLY ONE detent is installed at a time — see `applySheetMode`.
        //
        // This used to install both the content-sized detent and `.large()`
        // together, with a comment claiming the user could not drag between
        // them. That was simply untrue: a sheet holding two detents is always
        // draggable between them, which is how the sheet came to slide down
        // behind an open keyboard during search.
        sheet.detents = [contentDetent()]
        sheet.selectedDetentIdentifier = Self.detentIdentifier
        sheet.prefersGrabberVisible = true
        // Set HERE, from init — not in `viewDidAppear`. See the initializer.
        if deviceCornerRadius > 0 {
            sheet.preferredCornerRadius = deviceCornerRadius
        }
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
        observeKeyboard()
        cardView.configure(with: card)
        loadTargets()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        materializeGlass()
    }

    /// Materialized on window attach, never in init: building a real effect
    /// off-screen contacts the render server and stalls the main actor for
    /// tens of seconds on headless CI simulators (the rule `ChatInputBar`,
    /// `SearchDockView`, and `ToastView` all follow).
    private func materializeGlass() {
        guard view.window != nil else { return }
        if glassBackdrop.effect == nil {
            glassBackdrop.effect = UIGlassEffect(style: .regular)
        }
        if cancelGlass.effect == nil {
            let glass = UIGlassEffect(style: .regular)
            // The native press response — the lens flexes under a touch rather
            // than sitting inert. It IS a touch target, so it should answer to
            // being pressed (the same call `SearchDockView` makes).
            glass.isInteractive = true
            cancelGlass.effect = glass
        }
    }

    /// The sheet's height, resolved on demand by the detent itself.
    ///
    /// ⚠️ This is deliberately NOT measured in `viewDidLayoutSubviews` and
    /// pushed with `invalidateDetents()`. That is a layout loop and it
    /// crashed: invalidating asks this resolver, the answer resizes the sheet,
    /// the resize lays out again, and dragging the sheet — which changes its
    /// height every frame — recursed until the stack blew (`EXC_BAD_ACCESS`).
    /// `animateChanges` around it made it worse by fighting the drag.
    ///
    /// Nothing needs to push a height any more: the content is static by
    /// construction. The card's height follows its width (fixed by the sheet's
    /// margins), the quick-send row has a fixed height and shows skeletons from
    /// its first frame, and the tray is a row of fixed chips. So the detent can
    /// simply ASK, and gets the same answer every time it does.
    private func fittedContentHeight() -> CGFloat {
        // The sheet is full-width on iPhone, so the presenter's width is the
        // right fallback for the frames before this view has been sized.
        let width = view.bounds.width > 0 ? view.bounds.width : fallbackWidth
        guard width > 0 else { return contentHeight }
        let columnHeight = column.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard columnHeight > 0 else { return contentHeight }
        // Symmetric: the same `margin` above the card and below the tray.
        //
        // No safe-area inset. A content-sized detent makes this a FLOATING
        // sheet — its bottom edge sits above the screen's, so the home
        // indicator is outside it entirely — while `safeAreaInsets.bottom`
        // still reports the window's. Adding it paid for the indicator twice.
        return Self.margin + columnHeight + Self.margin
    }

    /// READ-ONLY. ⚠️ Mutating layout here is what caused the crash: measuring
    /// the content and pushing it back with `invalidateDetents()` re-entered
    /// layout and recursed until the stack blew. Nothing that can dirty layout
    /// belongs in this method — the list's insets are set declaratively from
    /// `setSearching` for exactly that reason.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-profile-share-demo") else { return }
        print("RIGID-AUDIT view=\(Int(view.bounds.width))x\(Int(view.bounds.height)) "
            + "column=\(Int(column.bounds.width))x\(Int(column.bounds.height)) "
            + "card=\(Int(cardView.bounds.width))x\(Int(cardView.bounds.height)) "
            + "inset=\(Int(resultsView.contentInset.top))/\(Int(resultsView.contentInset.bottom))")
        #endif
    }

    // MARK: - Layout

    /// Three sections separated by hairlines, in a column pinned EDGE TO EDGE.
    ///
    /// The margin is applied per section rather than to the column, because
    /// the two scrolling rows have to reach the sheet's edges: their content
    /// insets do the visual indenting, so an avatar or a chip scrolls in from
    /// under the corner instead of being clipped against a margin. Sections
    /// that don't scroll inset themselves.
    /// Pins every band of the sheet at `.required` on the vertical axis.
    ///
    /// Auto Layout resolves a shortfall by squeezing whatever is cheapest, and
    /// the QR card — a code whose whole job is to be a fixed grid of squares —
    /// was the cheapest thing in the column. With these set there is nothing in
    /// the stack that can absorb a shortfall, so a drag can only ever translate
    /// the sheet; it cannot re-proportion what is inside it.
    private func makeContentRigid(_ views: [UIView]) {
        for view in views {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            view.setContentHuggingPriority(.required, for: .vertical)
        }
    }

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
        searchBar.isHidden = true

        cancelSearchButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            ),
            for: .normal
        )
        cancelSearchButton.tintColor = .label
        cancelSearchButton.accessibilityLabel = "Cancel search"
        cancelSearchButton.addAction(
            UIAction { [weak self] _ in self?.setSearching(false) }, for: .primaryActionTriggered
        )
        // The lens is the chrome; the button is just the glyph and the target.
        cancelGlass.clipsToBounds = true
        cancelGlass.cornerConfiguration = .capsule()
        cancelSearchButton.pin(to: cancelGlass.contentView)
        NSLayoutConstraint.activate([
            cancelGlass.widthAnchor.constraint(equalToConstant: Self.cancelDiameter),
            cancelGlass.heightAnchor.constraint(equalToConstant: Self.cancelDiameter)
        ])

        let searchRow = UIStackView(arrangedSubviews: [searchBar, cancelGlass])
        searchRow.axis = .horizontal
        searchRow.alignment = .center
        searchRow.spacing = Spacing.sm
        // Fixed, so the list's top inset is a constant rather than something
        // measured during layout — see `Metrics.searchRowHeight`.
        searchRow.heightAnchor.constraint(equalToConstant: Self.searchRowHeight).isActive = true

        let cardSection = makeCardSection()
        let topDivider = makeDivider()
        let searchSection = inset(searchRow)
        let bottomDivider = makeDivider()
        let actions = makeActionsTray()
        for section in [cardSection, topDivider, searchSection, targetsView, bottomDivider, actions] {
            column.addArrangedSubview(section)
        }
        searchBarSection = searchSection
        searchSection.isHidden = true
        nonSearchSections = [cardSection, topDivider, targetsView, bottomDivider, actions]
        // The card, the quick-send row, the actions tray, their containers, and
        // the column itself: none of them may give up height.
        makeContentRigid([cardView, cardSection, targetsView, actions, column])
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
        // Rigidity for the card and its container is set together with every
        // other band in `makeContentRigid`.
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

    // MARK: - Result list insets

    /// Holds the rows clear of the floating search row.
    ///
    /// `additionalSafeAreaInsets`, NOT `contentInset` — and the difference is
    /// the whole point. `UIScrollEdgeEffect` anchors its fade to the scroll
    /// view's SAFE AREA edge, so a content inset left the soft fade stranded at
    /// the sheet's top while rows slid sharply under a bar 88pt lower. Insetting
    /// the safe area puts the fade exactly where the bar is, which is how the
    /// system's own bars do it.
    ///
    /// Set from `setSearching`, never from a layout callback: the row's height
    /// is a constant, so there is nothing to measure.
    private func applyResultsInset(searching: Bool) {
        additionalSafeAreaInsets.top = searching
            ? Self.margin + Self.searchRowHeight + Spacing.sm
            : 0
    }

    /// Tracks the keyboard so the list can inset around it.
    ///
    /// Notifications rather than a `keyboardLayoutGuide` constraint: the guide
    /// is window-relative, and tying the list's frame to it is exactly what
    /// crushed the card during a drag. An inset changes only what the scroll
    /// view considers reachable, so it cannot resize anything.
    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = view.window else { return }
        // The keyboard frame is in screen coordinates; the overlap that matters
        // is with THIS view, which on a floating sheet does not reach the
        // screen's bottom.
        let inView = view.convert(window.convert(end, from: nil), from: window)
        applyKeyboardOverlap(max(0, view.bounds.maxY - inView.minY), note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        applyKeyboardOverlap(0, note: note)
    }

    private func applyKeyboardOverlap(_ overlap: CGFloat, note: Notification) {
        guard abs(keyboardOverlap - overlap) > 0.5 else { return }
        keyboardOverlap = overlap
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) {
            self.resultsView.contentInset.bottom = overlap
            self.resultsView.verticalScrollIndicatorInsets.bottom = overlap
        }
    }

    // MARK: - Targets

    private func loadTargets() {
        guard let targeting else {
            targetsView.render([])
            return
        }
        Task { [weak self] in
            let targets = await targeting.shareTargets(limit: Self.targetLimit)
            guard let self else { return }
            self.suggestedTargets = targets
            // If search opened before the graph answered, its list is waiting
            // on exactly these.
            if self.isSearching, self.searchBar.text?.isEmpty != false {
                self.showSuggestionsInResults()
            }
            guard !self.isSearching else {
                // The row is hidden; render it on the way back out instead of
                // into a view nobody is looking at.
                self.suggestionsAwaitingRender = true
                return
            }
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
        emptyResultsLabel.isHidden = true
        // `setSpinning` owns the list's visibility, so it runs after
        // `isSearching` has been updated above.
        setSpinning(false)
        if !searching {
            applyResults([])
        }
        // Grow before raising the keyboard, and dismiss the keyboard before
        // shrinking — so the sheet is never asked to resize around a keyboard
        // that is about to move. A precaution rather than a fix for anything
        // observed: the reverse order also worked in the simulator.
        applyResultsInset(searching: searching)
        if searching {
            applySheetMode(searching: true)
            showSuggestionsInResults()
            searchBar.becomeFirstResponder()
        } else {
            searchBar.text = nil
            searchBar.resignFirstResponder()
            applySheetMode(searching: false)
            restoreSuggestionsRow()
        }
    }

    /// Puts the horizontal row back on screen when leaving search.
    ///
    /// Deliberately does NOT re-render or re-fetch. The row is only ever
    /// HIDDEN while searching — its items are still built and its avatars
    /// still decoded — so unhiding it is the whole restore, and it is
    /// instantaneous. The previous version tore it down to skeletons and
    /// re-read the social graph here, which flashed a loading state over data
    /// the sheet already had.
    ///
    /// The single exception is a graph answer that landed mid-search, where
    /// the row skipped its render; that one is settled from the cache, still
    /// without touching the network.
    private func restoreSuggestionsRow() {
        guard suggestionsAwaitingRender else { return }
        suggestionsAwaitingRender = false
        targetsView.render(suggestedTargets)
    }

    /// Swaps the sheet between its two modes, and LOCKS it while searching.
    ///
    /// Only one detent is offered at a time, so there is nothing to drag
    /// between; and `isModalInPresentation` withholds the pull-to-dismiss
    /// gesture, so the sheet cannot travel downward at all while the keyboard
    /// is up. Together those make the sheet-behind-keyboard overlap impossible
    /// by construction rather than something to race against.
    ///
    /// ⚠️ The pull-down is genuinely GONE while searching, not re-purposed.
    /// `presentationControllerDidAttemptToDismiss` was wired here first, on the
    /// assumption UIKit would report the swipe — it does not. With one detent
    /// and `isModalInPresentation` there is nothing to resize and nothing to
    /// dismiss, so the sheet's pan recognizer is never armed and the delegate
    /// never fires (verified across five drag origins). Cancel is the exit;
    /// the list's `.interactive` keyboard dismissal is how the keyboard is
    /// cleared without leaving search.
    private func applySheetMode(searching: Bool) {
        guard let sheet = sheetPresentationController else { return }
        isModalInPresentation = searching
        sheet.animateChanges {
            sheet.detents = searching ? [.large()] : [contentDetent()]
            sheet.selectedDetentIdentifier = searching ? .large : Self.detentIdentifier
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-profile-share-demo") {
            print("SHEET-MODE searching=\(searching) "
                + "detents=\(sheet.detents.count) "
                + "selected=\(sheet.selectedDetentIdentifier?.rawValue ?? "nil") "
                + "fitted=\(Int(fittedContentHeight())) "
                + "viewH=\(Int(view.bounds.height))")
        }
        #endif
    }

    /// The list's resting content in search mode: the same people the
    /// horizontal row suggests, or a spinner if they haven't landed yet.
    private func showSuggestionsInResults() {
        searchTask?.cancel()
        searchTask = nil
        emptyResultsLabel.isHidden = true
        applyResults(suggestedTargets)
        setSpinning(suggestedTargets.isEmpty && targeting != nil)
    }

    /// The spinner REPLACES the list rather than floating over it: an
    /// indicator laid on top of the previous query's rows reads as "these
    /// results are loading", which is the one thing it doesn't mean. The
    /// 250ms debounce keeps the blank beat short.
    private func setSpinning(_ spinning: Bool) {
        if spinning {
            resultsSpinner.startAnimating()
        } else {
            resultsSpinner.stopAnimating()
        }
        resultsView.isHidden = spinning || !isSearching
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let targeting, !trimmed.isEmpty else {
            // Cleared back to empty: the suggestions are the right resting
            // state, not a blank list.
            showSuggestionsInResults()
            return
        }
        emptyResultsLabel.isHidden = true
        setSpinning(true)
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
            self.setSpinning(false)
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

        // The list runs the FULL height of the sheet and the search row floats
        // over it — the iOS 26 composition. Its top inset holds the rows clear
        // of the row at rest (see `applyResultsInset`), and `.soft` fades
        // them out as they pass beneath it instead of clipping at a hard line.
        resultsView.topEdgeEffect.style = .soft

        // Bottom pinned to the VIEW at required priority, which is the whole
        // point of this layout.
        //
        // It used to be pinned to `keyboardLayoutGuide` — a WINDOW-relative
        // guide — so as the sheet translated the guide's top marched up in this
        // view's coordinate space, crushing the list and passing the deficit
        // into the QR card. That needed a `.defaultLow` priority to defuse,
        // which in turn meant the list never reliably filled the sheet when the
        // keyboard went away, leaving dead space at the bottom.
        //
        // View-relative, the guide can no longer reach in: the list always
        // fills the sheet, and the keyboard is handled where a scroll view
        // expects it — as a content inset.
        resultsView.constrain(in: view) { parent in
            resultsView.topAnchor.constraint(equalTo: parent.topAnchor)
            resultsView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            resultsView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            resultsView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        // Beneath the column, so the search row floats above the rows it
        // fades. `constrain(in:)` appends, which would put it on top.
        view.insertSubview(resultsView, aboveSubview: glassBackdrop)

        // Centred on the list rather than pinned under the field: it marks
        // "the answer is coming", and the answer fills the list.
        resultsSpinner.hidesWhenStopped = true
        resultsSpinner.constrain(in: view) { _ in
            resultsSpinner.centerXAnchor.constraint(equalTo: resultsView.centerXAnchor)
            // Below the floating search row, not the list's top edge — which
            // now runs behind that row.
            resultsSpinner.topAnchor.constraint(equalTo: column.bottomAnchor, constant: Spacing.xxl)
        }
        emptyResultsLabel.constrain(in: view) { parent in
            emptyResultsLabel.topAnchor.constraint(equalTo: column.bottomAnchor, constant: Spacing.xxl)
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
    /// Scrolls the results so rows pass beneath the floating search row.
    func qaScrollResults(by offset: CGFloat) {
        resultsView.setContentOffset(
            CGPoint(x: 0, y: resultsView.contentOffset.y + offset), animated: false
        )
    }
    /// Lowers the keyboard WITHOUT leaving search — the state in which the
    /// built-in cancel button used to go dead.
    func qaLowerKeyboard() { searchBar.resignFirstResponder() }
    /// Whether our Cancel is genuinely tappable in the current state.
    var qaCancelIsUsable: Bool {
        cancelSearchButton.isEnabled && cancelSearchButton.isUserInteractionEnabled
            && !cancelSearchButton.isHidden
    }
    /// Fires Cancel the way a tap would.
    func qaTapCancel() { cancelSearchButton.sendActions(for: .primaryActionTriggered) }
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
