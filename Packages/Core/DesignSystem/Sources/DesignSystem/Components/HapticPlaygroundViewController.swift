// ⚠️ THE WHOLE FILE: DEBUG only — the haptics playground (#2193).
#if DEBUG
import UIKit

/// THE HAPTICS PLAYGROUND (#2193, was the catalog of #1882): every haptic the
/// app could play, felt on a device, in the app's own gestures, and on the
/// app's own roles — to choose the catalog. The simulator has no Taptic
/// Engine: there it only shows what exists.
///
/// Reached from the debug dashboard (Labs), or `-haptic-playground`
/// (`-haptic-catalog` still works).
///
/// - **The app's roles:** a tap plays one through `Haptics.play`, its
///   candidate if it has one; "Try in the app" gives it the selection.
/// - **UIKit generators, Core Haptics (a tap, a buzz, patterns), the system
///   vibration:** a tap plays one AND selects it.
/// - **Pacing:** today's burst, and ten of the selection at a chosen spacing.
/// - **In context:** a button, a toggle, a long press, a detent strip and a
///   pull with a threshold, each playing the selection.
public final class HapticPlaygroundViewController: UIViewController, UIScrollViewDelegate {
    /// The sections, in order: their identifiers, for the tests.
    enum Section: String, CaseIterable {
        case status, roles, uikit, tap, buzz, patterns, vibration, pacing, context
    }

    private let overrides: HapticOverrides
    private let scroll = UIScrollView()
    private let column = UIStackView()
    /// The rows each section holds, by identifier: what the tests count.
    private(set) var rows: [Section: [UIView]] = [:]

    // MARK: The selection

    /// What the pads, the spaced burst and "Try in the app" play.
    private(set) var selection: HapticSound = .recipe(.impact(.medium, intensity: 1))
    /// The section the selection came from, so its sliders keep it current.
    private var selectionSource: Section = .uikit
    private var selectionLabels: [UILabel] = []

    // MARK: The sliders' values

    private var impactIntensity: Double = 1
    private var tapIntensity: Double = 1
    private var tapSharpness: Double = 0.5
    private var buzzIntensity: Double = 0.8
    private var buzzSharpness: Double = 0.3
    private var buzzDuration: Double = 0.3
    private var buzzAttack: Double = 0
    private var buzzDecay: Double = 0
    private var burstSpacing: Double = 0.060
    /// The UIKit row selected, to re-read at a new intensity.
    private var selectedImpact: HapticRecipe?

    // MARK: The pads

    private let strip = UIScrollView()
    private static let detentSpacing: CGFloat = 56
    private static let detentCount = 30
    private var stripIndex = 0
    private var stripLastPlayed: TimeInterval = 0
    private var toggleIsOn = false
    private let pullFill = UIView()
    private var pullFillHeight: NSLayoutConstraint?
    private var pullArmed = false
    private static let pullHeight: CGFloat = 220
    private static let pullThreshold: CGFloat = 120

    private var roleDetails: [Haptic: UIButton] = [:]
    /// The "Try in the app" button beside each role.
    static let menuWidth: CGFloat = 52
    /// Each role's "Try in the app" button, for the tests.
    private(set) var roleMenus: [Haptic: UIButton] = [:]
    private var observer: NSObjectProtocol?

