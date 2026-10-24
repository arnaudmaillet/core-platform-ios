#if DEBUG
import DesignSystem
import PostGrid
import UIKit

/// `-button-catalog`: every button the app ACTUALLY wears, configured as its
/// screen configures it, with the states that screen walks it through — the
/// place to watch, tune and then unify their motions (the owner, 2026-10-23).
///
/// Each row names where its buttons live. Tapping a button runs that screen's
/// own transition; the chips under a row jump it to each of its states. At the
/// top, a ×4 slow motion (the window's layer speed) — no Reduce Motion: the
/// buttons ignore it (the owner, 2026-10-23). The component's generic matrix — every aspect × size —
/// stays `AppButtonGalleryViewController`, one tap away.
///
/// ⚠️ A COPY OF EACH CALL SITE'S CONFIGURATION, not the call site: the
/// profile's and the place's buttons are private to their views. Where a
/// factory is public (`PostCardAction.make`), it is the one used here.
final class AppButtonCatalogViewController: UIViewController {
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private var buttons: [AppButton] = []
    private var anchorButtons: [AppButton] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Buttons"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Spacing.md
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xxl),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.view.window?.layer.speed = 1
            self?.dismiss(animated: true)
        })
        buildTools()
        buildSystemReference()
        buildAnchors()
        buildProfileOther()
        buildProfileOwn()
        buildPlace()
        buildPersonRow()
        buildMessageRequest()
        buildPostCard()
        buildShop()
        buildGalleryLink()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.window?.layer.speed = 1
    }

    // MARK: - Building blocks

    /// A section: its title, where its buttons live, then its rows.
    private func section(_ title: String, source: String) {
        let label = UILabel()
        label.text = title
        label.font = UIFont.scaledFont(forTextStyle: .title3, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        let caption = UILabel()
        caption.text = source
        caption.font = .appFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label, caption])
        stack.axis = .vertical
        stack.spacing = 2
        column.setCustomSpacing(Spacing.xl, after: column.arrangedSubviews.last ?? stack)
        column.addArrangedSubview(stack)
    }

    /// Buttons side by side, as their screen lays them.
    @discardableResult
    private func row(_ views: [UIView], fills: Bool = false, on ground: UIColor? = nil) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = Spacing.sm
        stack.alignment = .center
        if !fills { stack.addArrangedSubview(UIView()) }
        guard let ground else {
            column.addArrangedSubview(stack)
            return stack
        }
        let card = UIView()
        card.backgroundColor = ground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Spacing.sm),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Spacing.sm),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Spacing.md),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Spacing.md),
        ])
        column.addArrangedSubview(card)
        return stack
    }

    /// Small plain chips that jump a row to one of its states.
    private func states(_ items: [(String, () -> Void)]) {
        let chips = items.map { title, run in
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            return UIButton(configuration: configuration, primaryAction: UIAction { _ in run() })
        }
        let stack = UIStackView(arrangedSubviews: chips + [UIView()])
        stack.axis = .horizontal
        stack.spacing = Spacing.xs
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 28),
        ])
        column.addArrangedSubview(scroller)
    }

    /// Every button joins the catalog's colour trials.
    private func track(_ button: AppButton) -> AppButton {
        buttons.append(button)
        return button
    }

    // MARK: - Tools

    private func buildTools() {
        let slow = UISwitch()
        slow.addAction(UIAction { [weak self, weak slow] _ in
            self?.view.window?.layer.speed = (slow?.isOn ?? false) ? 0.25 : 1
        }, for: .valueChanged)
        func labelled(_ text: String, _ control: UISwitch) -> UIStackView {
            let label = UILabel()
            label.text = text
            label.font = .appFont(forTextStyle: .subheadline)
            let stack = UIStackView(arrangedSubviews: [label, control])
            stack.spacing = Spacing.xs
            stack.alignment = .center
            return stack
        }
        let tools = UIStackView(arrangedSubviews: [labelled("Slow ×4", slow), UIView()])
        tools.spacing = Spacing.lg
        tools.alignment = .center
        column.addArrangedSubview(tools)
    }

    // MARK: - System reference

    /// System glass buttons whose words change on a tap: the reference the
    /// content change copies (the owner, 2026-10-23: "the Liquid Glass
    /// button's behaviour, without its look"). The bar item is replaced,
    /// animated (a plain `title` change lands at once); the two in the page
    /// are configured glass buttons, their title changed in an animation.
    private func buildSystemReference() {
        let titles = ["Edit", "Edit Profile Now"]
        func barItem(_ title: String) -> UIBarButtonItem {
            UIBarButtonItem(primaryAction: UIAction(title: title) { [weak self] _ in
                let next = title == titles[0] ? titles[1] : titles[0]
                self?.navigationItem.setLeftBarButton(barItem(next), animated: true)
            })
        }
        navigationItem.leftBarButtonItem = barItem(titles[0])

        section("System glass", source: "UIButton.Configuration .glass() / .prominentGlass() — tap to change the words")
        var glassButtons: [UIView] = []
        for configuration in [UIButton.Configuration.glass(), .prominentGlass()] {
            var configured = configuration
            configured.title = titles[0]
            let button = UIButton(configuration: configured)
            button.addAction(UIAction { [weak button] _ in
                guard let button else { return }
                let next = button.configuration?.title == titles[0] ? titles[1] : titles[0]
                UIView.animate(springDuration: 0.4, bounce: 0.2) {
                    button.configuration?.title = next
                    button.superview?.layoutIfNeeded()
                }
            }, for: .primaryActionTriggered)
            glassButtons.append(button)
        }
        // A glass button that does nothing: its press alone, to measure.
        var still = UIButton.Configuration.glass()
        still.title = "Press"
        glassButtons.append(UIButton(configuration: still))
        row(glassButtons)
        // Ours beside it, the same words, for the comparison.
        let ours = track(AppButton(aspect: .pill(.quiet), size: .header, content: .title(titles[0])))
        ours.morphAnchor = .leading
        ours.addAction(UIAction { [weak ours] _ in
            guard let ours else { return }
            ours.setContent(.title(ours.content.title == titles[0] ? titles[1] : titles[0]), animated: true)
        }, for: .primaryActionTriggered)
        row([ours])
    }

    // MARK: - Morph anchors

    /// The five sides a content change can keep (`morphAnchor`), each button
    /// in a slot the size of its largest content (`holdsReservedSize`), the
    /// slot drawn dashed: a tap swaps the content (the owner, 2026-10-23).
    private func buildAnchors() {
        section("Morph anchors", source: "AppButton.morphAnchor + holdsReservedSize — dashed: the slot; tap a button to swap it")
        let wide: [AppButton.Content] = [.title("Follow"), .title("Follow Back")]
        let tall: [AppButton.Content] = [
            AppButton.Content(title: "Pin", symbol: "mappin", imagePlacement: .top),
            .title("Pinned to Map"),
        ]
        let anchors: [(String, AppButton.MorphAnchor, [AppButton.Content])] = [
            ("Leading", .leading, wide),
            ("Center", .center, wide),
            ("Trailing", .trailing, wide),
            ("Top", .top, tall),
            ("Bottom", .bottom, tall),
        ]
        var swaps: [() -> Void] = []
        var loads: [() -> Void] = []
        for (name, anchor, contents) in anchors {
            let button = track(AppButton(aspect: .pill(.prominent), size: .row, content: contents[0]))
            anchorButtons.append(button)
            button.reservedContents = contents
            button.morphAnchor = anchor
            button.holdsReservedSize = true
            let swap = { [weak button] in
                guard let button else { return }
                let next = contents.first { $0 != button.content } ?? contents[0]
                button.setContent(next, selected: next == contents[1], animated: true)
            }
            button.addAction(UIAction { _ in swap() }, for: .primaryActionTriggered)
            swaps.append(swap)
            // A load, then its answer: the next content, as a request would.
            loads.append { [weak button] in
                guard let button else { return }
                button.setPhase(.loading, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
                    guard let button else { return }
                    let next = contents.first { $0 != button.content } ?? contents[0]
                    button.setContent(next, selected: next == contents[1], animated: true)
                    button.setPhase(.content, animated: true)
                }
            }
            let label = UILabel()
            label.text = name
            label.font = .appFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            row([label, SlotFrameView(around: button)])
        }
        states([
            ("Swap all", { swaps.forEach { $0() } }),
            ("Load & swap", { loads.forEach { $0() } }),
            ("Go / Appear", { [weak self] in
                self?.anchorButtons.forEach { $0.isHidden ? $0.appear(animated: true) : $0.disappear(animated: true) }
            }),
        ])
        // The prominent ground's colour, on every button of the page.
        let colours: [(String, UIColor)] = [
            ("Pink", Palette.prominentFill),
            ("Violet", UIColor(red: 0.47, green: 0.36, blue: 0.94, alpha: 1)),
            ("Blue", .systemBlue),
            ("Green", .systemGreen),
            ("Orange", .systemOrange),
            ("Red", .systemRed),
            ("Ink", UIColor(white: 0.12, alpha: 1)),
        ]
        states(colours.map { name, colour in
            (name, { [weak self] in self?.buttons.forEach { $0.prominentColor = colour } })
        })
    }

    // MARK: - Profile, someone else's

    private enum Relationship { case unread, follow, following, requested, unavailable }

    private func buildProfileOther() {
        section("Profile · someone else", source: "ProfileHeaderView — Follow · Message · QR · ⋯")
        let follow = track(AppButton(aspect: .pill(.prominent), size: .header, content: .title("Follow")))
        follow.isToggle = true
        follow.reservedContents = [.title("Follow"), .title("Following"), .title("Requested")]
        let message = track(AppButton(aspect: .pill(.quiet), size: .header, content: .title("Message")))
        let qr = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode")))
        let more = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("ellipsis")))
        more.menu = UIMenu(children: [
            UIAction(title: "Share Profile", image: UIImage(systemName: "square.and.arrow.up")) { _ in print("[catalog] Share Profile") },
            UIAction(title: "Report", image: UIImage(systemName: "flag"), attributes: .destructive) { _ in print("[catalog] Report") },
        ])
        more.showsMenuAsPrimaryAction = true
        let tray = row([follow, message, qr, more], fills: true)
        for capsule in [follow, message] {
            capsule.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
            capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        message.widthAnchor.constraint(equalTo: follow.widthAnchor).isActive = true
        for bubble in [qr, more] {
            NSLayoutConstraint.activate([
                bubble.widthAnchor.constraint(equalToConstant: HeroHeaderMetrics.bubble),
                bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor),
            ])
        }
        _ = tray

        // The profile's own state machine (`ProfileHeaderView.configureAction`).
        var shown: Relationship?
        func apply(_ state: Relationship) {
            let onScreen = shown != nil
            defer { shown = state }
            switch state {
            case .unread:
                follow.setPhase(.placeholder, animated: false)
                if follow.isHidden { follow.appear(animated: onScreen) }
            case .follow, .following, .requested:
                let title = state == .follow ? "Follow" : state == .requested ? "Requested" : "Following"
                let changes = [Relationship.follow, .following, .requested].contains(shown) && shown != state
                if follow.phase == .placeholder {
                    follow.setContent(.title(title), selected: state != .follow, animated: false)
                    follow.setPhase(.content, animated: onScreen)
                } else {
                    follow.setContent(.title(title), selected: state != .follow, animated: changes)
                }
                if follow.isHidden { follow.appear(animated: onScreen) }
            case .unavailable:
                follow.setPhase(.content, animated: false)
                if !follow.isHidden { follow.disappear(animated: onScreen) }
            }
        }
        apply(.follow)
        // A tap is the viewer's follow, answered at once (optimistic).
        follow.addAction(UIAction { _ in
            apply(shown == .follow ? .following : .follow)
        }, for: .primaryActionTriggered)
        states([
            ("Unread", { apply(.unread) }), ("Follow", { apply(.follow) }), ("Following", { apply(.following) }),
            ("Requested", { apply(.requested) }), ("Unavailable", { apply(.unavailable) }),
            ("Fail", { follow.fail() }),
        ])
    }

    // MARK: - Profile, yours

    private func buildProfileOwn() {
        section("Profile · yours", source: "ProfileHeaderView — Edit Profile · QR · ⋯")
        let edit = track(AppButton(aspect: .pill(.quiet), size: .header, content: .title("Edit Profile")))
        edit.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let qr = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode")))
        let more = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("ellipsis")))
        row([edit, qr, more], fills: true)
        for bubble in [qr, more] {
            NSLayoutConstraint.activate([
                bubble.widthAnchor.constraint(equalToConstant: HeroHeaderMetrics.bubble),
                bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor),
            ])
        }
    }

    // MARK: - Place

    private func buildPlace() {
        section("Place page", source: "PlaceProfileViewController — Add Pin to Map · star · QR")
        func pinContent(_ docked: Bool) -> AppButton.Content {
            docked
                ? AppButton.Content(title: "Pinned to Map", symbol: "mappin.circle.fill")
                : AppButton.Content(title: "Add Pin to Map", symbol: "mappin")
        }
        let pin = track(AppButton(aspect: .pill(.quiet), size: .header, content: pinContent(false)))
        pin.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        pin.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let star = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol(SaveStar.symbol(saved: false))))
        let qr = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode")))
        row([pin, star, qr], fills: true)
        for bubble in [star, qr] {
            NSLayoutConstraint.activate([
                bubble.widthAnchor.constraint(equalToConstant: HeroHeaderMetrics.bubble),
                bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor),
            ])
        }
        var docked = false
        var starred = false
        func dock(_ value: Bool) {
            docked = value
            pin.setContent(pinContent(value), animated: true)
        }
        func follow(_ value: Bool) {
            starred = value
            star.setContent(.symbol(SaveStar.symbol(saved: value)), animated: true)
            star.inkColor = value ? SaveStar.tint : nil
        }
        pin.addAction(UIAction { _ in dock(!docked) }, for: .primaryActionTriggered)
        star.addAction(UIAction { _ in follow(!starred) }, for: .primaryActionTriggered)
        states([
            ("Not pinned", { dock(false) }), ("Pinned", { dock(true) }),
            ("Not followed", { follow(false) }), ("Followed", { follow(true) }),
        ])
    }

    // MARK: - Person rows

    private enum RowState { case follow, followBack, following, requested }

    private func buildPersonRow() {
        section(
            "Person row",
            source: "RelationshipListCell · SuggestionCell — Follow / Follow Back ⇄ Following / Requested, a bare ✕"
        )
        let follow = track(AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow")))
        follow.isToggle = true
        // The row's trailing button: it grows and shrinks from its right edge.
        follow.morphAnchor = .trailing
        let dismiss = track(AppButton(aspect: .bare, size: .inline, content: .symbol("xmark")))
        dismiss.inkColor = .tertiaryLabel
        let name = UILabel()
        name.text = "Kenji Tanaka"
        name.font = UIFont.scaledFont(forTextStyle: .body, weight: .semibold)
        row([name, UIView(), follow, dismiss], fills: true, on: Surface.card)
        var shown = RowState.follow
        // The row's own rule (`RelationshipListCell`): an invitation stands
        // prominent, a fact is selected — the quiet ground.
        func apply(_ state: RowState) {
            let (title, selected): (String, Bool) = switch state {
            case .follow: ("Follow", false)
            case .followBack: ("Follow Back", false)
            case .following: ("Following", true)
            case .requested: ("Requested", true)
            }
            follow.setContent(.title(title), selected: selected, animated: state != shown)
            shown = state
        }
        follow.addAction(UIAction { _ in apply(shown == .following ? .follow : .following) }, for: .primaryActionTriggered)
        dismiss.addAction(UIAction { _ in
            dismiss.disappear(animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dismiss.appear(animated: true) }
        }, for: .primaryActionTriggered)
        states([
            ("Follow", { apply(.follow) }), ("Follow Back", { apply(.followBack) }),
            ("Following", { apply(.following) }), ("Requested", { apply(.requested) }),
            ("Loading", { follow.setPhase(.loading, animated: true) }), ("Loaded", { follow.setPhase(.content, animated: true) }),
        ])
    }

    // MARK: - Message request

    private func buildMessageRequest() {
        section("Message request", source: "MessageRequestCell — Accept · ✕")
        let accept = track(AppButton(aspect: .pill(.prominent), size: .row, content: .title("Accept")))
        let decline = track(AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("xmark")))
        decline.inkColor = .secondaryLabel
        let name = UILabel()
        name.text = "Vera Lindqvist"
        name.font = UIFont.scaledFont(forTextStyle: .body, weight: .semibold)
        row([name, UIView(), accept, decline], fills: true, on: Surface.card)
        accept.addAction(UIAction { _ in
            accept.busyLabel = "Accepting…"
            accept.setPhase(.loading, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { accept.setPhase(.content, animated: true) }
        }, for: .primaryActionTriggered)
    }

    // MARK: - Post card

    private func buildPostCard() {
        section(
            "Post card",
            source: "PostGridListRowCell — PostCardAction.make (the real factory): save · repost ······ comments · likes"
        )
        let save = track(PostCardAction.make(symbol: PostGridListRowCell.ActionSymbol.save, label: "Save", selectedTint: SaveStar.tint))
        let repost = track(PostCardAction.make(symbol: PostGridListRowCell.ActionSymbol.repost, label: "Repost"))
        let comments = track(PostCardAction.make(symbol: PostGridListRowCell.ActionSymbol.comments, label: "Comments"))
        let likes = track(PostCardAction.make(
            symbol: PostGridListRowCell.ActionSymbol.like, label: "Likes", selectedTint: LikesSymbol.tint
        ))
        var likeCount = 1_284
        var commentCount = 48
        comments.setContent(.init(symbol: PostGridListRowCell.ActionSymbol.comments, count: commentCount), animated: false)
        likes.setContent(.init(symbol: PostGridListRowCell.ActionSymbol.like, count: likeCount), animated: false)
        row([save, repost, UIView(), comments, likes], fills: true, on: Surface.card)
        var saved = false
        var staked = false
        func setSaved(_ value: Bool) {
            saved = value
            save.setContent(.symbol(value ? PostGridListRowCell.ActionSymbol.saved : PostGridListRowCell.ActionSymbol.save), animated: true)
            save.setSelected(value, animated: true)
        }
        func setStaked(_ value: Bool) {
            if value != staked { likeCount += value ? 1 : -1 }
            staked = value
            likes.setContent(.init(symbol: value ? LikesSymbol.glyph : PostGridListRowCell.ActionSymbol.like, count: likeCount), animated: true)
            likes.setSelected(value, animated: true)
        }
        save.addAction(UIAction { _ in setSaved(!saved) }, for: .primaryActionTriggered)
        likes.addAction(UIAction { _ in setStaked(!staked) }, for: .primaryActionTriggered)
        comments.addAction(UIAction { _ in
            commentCount += 1
            comments.setContent(.init(symbol: PostGridListRowCell.ActionSymbol.comments, count: commentCount), animated: true)
        }, for: .primaryActionTriggered)
        repost.addAction(UIAction { _ in repost.playSymbolEffect() }, for: .primaryActionTriggered)
        states([
            ("Saved", { setSaved(true) }), ("Unsaved", { setSaved(false) }),
            ("Liked", { setStaked(true) }), ("Not liked", { setStaked(false) }),
            ("+1 000 likes", {
                likeCount += 1_000
                likes.setContent(.init(symbol: staked ? LikesSymbol.glyph : PostGridListRowCell.ActionSymbol.like, count: likeCount), animated: true)
            }),
        ])
    }

    // MARK: - Shop

    private func buildShop() {
        section("Shop", source: "CountryShopViewController — the price: tinted pill, gem, its menu")
        let price = track(AppButton(aspect: .pill(.tinted), size: .row, content: AppButton.Content(title: 40.formatted(), symbol: GemSymbol.glyph)))
        price.menu = UIMenu(children: [UIAction(title: "Unlock for 40 Gems", image: UIImage(systemName: "lock.open")) { _ in print("[catalog] Unlock") }])
        price.showsMenuAsPrimaryAction = true
        let disabled = track(AppButton(aspect: .pill(.tinted), size: .row, content: AppButton.Content(title: 2_500.formatted(), symbol: GemSymbol.glyph)))
        disabled.isEnabled = false
        let name = UILabel()
        name.text = "Japan"
        name.font = UIFont.scaledFont(forTextStyle: .body, weight: .semibold)
        row([name, UIView(), price, disabled], fills: true, on: Surface.card)
    }

    // MARK: - The component's matrix

    private func buildGalleryLink() {
        section("Every aspect × size", source: "AppButtonGalleryViewController — the component's own matrix")
        let open = track(AppButton(aspect: .pill(.quiet), size: .row, content: AppButton.Content(title: "Open the gallery", symbol: "square.grid.2x2")))
        open.addAction(UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(AppButtonGalleryViewController(), animated: true)
        }, for: .primaryActionTriggered)
        row([open])
    }
}

/// The profile tray's bubble: `HeroHeaderView.bubbleSize`, restated so the
/// catalog needs no HeroPage import for one number.
private enum HeroHeaderMetrics {
    static let bubble: CGFloat = 44
}
/// A dashed frame just outside a view: the slot a button holds.
private final class SlotFrameView: UIView {
    private let dash = CAShapeLayer()

    init(around content: UIView) {
        super.init(frame: .zero)
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [3, 3]
        layer.addSublayer(dash)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.setNeedsLayout() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -3), cornerRadius: 6).cgPath
        dash.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
