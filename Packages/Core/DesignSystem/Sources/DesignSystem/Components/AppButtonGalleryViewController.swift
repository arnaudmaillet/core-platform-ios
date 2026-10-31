#if DEBUG
import UIKit

/// Every `AppButton` aspect × size × state and every `AppIconButton` style on
/// one screen, and their motions on demand (#931, #1666) — `-button-gallery`
/// opens it over the app. A QA surface: it is how the components are filmed
/// in light, dark and at the app's largest text size.
public final class AppButtonGalleryViewController: UIViewController {
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private var all: [AppControl] = []
    /// The gallery's own Reduce Motion: the buttons ignore the iPhone's, and
    /// this shows their fallbacks.
    private var forcesReducedMotion = false
    private var demo: AppButton?
    private var counter: AppIconButton?
    private var toggled: AppIconButton?
    private var vanishing: AppIconButton?

    public init() {
        super.init(nibName: nil, bundle: nil)
        title = "AppButton"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xxl),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.closePresentation()
        })
        buildMotion()
        buildAspects()
        buildStates()
    }

    // MARK: - Sections

    private func header(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .appFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        column.addArrangedSubview(label)
    }

    private func row(_ views: [UIView], over backdrop: Bool = false) {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = Spacing.sm
        stack.alignment = .center
        guard backdrop else {
            column.addArrangedSubview(stack)
            return
        }
        // The material pill's reason to exist: something busy behind it.
        let photo = GradientBackdrop()
        photo.layer.cornerRadius = Spacing.md
        photo.clipsToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        photo.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: photo.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: photo.bottomAnchor, constant: -Spacing.md),
            stack.leadingAnchor.constraint(equalTo: photo.leadingAnchor, constant: Spacing.md),
            stack.trailingAnchor.constraint(equalTo: photo.trailingAnchor, constant: -Spacing.md),
        ])
        column.addArrangedSubview(photo)
    }

    private func make(
        _ aspect: AppButton.Aspect, _ size: AppButton.Size, _ content: AppButton.Content,
        shape: AppButton.Shape = .capsule
    ) -> AppButton {
        let button = AppButton(aspect: aspect, size: size, shape: shape, content: content, sound: .tap)
        track(button)
        return button
    }

    private func makeIcon(_ style: AppIconButton.Style, _ content: AppIconButton.Content) -> AppIconButton {
        let button = AppIconButton(style: style, content: content, sound: .tap)
        track(button)
        return button
    }

    private func track(_ button: AppControl) {
        button.reducesMotion = { [weak self] in self?.forcesReducedMotion ?? false }
        all.append(button)
    }

    private func content(for size: AppButton.Size) -> AppButton.Content {
        switch size {
        case .row: .title("Follow")
        case .header: AppButton.Content(title: "Message", symbol: "paperplane")
        }
    }

    private func buildAspects() {
        for size in AppButton.Size.allCases {
            header("\(size)".capitalized)
            let sample = content(for: size)
            row([make(.pill(.prominent), size, sample), make(.pill(.quiet), size, sample), make(.pill(.tinted), size, sample)])
            row([make(.pill(.material), size, sample)], over: true)
        }
        header("Bubble")
        let qr = AppIconButton.Content.symbol("qrcode")
        row([makeIcon(.bubble(.prominent), qr), makeIcon(.bubble(.quiet), qr), makeIcon(.bubble(.tinted), qr)])
        row([makeIcon(.bubble(.material), qr), makeIcon(.glyph, qr)], over: true)
        header("Glyph")
        let likes = AppIconButton.Content(symbol: AppSymbol.like.rawValue, count: 1_284)
        row([makeIcon(.glyph, likes), makeIcon(.glyph, .symbol(AppSymbol.save.rawValue))])
        header("Card shape")
        row([
            make(.pill(.quiet), .header, .title("Edit profile"), shape: .card),
            make(.pill(.prominent), .header, AppButton.Content(title: "25", symbol: GemSymbol.glyph), shape: .card),
        ])
    }

    private func buildStates() {
        header("States")
        let normal = make(.pill(.prominent), .row, .title("Follow"))
        let selected = make(.pill(.prominent), .row, .title("Following"))
        selected.isSelected = true
        let disabled = make(.pill(.tinted), .row, AppButton.Content(title: "40", symbol: GemSymbol.glyph))
        disabled.isEnabled = false
        row([normal, selected, disabled])
        let placeholder = make(.pill(.prominent), .row, .title("Follow"))
        placeholder.reservedContents = [.title("Follow"), .title("Following"), .title("Requested")]
        placeholder.setPhase(.placeholder, animated: false)
        let loading = make(.pill(.quiet), .row, .title("Following"))
        loading.busyLabel = "Following…"
        loading.setPhase(.loading, animated: false)
        let loadingSymbol = make(.pill(.quiet), .header, AppButton.Content(title: "Save", symbol: AppSymbol.save.rawValue))
        loadingSymbol.setPhase(.loading, animated: false)
        row([placeholder, loading, loadingSymbol])
        let liked = makeIcon(.glyph, AppIconButton.Content(symbol: AppSymbol.liked.rawValue, count: 1_285))
        liked.selectedTint = Palette.tint
        liked.isSelected = true
        row([liked, makeIcon(.glyph, AppIconButton.Content(symbol: "bubble.right", count: 48))])
    }

    // MARK: - Motion

    private func buildMotion() {
        header("Motion")
        let demo = make(.pill(.prominent), .row, .title("Follow"))
        demo.isToggle = true
        demo.haptic = .tick
        demo.addAction(UIAction { [weak self] _ in self?.cycleFollow() }, for: .primaryActionTriggered)
        self.demo = demo
        let counter = makeIcon(.glyph, AppIconButton.Content(symbol: AppSymbol.like.rawValue, count: 99))
        counter.selectedTint = Palette.tint
        counter.bouncesSymbolOnTap = true
        counter.haptic = .toggleOn
        counter.holdFreezesScrolling = true
        counter.addAction(UIAction { [weak self] _ in self?.like() }, for: .primaryActionTriggered)
        self.counter = counter
        let toggled = makeIcon(.glyph, .symbol(AppSymbol.save.rawValue))
        toggled.addAction(UIAction { [weak self] _ in self?.save() }, for: .primaryActionTriggered)
        self.toggled = toggled
        let vanishing = makeIcon(.bubble(.quiet), .symbol("ellipsis"))
        // A menu as the primary action; its item answers with the symbol
        // effect, so the menu's own path is visible too.
        vanishing.menu = UIMenu(children: [UIAction(title: "Bounce") { [weak vanishing] _ in
            vanishing?.playSymbolEffect()
        }])
        vanishing.showsMenuAsPrimaryAction = true
        self.vanishing = vanishing
        row([demo, counter, toggled, vanishing])

        let appear = make(.pill(.quiet), .row, .title("Appear / go"))
        appear.addAction(UIAction { [weak self] _ in self?.toggleVanishing() }, for: .primaryActionTriggered)
        let fail = make(.pill(.quiet), .row, .title("Fail"))
        fail.notifiesCompletion = true
        fail.addAction(UIAction { [weak self] _ in self?.demo?.fail() }, for: .primaryActionTriggered)
        let reduce = make(.pill(.tinted), .row, .title("Reduce Motion: off"))
        reduce.isToggle = true
        reduce.addAction(UIAction { [weak self, weak reduce] _ in
            guard let self, let reduce else { return }
            forcesReducedMotion.toggle()
            reduce.setSelected(forcesReducedMotion, animated: true)
            reduce.setContent(.title(forcesReducedMotion ? "Reduce Motion: on" : "Reduce Motion: off"), animated: true)
        }, for: .primaryActionTriggered)
        row([appear, fail, reduce])
    }

    /// Follow → (loading) → Following → Follow: the content change, the held
    /// width and the state tint, in one tap.
    private func cycleFollow() {
        guard let demo else { return }
        let following = !demo.isSelected
        demo.busyLabel = following ? "Following…" : "Unfollowing…"
        demo.setPhase(.loading, animated: true)
        Task { @MainActor [weak demo] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let demo else { return }
            // The answer onto the held load, then the morph to it.
            demo.setContent(.title(following ? "Following" : "Follow"), selected: following, animated: true)
            demo.setPhase(.content, animated: true)
        }
    }

    private func like() {
        guard let counter else { return }
        let liked = !counter.isSelected
        counter.setSelected(liked, animated: true)
        let count = (counter.content.count ?? 0) + (liked ? 1 : -1)
        counter.setContent(AppIconButton.Content(symbol: liked ? AppSymbol.liked.rawValue : AppSymbol.like.rawValue, count: count), animated: true)
    }

    private func save() {
        guard let toggled else { return }
        let saved = toggled.content.symbol == AppSymbol.save.rawValue
        toggled.setContent(.symbol(saved ? AppSymbol.saved.rawValue : AppSymbol.save.rawValue), animated: true)
    }

    private func toggleVanishing() {
        guard let vanishing else { return }
        if vanishing.isHidden {
            vanishing.appear(animated: true)
        } else {
            vanishing.disappear(animated: true)
        }
    }

    /// A stand-in photograph: colour and contrast for a material to blur.
    private final class GradientBackdrop: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let gradient = layer as? CAGradientLayer
            gradient?.colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor, UIColor.systemIndigo.cgColor]
            gradient?.startPoint = CGPoint(x: 0, y: 0)
            gradient?.endPoint = CGPoint(x: 1, y: 1)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
#endif