    public init(overrides: HapticOverrides = .shared) {
        self.overrides = overrides
        super.init(nibName: nil, bundle: nil)
        title = "Haptics Playground"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.closePresentation() }
        )
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Spacing.sm
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        buildStatus()
        buildRoles()
        buildUIKit()
        buildTap()
        buildBuzz()
        buildPatterns()
        buildVibration()
        buildPacing()
        buildContext()
        refreshSelection()
        observer = NotificationCenter.default.addObserver(
            forName: HapticOverrides.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoles() }
        }
    }

    // MARK: - Sections

    private func buildStatus() {
        var notes: [String] = []
        if !HapticPreference.isOn {
            notes.append("⚠️ Haptics is off in the app's Settings (Playback and Sound): nothing plays.")
        }
        if !HapticPatternPlayer.supportsHaptics {
            notes.append("⚠️ No Taptic Engine here (the simulator): nothing plays, and Core Haptics is greyed out.")
        }
        notes.append("If nothing plays on a device, check iOS Settings → Sounds & Haptics → System Haptics: the app can't read it.")
        let selected = Self.note("")
        selected.font = .appFont(forTextStyle: .subheadline)
        selected.textColor = .label
        selectionLabels.append(selected)
        add(.status, header: nil, rows: notes.map { Self.note($0) } + [selected])
    }

    private func buildRoles() {
        var views: [UIView] = []
        for role in Haptic.allCases {
            let play = button(title: "\(role)", detail: "") { Haptics.play(role) }
            play.addAction(UIAction { _ in Haptics.prepare(role) }, for: .touchDown)
            roleDetails[role] = play
            let menu = UIButton(configuration: .gray())
            menu.configuration?.image = UIImage(systemName: "wand.and.stars")
            menu.accessibilityLabel = "Try in the app"
            menu.showsMenuAsPrimaryAction = true
            roleMenus[role] = menu
            menu.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.roleMenu(role) ?? [])
            }])
            // One width on every row: the row's two-line button gave way to it
            // unevenly, and crushed it to nothing on some rows.
            menu.setContentHuggingPriority(.required, for: .horizontal)
            menu.setContentCompressionResistancePriority(.required, for: .horizontal)
            menu.widthAnchor.constraint(equalToConstant: Self.menuWidth).isActive = true
            play.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = UIStackView(arrangedSubviews: [play, menu])
            line.spacing = Spacing.sm
            line.alignment = .fill
            views.append(line)
        }
        let reset = button(title: "Reset all", detail: "Every role back to today's recipe") { [weak self] in
            self?.overrides.resetAll()
        }
        let copy = button(title: "Copy the catalog", detail: "Each role and what it plays, with its values") { [weak self] in
            self?.copyCatalog()
        }
        add(.roles, header: "The app's roles",
            footer: "A tap plays the role as the app does. ✦ Try in the app: the role plays the selection everywhere, until reset.",
            rows: views + [reset, copy])
        refreshRoles()
    }

    private func buildUIKit() {
        var views: [UIView] = []
        for recipe in HapticRecipe.impactStyles {
            views.append(button(title: recipe.summary, detail: "UIKit impact, at the intensity below") { [weak self] in
                guard let self else { return }
                selectedImpact = recipe
                select(.recipe(recipe.at(intensity: impactIntensity)), from: .uikit)
            })
        }
        views.append(slider("Impact intensity", value: impactIntensity, range: 0...1) { [weak self] value in
            guard let self else { return }
            impactIntensity = value
            if selectionSource == .uikit, let selectedImpact {
                selection = .recipe(selectedImpact.at(intensity: value))
                refreshSelection()
            }
        })
        views.append(button(title: "selection", detail: "UIKit selection") { [weak self] in
            self?.selectedImpact = nil
            self?.select(.recipe(.selection), from: .uikit)
        })
        for recipe in HapticRecipe.notifications {
            views.append(button(title: recipe.summary, detail: "UIKit notification") { [weak self] in
                self?.selectedImpact = nil
                self?.select(.recipe(recipe), from: .uikit)
            })
        }
        add(.uikit, header: "UIKit generators", footer: "A tap plays it and selects it.", rows: views)
    }

    private func buildTap() {
        add(.tap, header: "Core Haptics, a tap", footer: coreHapticsFooter, rows: [
            slider("Intensity", value: tapIntensity, range: 0...1) { [weak self] in
                self?.tapIntensity = $0
                self?.keepSelection(from: .tap)
            },
            slider("Sharpness", value: tapSharpness, range: 0...1) { [weak self] in
                self?.tapSharpness = $0
                self?.keepSelection(from: .tap)
            },
            button(title: "Play the tap", detail: "One transient event") { [weak self] in
                guard let self else { return }
                select(tapSound, from: .tap)
            },
        ], coreHaptics: true)
    }

    private func buildBuzz() {
        add(.buzz, header: "Core Haptics, a buzz", footer: coreHapticsFooter, rows: [
            slider("Intensity", value: buzzIntensity, range: 0...1) { [weak self] in
                self?.buzzIntensity = $0
                self?.keepSelection(from: .buzz)
            },
            slider("Sharpness", value: buzzSharpness, range: 0...1) { [weak self] in
                self?.buzzSharpness = $0
                self?.keepSelection(from: .buzz)
            },
            slider("Duration (s)", value: buzzDuration, range: 0.05...1) { [weak self] in
                self?.buzzDuration = $0
                self?.keepSelection(from: .buzz)
            },
            slider("Attack", value: buzzAttack, range: 0...1) { [weak self] in
                self?.buzzAttack = $0
                self?.keepSelection(from: .buzz)
            },
            slider("Decay", value: buzzDecay, range: 0...1) { [weak self] in
                self?.buzzDecay = $0
                self?.keepSelection(from: .buzz)
            },
            button(title: "Play the buzz", detail: "One continuous event") { [weak self] in
                guard let self else { return }
                select(buzzSound, from: .buzz)
            },
        ], coreHaptics: true)
    }

    private func buildPatterns() {
        add(.patterns, header: "Core Haptics, patterns", footer: coreHapticsFooter,
            rows: HapticPattern.presets.map { pattern in
                button(title: pattern.name, detail: pattern.events.count == 1 ? "1 event" : "\(pattern.events.count) events") { [weak self] in
                    self?.select(.pattern(pattern), from: .patterns)
                }
            }, coreHaptics: true)
    }

    private func buildVibration() {
        add(.vibration, header: "The system vibration",
            footer: "The long buzz (kSystemSoundID_Vibrate), for comparison. The undocumented peek/pop sounds are left out: the app couldn't ship them.",
            rows: [button(title: "System vibration", detail: "AudioServicesPlaySystemSound") { [weak self] in
                self?.select(.systemVibration, from: .vibration)
            }])
    }

    private func buildPacing() {
        let burstTitle = { (spacing: Double) in "Ten of the selection, \(Int((spacing * 1000).rounded())) ms apart" }
        var spaced: UIButton?
        let burst = button(
            title: "Burst",
            detail: "Ten steps 30 ms apart through Haptics.play: fewer play, which is the pacing (60 ms)"
        ) {
            for index in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.030 * Double(index)) { Haptics.play(.step) }
            }
        }
        let slider = slider("Spacing (s)", value: burstSpacing, range: 0.020...0.150) { [weak self] value in
            self?.burstSpacing = value
            spaced?.configuration?.title = burstTitle(value)
        }
        let spacedButton = button(title: burstTitle(burstSpacing), detail: "Unpaced: the spacing you chose") { [weak self] in
            guard let self else { return }
            let sound = selection
            let spacing = burstSpacing
            Haptics.prepareAudition(sound)
            for index in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(index)) { Haptics.audition(sound) }
            }
        }
        spaced = spacedButton
        add(.pacing, header: "Pacing", rows: [burst, slider, spacedButton])
    }

    private func buildContext() {
        let selected = Self.note("")
        selected.font = .appFont(forTextStyle: .subheadline)
        selected.textColor = .label
        selectionLabels.append(selected)

        // A button: warmed on press, played on release.
        let press = button(title: "A button", detail: "Press: prepare · release: play") { [weak self] in
            guard let self else { return }
            Haptics.audition(selection)
        }
        press.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.prepareAudition(selection)
        }, for: .touchDown)

        // A toggle: plays turning on, silent turning off — the app's rule.
        var toggle: UIButton?
        let toggleButton = button(title: "A toggle: off", detail: "Plays turning on, silent turning off") { [weak self] in
            guard let self else { return }
            toggleIsOn.toggle()
            toggle?.configuration?.title = toggleIsOn ? "A toggle: on" : "A toggle: off"
            if toggleIsOn { Haptics.audition(selection) }
        }
        toggle = toggleButton

        // A long press: the `held` moment.
        let held = PadView(text: "Long press: plays when held (0.5 s)")
        held.onTouchDown = { [weak self] in
            guard let self else { return }
            Haptics.prepareAudition(selection)
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.5
        held.addGestureRecognizer(longPress)
        held.heightAnchor.constraint(equalToConstant: 72).isActive = true

        add(.context, header: "In context",
            footer: "Each plays the selection. The strip: one per detent, paced like a step (60 ms) — drag slowly, then flick. The pull: once per crossing of the line, silent going back.",
            rows: [selected, press, toggleButton, held, makeStrip(), makePull()])
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        Haptics.audition(selection)
    }

    private func makeStrip() -> UIView {
        strip.delegate = self
        strip.showsHorizontalScrollIndicator = false
        strip.decelerationRate = .fast
        strip.layer.cornerRadius = 12
        strip.backgroundColor = .secondarySystemFill
        strip.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let spacing = Self.detentSpacing
        for index in 0..<Self.detentCount {
            let label = UILabel(frame: CGRect(x: CGFloat(index) * spacing, y: 0, width: spacing, height: 72))
            label.text = "\(index)"
            label.textAlignment = .center
            label.font = .appFont(forTextStyle: .headline)
            strip.addSubview(label)
        }
        strip.contentSize = CGSize(width: spacing * CGFloat(Self.detentCount), height: 72)
        return strip
    }

    private func makePull() -> UIView {
        let pad = PadView(text: "Pull down past the line")
        pad.clipsToBounds = true
        pad.heightAnchor.constraint(equalToConstant: Self.pullHeight).isActive = true
        pullFill.backgroundColor = tintColor.withAlphaComponent(0.25)
        pullFill.translatesAutoresizingMaskIntoConstraints = false
        pad.insertSubview(pullFill, at: 0)
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(line)
        let fillHeight = pullFill.heightAnchor.constraint(equalToConstant: 0)
        pullFillHeight = fillHeight
        NSLayoutConstraint.activate([
            pullFill.topAnchor.constraint(equalTo: pad.topAnchor),
            pullFill.leadingAnchor.constraint(equalTo: pad.leadingAnchor),
            pullFill.trailingAnchor.constraint(equalTo: pad.trailingAnchor),
            fillHeight,
            line.topAnchor.constraint(equalTo: pad.topAnchor, constant: Self.pullThreshold),
            line.leadingAnchor.constraint(equalTo: pad.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: pad.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 2),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pad.addGestureRecognizer(pan)
        // The pad's drag is the pull, never the page's scroll.
        scroll.panGestureRecognizer.require(toFail: pan)
        return pad
    }

    @objc private func pulled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pullArmed = false
            Haptics.prepareAudition(selection)
        case .changed:
            let travel = max(0, min(Self.pullHeight, recognizer.translation(in: recognizer.view).y))
            pullFillHeight?.constant = travel
            let past = travel >= Self.pullThreshold
            if past, !pullArmed { Haptics.audition(selection) }
            pullArmed = past
        default:
            pullArmed = false
            UIView.animate(withDuration: 0.25) {
                self.pullFillHeight?.constant = 0
                recognizer.view?.layoutIfNeeded()
            }
        }
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        Haptics.prepareAudition(selection)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === strip else { return }
        let index = Int((scrollView.contentOffset.x / Self.detentSpacing).rounded())
        guard (0..<Self.detentCount).contains(index), index != stripIndex else { return }
        stripIndex = index
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        let now = CACurrentMediaTime()
        guard now - stripLastPlayed >= Haptics.stepSpacing else { return }
        stripLastPlayed = now
        Haptics.audition(selection)
    }

    // MARK: - The selection

    private var tapSound: HapticSound {
        .pattern(HapticPattern(name: "Tap", events: [.tap(intensity: tapIntensity, sharpness: tapSharpness)]))
    }

    private var buzzSound: HapticSound {
        .pattern(HapticPattern(name: "Buzz", events: [.buzz(
            duration: buzzDuration, intensity: buzzIntensity, sharpness: buzzSharpness,
            attack: buzzAttack, decay: buzzDecay
        )]))
    }

    /// Plays `sound` and makes it the selection.
    func select(_ sound: HapticSound, from source: Section) {
        selection = sound
        selectionSource = source
        Haptics.audition(sound)
        refreshSelection()
    }

    /// A slider moved: the selection follows it if it came from its section.
    private func keepSelection(from source: Section) {
        guard selectionSource == source else { return }
        switch source {
        case .tap: selection = tapSound
        case .buzz: selection = buzzSound
        default: return
        }
        refreshSelection()
    }

    private func refreshSelection() {
        for label in selectionLabels { label.text = "Selected: \(selection.summary)" }
    }

    private func roleMenu(_ role: Haptic) -> [UIMenuElement] {
        var items: [UIMenuElement] = [UIAction(
            title: "Try the selection in the app", subtitle: selection.summary, image: UIImage(systemName: "wand.and.stars")
        ) { [weak self] _ in
            guard let self else { return }
            overrides[role] = selection
        }]
        if overrides[role] != nil {
            items.append(UIAction(
                title: "Back to today's", subtitle: role.recipe.summary,
                image: UIImage(systemName: "arrow.uturn.backward"), attributes: .destructive
            ) { [weak self] _ in
                self?.overrides[role] = nil
            })
        }
        return items
    }

    private func refreshRoles() {
        for (role, button) in roleDetails {
            let when = Self.when(role)
            if let candidate = overrides[role] {
                button.configuration?.title = "✦ \(role)"
                button.configuration?.subtitle = "Candidate: \(candidate.summary) — today: \(role.recipe.summary) — \(when)"
            } else {
                button.configuration?.title = "\(role)"
                button.configuration?.subtitle = "\(role.recipe.summary) — \(when)"
            }
        }
    }

    private func copyCatalog() {
        UIPasteboard.general.string = HapticCatalogExport.text(overrides: overrides)
        let alert = UIAlertController(
            title: "Catalog copied", message: "Paste it in the issue (#2193).", preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Building blocks

    private var tintColor: UIColor { view.tintColor ?? .tintColor }

    private var coreHapticsFooter: String? {
        HapticPatternPlayer.supportsHaptics
            ? "A tap plays it and selects it."
            : "Greyed out: no Taptic Engine here (the simulator). Core Haptics plays on a device."
    }

    private func add(_ section: Section, header: String?, footer: String? = nil, rows views: [UIView], coreHaptics: Bool = false) {
        let group = UIStackView()
        group.axis = .vertical
        group.spacing = Spacing.sm
        group.accessibilityIdentifier = "haptics.\(section.rawValue)"
        if let header {
            let label = UILabel()
            label.text = header
            label.font = .appFont(forTextStyle: .headline)
            label.numberOfLines = 0
            group.addArrangedSubview(label)
        }
        let disabled = coreHaptics && !HapticPatternPlayer.supportsHaptics
        for row in views {
            if disabled {
                row.isUserInteractionEnabled = false
                row.alpha = 0.4
            }
            group.addArrangedSubview(row)
        }
        if let footer { group.addArrangedSubview(Self.note(footer)) }
        rows[section] = views
        if !column.arrangedSubviews.isEmpty { column.setCustomSpacing(Spacing.xl, after: column.arrangedSubviews.last!) }
        column.addArrangedSubview(group)
    }

    private func button(title: String, detail: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.subtitle = detail.isEmpty ? nil : detail
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        return button
    }

    private func slider(
        _ title: String, value: Double, range: ClosedRange<Double>, changed: @escaping (Double) -> Void
    ) -> UIView {
        let label = UILabel()
        label.font = .appFont(forTextStyle: .subheadline)
        let format = { (value: Double) in "\(title): \(String(format: "%.2f", value))" }
        label.text = format(value)
        let control = UISlider()
        control.minimumValue = Float(range.lowerBound)
        control.maximumValue = Float(range.upperBound)
        control.value = Float(value)
        control.addAction(UIAction { [weak control] _ in
            guard let control else { return }
            let value = Double(control.value)
            label.text = format(value)
            changed(value)
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = Spacing.xs
        return stack
    }

    private static func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .appFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        return label
    }

    private static func when(_ role: Haptic) -> String {
        switch role {
        case .tick: "a fine step: a ruler, the dial, a choice in a list"
        case .step: "a coarse step: a page scrubbed, an emote past the wheel's detent"
        case .held: "a custom long press recognised"
        case .armed: "a drag crosses its commit point: a pull, the trash, the lock"
        case .grab: "a custom drag lifts an item"
        case .drop: "the item lands in a new place"
        case .boundary: "a scrub, ruler or dial reaches its end or centre"
        case .toggleOn: "a state turned on: follow, repost, bookmark"
        case .commit: "a weighty action: a stake, the shutter, recording"
        case .success: "an action of the viewer's succeeded"
        case .warning: "it happened, with a catch"
        case .error: "an action of the viewer's failed"
        }
    }
}

/// A plain pad that says when a finger lands on it (to warm the haptic).
private final class PadView: UIView {
    var onTouchDown: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 12
        let label = UILabel()
        label.text = text
        label.font = .appFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.md),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onTouchDown?()
    }
}
#endif
