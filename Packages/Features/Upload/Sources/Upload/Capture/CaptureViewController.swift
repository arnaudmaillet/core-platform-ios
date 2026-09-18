import DesignSystem
import MediaPlayback
import UIKit

/// The camera: "+" → Camera. Photographs and multi-clip videos, handed to the
/// media editor the moment a capture is done.
///
/// ```
/// │ Cancel                       Next │  ← the stack's bar; Next once there is a clip
/// │ ┌──────────────────────────────┐  │
/// │ │                              │  │
/// │ │     the preview, 9:16,       │  │  ← the ratio's window; grid, countdown
/// │ │     the chosen look          │  │
/// │ │      [0.5] [1×] [2] [3]      │  │  ← lens chips (or the band, when open)
/// │ │  ▣       (  ◉  )       ⌫     │  │  ← library · shutter · undo
/// │ └──────────────────────────────┘  │
/// │ [ ⚡ ⟲ ] [ ⏱  ▭  ◐  ⊞        ]    │  ← the toolbar: flash and flip, then the options
/// ```
///
/// ⚠️ **THE OPTIONS ARE ICONS IN A SELECTOR, AND AN ICON OPENS A BAND — THE
/// EDITOR'S PATTERN, NOT ITS CODE.** Choosing timer, ratio or filters
/// opens that option's controls above the shutter; a second tap on the chosen
/// icon closes them again (the editor's neutral state). The grid is a toggle
/// and opens nothing. The band is `MediaEditorBandView`, its tenants arrive
/// with `BandPop` and `UISound.pop`, and leave quicker than they came.
///
/// ⚠️ **A CAPTURE IS NEVER BAKED: THE LOOK AND THE RATIO TRAVEL AS THE EDITOR'S
/// OWN EDITS.** The files keep the whole frame and the untouched picture; the
/// chosen filter becomes `MediaEdits.filter` and the ratio a centred
/// `MediaEdits.crop`, handed over through `initialEdits`. The author can still
/// change both in the editor, and no pixel is rendered twice. The preview SHOWS
/// both while shooting — the look through `CaptureLiveView`, the ratio as the
/// window the letterbox leaves.
///
/// ⚠️ **ONCE A TAKE HAS A CLIP, THE SHUTTER RECORDS; IT NEVER PHOTOGRAPHS.** See
/// `CaptureShutterLogic` for why, and `CaptureTake` for the three-minute budget
/// and the two-tap undo.
///
/// ⚠️ **ALWAYS DARK**, for the editor's reason: a capture surface is a viewing
/// surface, and the colour that disappears next to a picture is black.
@MainActor
final class CaptureViewController: UIViewController {
    typealias MakeEditor = ([MediaLibraryItem], [String: MediaEdits]) -> UIViewController

    private let source: any CaptureSource
    private let folder: CaptureFolder
    /// The captures, as the editor and the finalisation screen will read them.
    let captures: CapturedMediaLibrary
    /// The library shortcut's face: the newest picture in the library, or nil
    /// — see `CaptureLibraryFace`.
    private let libraryFace: (@MainActor () async -> UIImage?)?
    private let makeEditor: MakeEditor
    private let makeLibraryPicker: (() -> UIViewController)?
    private let reducesMotion: () -> Bool

    private(set) var settings = CaptureSettings()
    private(set) var take: CaptureTake
    private(set) var shutterLogic = CaptureShutterLogic()
    private(set) var authorization: CaptureAuthorization?
    private(set) var isRecording = false
    /// A photograph being written or a take being stitched: the shutter waits.
    private(set) var isBusy = false
    private var countdownTask: Task<Void, Never>?
    private var holdBaseZoom: CGFloat = 1
    private var pinchBaseZoom: CGFloat = 1
    /// The last stitch, reused while the take has not changed since.
    private var stitched: (clips: [URL], url: URL, duration: TimeInterval)?

    // MARK: Views

    private let previewContainer = UIView()
    private let liveView = CaptureLiveView()
    /// The pictures' host: what a flip turns, rounded like the zone on all
    /// four corners — see `flip()` and `matchTheSheetsCorners`.
    private let flipHost = UIView()
    private let letterboxTop = UIView()
    private let letterboxBottom = UIView()
    private let gridView = CaptureGridView()
    private let flashView = UIView()
    private let countdownLabel = UILabel()
    private let focusRing = UIView()
    private let timePill = UIVisualEffectView(effect: nil)
    private let timeLabel = UILabel()
    private let toast = UIVisualEffectView(effect: nil)
    private let toastLabel = UILabel()
    private var notice: CaptureAccessNoticeView?

    let shutter = CaptureShutterView()
    private let lockView = CaptureLockView()
    private let lensChips = CaptureLensChipsView()
    private let band = MediaEditorBandView()
    private let libraryButton = UIButton(type: .custom)
    private lazy var undoButton: UIButton = {
        let button = UIButton(configuration: .glass())
        button.configuration?.image = UIImage(systemName: "delete.left.fill")
        button.accessibilityLabel = "Delete last clip"
        button.addAction(UIAction { [weak self] _ in self?.undoTapped() }, for: .primaryActionTriggered)
        return button
    }()
    /// The header's "Next", while the take has a clip — see `refreshNextItem`.
    private var nextItem: UIBarButtonItem?
    static let nextItemID = "upload.camera.next"

    private let selector = IconSelectorBar(items: CaptureOption.allCases.map {
        IconSelectorBar.Item(
            symbolName: CaptureViewController.symbol(for: $0, settings: CaptureSettings()),
            accessibilityLabel: CaptureViewController.spokenName(for: $0, settings: CaptureSettings())
        )
    })

    private lazy var timerRow = CaptureChoiceRowView(
        choices: CaptureTimer.allCases, chosen: settings.timer, label: \.label, spoken: \.spoken
    )
    private lazy var ratioRow = CaptureChoiceRowView(
        choices: CaptureRatio.allCases, chosen: settings.ratio, label: \.label, spoken: \.spoken
    )
    private lazy var filterRow = MediaFilterRowView()

    private lazy var cancelItem = UIBarButtonItem(
        title: "Cancel", primaryAction: UIAction { [weak self] _ in self?.cancelTapped() }
    )
    /// The toolbar's LEADING strip: the flash and the flip.
    ///
    /// ⚠️ **ASKED FOR IN THOSE WORDS**: both icons in the bottom toolbar, on the
    /// left, "toujours en largeur sa taille intrinsèque (prioritaire)", the
    /// options' selector taking the rest — "le même système qu'on a fait sur
    /// l'écran d'édition des médias". So it is the editor's leading strip:
    /// an `IconActionBar`, momentary, drawn without a backdrop inside the
    /// toolbar's glass.
    ///
    /// ⚠️ **THE FLASH CYCLES ON A TAP — AUTO → ON → OFF — AND DOES NOT OPEN A
    /// MENU.** `IconActionBar` is a row of momentary buttons with no menu to
    /// carry, and giving it one is a DesignSystem change. The icon names the
    /// mode it is in, so the author sees each step as they take it; VoiceOver
    /// says it ("Flash, auto"). Dimmed where the camera has no flash — the
    /// front one — rather than taken away, so the strip keeps its width and
    /// the bar is not handed over again for it.
    private(set) lazy var leadingBar: IconActionBar = {
        let bar = IconActionBar(items: leadingItems())
        bar.suppressesBackdrop = true
        bar.onTap = { [weak self] index in
            switch LeadingAction(rawValue: index) {
            case .flash: self?.cycleFlash()
            case .flip: self?.flip()
            case nil: break
            }
        }
        return bar
    }()

    /// The leading strip's items. The raw value is the bar's index.
    enum LeadingAction: Int, CaseIterable {
        case flash
        case flip
    }

    private func leadingItems() -> [IconActionBar.Item] {
        let flash = source.hasFlash
            ? "Flash, \(settings.flash.label.lowercased())"
            : "Flash, unavailable"
        return [
            IconActionBar.Item(symbolName: settings.flash.symbolName, accessibilityLabel: flash),
            IconActionBar.Item(symbolName: "arrow.triangle.2.circlepath.camera", accessibilityLabel: "Switch camera")
        ]
    }

    private func refreshLeadingBar() {
        leadingBar.setItems(leadingItems())
        leadingBar.setEnabled(source.hasFlash, at: LeadingAction.flash.rawValue)
    }

    private func cycleFlash() {
        UISelectionFeedbackGenerator().selectionChanged()
        setFlash(settings.flash.next)
    }

    private let ringLink = CaptureLinkProxy()
    private var cardsTimer: Timer?

    init(
        source: any CaptureSource,
        folder: CaptureFolder,
        captures: CapturedMediaLibrary,
        libraryFace: (@MainActor () async -> UIImage?)?,
        takeLimit: TimeInterval = CaptureTake.maximum,
        reducesMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        makeLibraryPicker: (() -> UIViewController)?,
        makeEditor: @escaping MakeEditor
    ) {
        self.take = CaptureTake(limit: takeLimit)
        self.source = source
        self.folder = folder
        self.captures = captures
        self.libraryFace = libraryFace
        self.reducesMotion = reducesMotion
        self.makeLibraryPicker = makeLibraryPicker
        self.makeEditor = makeEditor
        super.init(nibName: nil, bundle: nil)
        // The top bar belongs to the screen — a navigation controller reads
        // `navigationItem` on the way in (the picker's and editor's note).
        configureBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        configurePreview()
        configureControls()
        configureSelector()
        refreshTakeControls(animated: false)
        applyFrameDelivery()
        #if DEBUG
        runDebugScriptIfAsked()
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isClosing = false
        UISound.prepare()
        // The options live in the stack's toolbar, as the editor's categories
        // do — see `handOverSelector`.
        navigationController?.setToolbarHidden(false, animated: animated)
        configureToolbarAppearance()
        startCamera()
        sweepReleased()
        // ⚠️ THE CARDS' TIMER STOPS WHEN THE CAMERA IS LEFT (`viewDidDisappear`)
        // and the Filters band can still be open when the author comes back
        // from the editor or the picker: without this the nine cards froze on
        // the frame from before they left.
        if openOption == .filters { startCardsTimer() }
    }

    /// The toolbar's appearance as the camera found it, put back on the way out.
    private var restoreToolbar: (() -> Void)?

    /// ⚠️ **TRANSPARENT, AS THE EDITOR'S IS** — the preview runs under the bar
    /// and a bar background would cut it — and put back on the way out: the
    /// library's picker, pushed from here, draws its album strip on the same
    /// toolbar with the appearance it expects.
    private func configureToolbarAppearance() {
        guard let toolbar = navigationController?.toolbar, restoreToolbar == nil else { return }
        let standard = toolbar.standardAppearance
        let compact = toolbar.compactAppearance
        let scrollEdge = toolbar.scrollEdgeAppearance
        restoreToolbar = { [weak toolbar] in
            toolbar?.standardAppearance = standard
            toolbar?.compactAppearance = compact
            toolbar?.scrollEdgeAppearance = scrollEdge
        }
        let clear = UIToolbarAppearance()
        clear.configureWithTransparentBackground()
        toolbar.standardAppearance = clear
        toolbar.compactAppearance = clear
        toolbar.scrollEdgeAppearance = clear
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreToolbar?()
        restoreToolbar = nil
        if navigationController?.isBeingDismissed == true || isBeingDismissed { isClosing = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // ⚠️ A RUNNING SESSION HOLDS THE CAMERA AND BURNS POWER — the deleted
        // screen's rule. A clip still recording is ended, not lost.
        if isRecording { requestStop() }
        cancelCountdown()
        stopCardsTimer()
        source.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWindow()
        let held = shareTheBar()
        guard !isHandingOver else { return }
        let moved = zip([handedWidths?.leading, handedWidths?.trailing], [held?.leading, held?.trailing])
            .contains { abs(($0 ?? -1) - ($1 ?? -2)) > 0.5 }
        if owesAHandover || moved { handOverSelector(animated: false) }
    }

    private func startCamera() {
        Task { [weak self] in
            guard let self else { return }
            let answer = await source.authorize()
            authorization = answer
            switch answer {
            case .denied:
                showNotice(.denied)
            case .unavailable:
                showNotice(.unavailable)
            case .authorized:
                notice?.removeFromSuperview()
                notice = nil
                // A real session reports its lenses once it is running.
                source.onStateChange = { [weak self] in self?.refreshLenses() }
                source.start()
                refreshLenses()
            }
        }
    }

    // MARK: - Bars

    private func configureBars() {
        navigationItem.leftBarButtonItems = [cancelItem]
        // The flip and the flash live in the toolbar's leading strip.
        navigationItem.backButtonDisplayMode = .minimal
        // ⚠️ TRANSPARENT, AND STATED ON THIS SCREEN'S ITEM — a bar appearance
        // set on the stack's bar would follow the author into the editor.
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        navigationItem.standardAppearance = clear
        navigationItem.scrollEdgeAppearance = clear
        navigationItem.compactAppearance = clear
    }

    /// The sheet is on its way out: Cancel or Discard, or a swipe that
    /// dismisses it. Cleared if the camera comes back.
    private var isClosing = false

    /// Whether a finished capture may still be handed over: the camera is what
    /// the author sees, and the sheet is not leaving.
    ///
    /// ⚠️ **"ON TOP" IS NOT ENOUGH.** During a dismissal the camera is still the
    /// top screen: a photograph, or a join of the take, that landed during
    /// Cancel's slide-down was registered, and an editor built and pushed
    /// inside the sheet on its way out. It is now dropped, file and all.
    private var canHandOff: Bool {
        !isClosing && view.window != nil && navigationController?.isBeingDismissed != true
            && navigationController?.topViewController === self
    }

    private func close() {
        isClosing = true
        dismiss(animated: true)
    }

    private func cancelTapped() {
        guard !take.isEmpty else {
            close()
            return
        }
        // ⚠️ CLIPS ARE WORK. A cancel that silently threw away a minute of
        // recording would be the one tap on this screen that cannot be undone.
        let count = take.clips.count
        let alert = UIAlertController(
            title: count == 1 ? "Discard this clip?" : "Discard \(count) clips?",
            message: "What you recorded will be lost.", preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.close()
        })
        alert.addAction(UIAlertAction(title: "Keep Recording", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = cancelItem
        present(alert, animated: true)
    }

    // MARK: - Preview

    private func configurePreview() {
        previewContainer.backgroundColor = .black
        previewContainer.clipsToBounds = true
        // Its corners are the sheet's — see `matchTheSheetsCorners`.
        previewContainer.cornerConfiguration = .corners(radius: .containerConcentric(minimum: Self.cornerFloor))
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewContainer)
        // ⚠️ **ALWAYS THE FRAME'S OWN 9:16, NARROWED AND CENTRED WHEN THE
        // HEIGHT RUNS OUT.** The container used to keep the full width and let
        // its height give: on a height-capped sheet (an iPhone SE) it was wider
        // than 9:16, the aspect fill cut the frame's top and bottom, and the
        // 9:16 window — narrower than the container — left the picture's sides
        // unmasked, showing more than a 9:16 crop keeps. At exactly 9:16 the
        // fill cuts nothing and the window, the preview and the crop handed to
        // the editor are the same rectangle; an SE gets thin bars at the sides.
        let wide = previewContainer.widthAnchor.constraint(equalTo: view.widthAnchor)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewContainer.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
            previewContainer.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor),
            previewContainer.heightAnchor.constraint(equalTo: previewContainer.widthAnchor, multiplier: 16.0 / 9.0),
            wide
        ])

        // The pictures sit in a host of their own — what a flip turns.
        flipHost.backgroundColor = .black
        flipHost.pin(to: previewContainer)
        if let plain = source.plainPreview { plain.pin(to: flipHost) }
        liveView.pin(to: flipHost)
        // The feed's consumer is decided by `applyFrameDelivery`.

        for bar in [letterboxTop, letterboxBottom] {
            bar.backgroundColor = UIColor.black.withAlphaComponent(0.9)
            bar.isUserInteractionEnabled = false
            previewContainer.addSubview(bar)
        }
        gridView.isHidden = true
        previewContainer.addSubview(gridView)

        focusRing.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusRing.layer.borderColor = UIColor.systemYellow.cgColor
        focusRing.layer.borderWidth = 1.5
        focusRing.alpha = 0
        focusRing.isUserInteractionEnabled = false
        previewContainer.addSubview(focusRing)

        flashView.backgroundColor = .white
        flashView.alpha = 0
        flashView.isUserInteractionEnabled = false
        flashView.pin(to: previewContainer)

        countdownLabel.font = .systemFont(ofSize: 132, weight: .heavy).rounded
        countdownLabel.textColor = .white
        countdownLabel.textAlignment = .center
        countdownLabel.alpha = 0
        countdownLabel.layer.shadowColor = UIColor.black.cgColor
        countdownLabel.layer.shadowOpacity = 0.35
        countdownLabel.layer.shadowRadius = 12
        countdownLabel.layer.shadowOffset = .zero
        countdownLabel.constrain(in: previewContainer) { container in
            countdownLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor)
            countdownLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        previewContainer.addGestureRecognizer(pinch)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        previewContainer.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(previewTapped(_:)))
        tap.require(toFail: doubleTap)
        previewContainer.addGestureRecognizer(tap)
    }

    /// Where the ratio's window stands in the preview, and the letterbox
    /// around it.
    /// The camera zone's foot, rounded like the top of the sheet.
    ///
    /// ⚠️ **ASKED FOR: THE FOOT OF THE CAMERA ZONE ROUNDED LIKE THE TOP OF THE
    /// SHEET.** The radius is not hard-coded, and not read from anything
    /// private: the zone's top corners are CONCENTRIC with their container —
    /// the sheet, whose top edge they sit on — so UIKit answers the sheet's
    /// radius as their effective radius (`effectiveRadius(corner:)`, iOS 26),
    /// and the foot is given that same number. Where there is no sheet to be
    /// concentric with (a test's window), the floor stands in.
    private func matchTheSheetsCorners() {
        let top = previewContainer.effectiveRadius(corner: .topLeft)
        let radius = max(Self.cornerFloor, top)
        guard abs(radius - sheetRadius) > 0.25 else { return }
        sheetRadius = radius
        previewContainer.cornerConfiguration = .corners(
            topLeftRadius: .containerConcentric(minimum: Self.cornerFloor),
            topRightRadius: .containerConcentric(minimum: Self.cornerFloor),
            bottomLeftRadius: .fixed(radius),
            bottomRightRadius: .fixed(radius)
        )
        // ⚠️ **WHAT A FLIP TURNS WEARS THE SAME CORNERS, ALL FOUR.** A flip
        // turns the pictures' host in 3D (`flip()`), away from the sheet's
        // edge and inside the zone: with square corners of its own, square
        // corners were what the author saw turning. At rest they coincide
        // with the zone's and cannot be seen.
        flipHost.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        flipHost.clipsToBounds = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-camera-log-frames") {
            NSLog("[camera-corners] sheet radius %.2f", radius)
        }
        #endif
    }

    /// The sheet's corner radius as last read — see `matchTheSheetsCorners`.
    private(set) var sheetRadius: CGFloat = 0

    /// The least the camera zone's corners are rounded, where no sheet says
    /// otherwise.
    static let cornerFloor: CGFloat = 24

    private func layoutWindow() {
        matchTheSheetsCorners()
        let bounds = previewContainer.bounds
        guard bounds.width > 0 else { return }
        let window = settings.ratio.window(in: bounds)
        letterboxTop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: window.minY)
        letterboxBottom.frame = CGRect(x: 0, y: window.maxY, width: bounds.width, height: bounds.height - window.maxY)
        gridView.frame = window
    }

    // MARK: - Controls

    private func configureControls() {
        shutter.onTap = { [weak self] in self?.shutterTapped() }
        shutter.onHoldBegan = { [weak self] in self?.holdBegan() }
        shutter.onHoldMoved = { [weak self] in self?.holdMoved($0) }
        shutter.onHoldEnded = { [weak self] in self?.holdEnded() }

        shutter.constrain(in: view) { view in
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            shutter.widthAnchor.constraint(equalToConstant: CaptureShutterView.side)
            shutter.heightAnchor.constraint(equalToConstant: CaptureShutterView.side)
        }

        lockView.alpha = 0
        lockView.constrain(in: view) { _ in
            lockView.centerYAnchor.constraint(equalTo: shutter.centerYAnchor)
            lockView.centerXAnchor.constraint(equalTo: shutter.centerXAnchor, constant: -(CaptureShutterLogic.lockDistance + 12))
        }

        libraryButton.clipsToBounds = true
        libraryButton.layer.cornerRadius = 10
        libraryButton.layer.cornerCurve = .continuous
        libraryButton.layer.borderColor = UIColor.white.cgColor
        libraryButton.layer.borderWidth = 2
        // A neutral face until the newest picture can be shown — see
        // `loadLibraryShortcut`.
        libraryButton.setImage(
            UIImage(systemName: "photo.on.rectangle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
        libraryButton.tintColor = .white
        libraryButton.imageView?.contentMode = .center
        libraryButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        libraryButton.accessibilityLabel = "Choose from library"
        libraryButton.isHidden = true
        libraryButton.addAction(UIAction { [weak self] _ in self?.openLibrary() }, for: .primaryActionTriggered)
        libraryButton.constrain(in: view) { _ in
            libraryButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor)
            libraryButton.centerXAnchor.constraint(equalTo: shutter.centerXAnchor, constant: -Self.besideTheShutter)
            libraryButton.widthAnchor.constraint(equalToConstant: 44)
            libraryButton.heightAnchor.constraint(equalToConstant: 44)
        }

        // ⚠️ **UNDO TO THE RIGHT OF THE SHUTTER, THE LIBRARY TO ITS LEFT —
        // ASKED FOR** ("déplacer le bouton pour supprimer la prise… à droite du
        // bouton de capture"), so the shortcut can stay beside a take. The row
        // reads — and VoiceOver reads it — library, shutter, undo.
        undoButton.constrain(in: view) { _ in
            undoButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor)
            undoButton.centerXAnchor.constraint(equalTo: shutter.centerXAnchor, constant: Self.besideTheShutter)
            undoButton.widthAnchor.constraint(equalToConstant: 48)
            undoButton.heightAnchor.constraint(equalToConstant: 48)
        }

        lensChips.onPick = { [weak self] lens in self?.pickLens(lens) }
        lensChips.constrain(in: view) { view in
            lensChips.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            lensChips.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: -Spacing.md)
        }

        band.constrain(in: view) { view in
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            band.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: -Spacing.sm)
        }

        timePill.cornerConfiguration = .capsule()
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.pin(to: timePill.contentView, insets: NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        timePill.alpha = 0
        timePill.constrain(in: view) { view in
            timePill.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            timePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
        }

        toast.cornerConfiguration = .capsule()
        toastLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.pin(to: toast.contentView, insets: NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        toast.alpha = 0
        toast.isUserInteractionEnabled = false
        toast.constrain(in: view) { view in
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            toast.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
        }

        ringLink.onTick = { [weak self] in self?.ringTick() }
        loadLibraryShortcut()
    }

    /// How far the library shortcut and undo sit from the shutter's centre, on
    /// either side.
    static let besideTheShutter: CGFloat = 112

    /// ⚠️ **GLASS IS MATERIALISED ONCE A WINDOW EXISTS** — the `IconSelectorBar`
    /// rule about contacting the render server before there is one.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        handOverSelector(animated: false)
        if timePill.effect == nil { timePill.effect = UIGlassEffect() }
        if toast.effect == nil { toast.effect = UIGlassEffect() }
    }

    // MARK: - Selector

    private func configureSelector() {
        // ⚠️ THE SHUTTER STANDS INSIDE THE PICTURE, NEVER ACROSS ITS EDGE. On
        // the first run the preview's rounded foot cut through the ring. It
        // rests just above the stack's toolbar — the safe area's foot, which
        // the visible toolbar raises — and is lifted into the preview where
        // the phone is too short for both (an SE).
        let resting = shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md)
        resting.priority = .defaultHigh
        NSLayoutConstraint.activate([
            shutter.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md),
            shutter.bottomAnchor.constraint(lessThanOrEqualTo: previewContainer.bottomAnchor, constant: -Spacing.lg),
            resting
        ])
        // ⚠️ **A REAL BAR ITEM IN THE STACK'S TOOLBAR, TRAILING — THE EDITOR'S
        // STRIP, NOT A LOOKALIKE.** It stood in the camera's own layout,
        // centred, with its own glass capsule, and it read as a different
        // control: the pill sat in a capsule of another height, with unequal
        // margins at the top and the sides. The toolbar supplies the glass, so
        // the bar draws none of its own — the rule `IconSelectorBar` states for
        // any bar that lives in one.
        selector.suppressesBackdrop = true
        selector.onSelect = { [weak self] index in self?.optionChosen(index) }
        // ⚠️ A SECOND TAP ON THE CHOSEN ICON PUTS ITS CONTROLS AWAY — the
        // editor's neutral state, asked for in the same words.
        selector.onReselect = { [weak self] _ in self?.closeOption() }
        selector.onSelectNothing = { [weak self] in self?.showBand(nil) }
        selector.selectNothing(notify: false)

        timerRow.onPick = { [weak self] in self?.setTimer($0) }
        ratioRow.onPick = { [weak self] in self?.setRatio($0) }
        filterRow.onPick = { [weak self] in self?.setFilter($0) }
    }

    static func symbol(for option: CaptureOption, settings: CaptureSettings) -> String {
        switch option {
        case .timer: settings.timer.symbolName
        case .ratio: "aspectratio"
        case .filters: "camera.filters"
        case .grid: settings.showsGrid ? "squareshape.split.3x3" : "square.dashed"
        }
    }

    /// The icons wear the state they set: the bolt is slashed while the flash
    /// is off, the timer shows its seconds, the grid its lines.
    /// What VoiceOver says for an option: its name, and the state its icon
    /// draws — the grid on or off, the flash and the timer as set.
    ///
    /// ⚠️ **THE STATE WAS ONLY A PICTURE.** The grid opens no band, so a
    /// VoiceOver user had no way to learn whether it was on. The shape keeps
    /// its bare title: its lock is found by it (`ratioButton`), and speaks
    /// through the button's value instead.
    static func spokenName(for option: CaptureOption, settings: CaptureSettings) -> String {
        switch option {
        case .timer: "\(option.title), \(settings.timer.spoken.lowercased())"
        case .grid: "\(option.title), \(settings.showsGrid ? "on" : "off")"
        case .ratio, .filters: option.title
        }
    }

    private func refreshSelectorIcons() {
        selector.setItems(CaptureOption.allCases.map {
            IconSelectorBar.Item(
                symbolName: Self.symbol(for: $0, settings: settings),
                accessibilityLabel: Self.spokenName(for: $0, settings: settings)
            )
        })
        applyShapeLock()
    }

    /// ⚠️ **ONE SHAPE AND ONE LOOK FOR THE WHOLE VIDEO — THE SHAPE LOCKED,
    /// THE LOOK SAID.** A take is stitched into one video and handed to the
    /// editor as ONE item with one set of edits, so the shape and the look in
    /// force at Next apply to every clip, including clips shot under another.
    /// The author decided: once the take has a clip the shape is locked — its
    /// icon dimmed, a tap explaining how to free it — while the look stays
    /// free and says, the first time it changes mid-take, that it applies to
    /// the whole video. Keeping a shape and a look per clip would mean handing
    /// the editor each clip as its own piece, which is a larger change.
    private func optionChosen(_ index: Int) {
        guard let option = CaptureOption(rawValue: index) else { return }
        take.disarm()
        refreshTakeControls(animated: true)
        if option == .ratio, !take.isEmpty {
            selector.selectNothing(notify: false)
            showBand(nil)
            say("Undo your clips to change the shape")
            return
        }
        if option == .grid {
            settings.showsGrid.toggle()
            applyGrid(animated: true)
            refreshSelectorIcons()
            selector.selectNothing(notify: false)
            showBand(nil)
            return
        }
        showBand(option)
    }

    private func closeOption() {
        selector.selectNothing(notify: false)
        showBand(nil)
    }

    /// The option whose controls are standing in the band.
    private(set) var openOption: CaptureOption?

    private func tenant(for option: CaptureOption) -> UIView? {
        switch option {
        case .timer: timerRow
        case .ratio: ratioRow
        case .filters: filterRow
        case .grid: nil
        }
    }

    /// ⚠️ **THE DEPARTING TENANT IS RELEASED BEFORE ANYTHING ELSE** —
    /// `MediaEditorBandView.release()`'s reason: `openOption` answers "what is
    /// up" at once, while the old row fades out on its own.
    private func showBand(_ option: CaptureOption?) {
        let wanted = option.flatMap(tenant(for:))
        guard wanted !== band.content else { return }
        let departing = band.content != nil ? band.release() : nil
        openOption = wanted == nil ? nil : option
        if let wanted {
            // ⚠️ A ROW SHOWN AGAIN MID-DEPARTURE ARRIVES WHOLE, AT ONCE: its
            // departure is cut short, and `popOut` leaves it with the band.
            wanted.layer.removeAllAnimations()
            wanted.alpha = 1
            wanted.transform = .identity
            band.show(wanted)
        } else {
            band.clear()
        }
        view.layoutIfNeeded()
        if let departing { popOut(departing) }
        if let wanted { popIn(wanted) }
        // The band takes the chips' place; they come back when it closes.
        setShown(lensChips, wanted == nil && lensChips.debugTitles.count > 1, animated: true)
        if option == .filters {
            startCardsTimer()
        } else {
            stopCardsTimer()
        }
        applyFrameDelivery()
    }

    /// The editor's arrival curve — each element the tenant names, one after
    /// another, each with its pop — read, not shared: that function is the
    /// editor's own.
    private func popIn(_ tenant: UIView) {
        guard !reducesMotion() else { return }
        let named = (tenant as? PoppingTenant)?.poppableElements ?? []
        let elements = named.isEmpty ? [tenant] : named
        for (index, element) in elements.enumerated() {
            // ⚠️ SILENT WHILE RECORDING: the microphone is open, and a pop
            // would be in the clip.
            if index < BandPop.audibleElements, !isRecording {
                UISound.pop.play(after: BandPop.stagger(for: index))
            }
            element.alpha = 0
            element.transform = BandPop.collapsedTransform
            UIView.animate(
                withDuration: BandPop.duration, delay: BandPop.stagger(for: index),
                usingSpringWithDamping: BandPop.dampingRatio, initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                element.alpha = 1
                element.transform = .identity
            }
        }
        debugPopIns += 1
    }

    private func popOut(_ departing: UIView) {
        guard !reducesMotion() else {
            departing.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: BandPop.departure, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            departing.alpha = 0
            departing.transform = BandPop.collapsedTransform
        } completion: { [weak self] _ in
            departing.alpha = 1
            departing.transform = .identity
            // ⚠️ **NOT IF THE BAND HAS TAKEN IT BACK.** The rows are built once
            // and shown again: reopened within the 0.17s of its departure, a
            // row was back in the band when this ran, and was pulled out of it
            // — an open band holding nothing, with its icon chosen. Every flow
            // test ran with motion reduced, which skips this block entirely.
            guard departing !== self?.band.content else { return }
            departing.removeFromSuperview()
        }
    }

    // MARK: - Settings

    private func setFlash(_ mode: CaptureFlashMode) {
        settings.flash = mode
        refreshLeadingBar()
    }

    private func setTimer(_ timer: CaptureTimer) {
        settings.timer = timer
        refreshSelectorIcons()
    }

    private func setRatio(_ ratio: CaptureRatio) {
        settings.ratio = ratio
        let animate = !reducesMotion()
        UIView.animate(
            withDuration: animate ? 0.45 : 0, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.layoutWindow()
        }
    }

    /// Whether this take has already been told its look is the whole video's.
    private var hasSaidTheLookIsWhole = false

    private func setFilter(_ filter: MediaFilter) {
        if !take.isEmpty, !hasSaidTheLookIsWhole, filter != settings.filter {
            hasSaidTheLookIsWhole = true
            say("The look applies to the whole video")
        }
        settings.filter = filter
        liveView.setLook(FrameLook(preset: filter))
        applyFrameDelivery()
    }

    private func applyGrid(animated: Bool) {
        setShown(gridView, settings.showsGrid, animated: animated)
    }

    /// ⚠️ **THE CHEAPEST PREVIEW THAT SHOWS THE TRUTH.** With no look chosen
    /// and a source that has a plain preview, the Metal view is hidden and the
    /// source stops delivering frames — unless the filter row is open, whose
    /// cards are drawn from the live frame.
    ///
    /// ⚠️ **A HIDDEN LIVE VIEW DRAWS NOTHING.** With the filter row open and no
    /// look chosen, frames flow for the cards, which read `latestFrame` twice a
    /// second — and every one of them was ALSO rendered, at full drawable size,
    /// into the hidden Metal layer. The feed keeps the latest frame whether or
    /// not it has a consumer; the renderer is only its consumer while it shows.
    private func applyFrameDelivery() {
        let hasPlain = source.plainPreview != nil
        let needsLook = settings.filter != .original
        liveView.isHidden = hasPlain && !needsLook
        source.feed.setConsumer(liveView.isHidden ? nil : liveView.makeSink())
        source.setDeliversFrames(!hasPlain || needsLook || openOption == .filters)
    }

    /// The filter row's cards, redrawn from the newest frame while the row is
    /// open — twice a second, which reads as live and costs nine 56pt renders.
    private func startCardsTimer() {
        refreshCards()
        guard cardsTimer == nil else { return }
        cardsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCards() }
        }
    }

    private func stopCardsTimer() {
        cardsTimer?.invalidate()
        cardsTimer = nil
    }

    private func refreshCards() {
        guard let frame = source.feed.latestFrame else { return }
        let side = MediaFilterRowView.thumbnailSide * (view.window?.screen.scale ?? 3)
        Task { [weak self] in
            let picture = await Task.detached(priority: .userInitiated) {
                CaptureLiveView.snapshot(of: frame, side: side)
            }.value
            guard let self, openOption == .filters, let picture else { return }
            debugCardRefreshes += 1
            filterRow.show(picture)
            filterRow.setSelected(settings.filter)
        }
    }

    // MARK: - The shutter

    /// A stop has been asked for and the clip's file is still being finished:
    /// the take does not hold it yet, so nothing can know what a tap means.
    ///
    /// ⚠️ **THE SHUTTER REFUSES IN THIS WINDOW, AND LOOKS BUSY WHILE IT DOES.**
    /// Before, a tap there saw an empty take and took a PHOTOGRAPH in the
    /// middle of a video, or a hold was swallowed with the padlock shown for a
    /// recording that never started.
    private var isFinishingClip: Bool { isRecording && shutterLogic.phase == .idle }

    private func shutterTapped() {
        guard authorizedToShoot, !isBusy, !isFinishingClip else { return }
        if countdownTask != nil {
            // A tap during the countdown calls it off.
            cancelCountdown()
            return
        }
        take.disarm()
        let action = shutterLogic.tap(takeIsEmpty: take.isEmpty, takeIsFull: take.isFull)
        switch action {
        case .takePhoto:
            afterCountdown { [weak self] in self?.takePhoto() }
        case .startRecording(let locked):
            // The logic already stands locked; the recording waits out the timer.
            afterCountdown { [weak self] in self?.startRecording(locked: locked) }
        case .stopRecording:
            requestStop()
        case .none where take.isFull:
            say(take.limitReachedMessage)
        default:
            break
        }
        refreshTakeControls(animated: true)
    }

    private func holdBegan() {
        guard authorizedToShoot, !isBusy, !isFinishingClip, countdownTask == nil else { return }
        take.disarm()
        let action = shutterLogic.beginHold(takeIsFull: take.isFull)
        guard case .startRecording = action else {
            if take.isFull { say(take.limitReachedMessage) }
            return
        }
        holdBaseZoom = source.zoom
        // ⚠️ A HOLD WITH A TIMER SET IS HANDS-FREE: the timer exists so the
        // author can step back, and a finger on the shutter cannot.
        if settings.timer != .off {
            _ = shutterLogic.moveHold(by: CGPoint(x: -CaptureShutterLogic.lockDistance, y: 0))
            afterCountdown { [weak self] in self?.startRecording(locked: true) }
            return
        }
        startRecording(locked: false)
        showLock(true)
    }

    private func holdMoved(_ translation: CGPoint) {
        guard isRecording, shutterLogic.phase == .holding else { return }
        lockView.setProgress(CaptureShutterLogic.lockProgress(for: translation))
        // An upward slide zooms, from where the zoom stood when the hold began.
        if translation.y < -8 {
            let zoom = CaptureShutterLogic.zoom(from: holdBaseZoom, translation: translation)
            source.setZoom(zoom, smoothly: false)
            lensChips.setZoom(source.zoom)
        }
        if shutterLogic.moveHold(by: translation) == .lock {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            lockView.setLocked(true)
            shutter.setLook(.locked, animated: true)
            UIView.animate(withDuration: 0.25, delay: 0.35, options: [.beginFromCurrentState]) {
                self.lockView.alpha = 0
            }
        }
    }

    private func holdEnded() {
        let action = shutterLogic.endHold()
        showLock(false)
        if action == .stopRecording { requestStop() }
    }

    /// What the source had recorded when the running clip was asked to stop;
    /// nil while nothing is being stopped.
    private var recordedAtStop: TimeInterval?

    /// Every stop the author asks for goes through here.
    private func requestStop() {
        recordedAtStop = source.recordedDuration
        source.stopRecording()
        // Busy until the clip lands — `recordingFinished` puts it back.
        shutter.setLook(.busy, animated: true)
    }

    /// ⚠️ **WHAT THE SHUTTER WILL DO, SAID FOR WHAT IT WILL DO NOW.** The hint
    /// was fixed at "tap for a photo", which is wrong the moment the take holds
    /// a clip (a tap then records the next one hands-free); and recording
    /// needed a HOLD, which Switch Control, Voice Control and many VoiceOver
    /// users cannot make. "Record video" starts a hands-free recording the way
    /// a hold slid onto the padlock does; "Stop recording" ends one.
    private func refreshShutterAccessibility() {
        if isRecording {
            shutter.accessibilityHint = nil
            shutter.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Stop recording") { [weak self] _ in
                    guard let self, isRecording, !isFinishingClip else { return false }
                    shutterTapped()
                    return true
                }
            ]
        } else if take.isEmpty {
            shutter.accessibilityHint = "Takes a photo. Touch and hold to record a video."
            shutter.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Record video") { [weak self] _ in
                    self?.recordHandsFree() ?? false
                }
            ]
        } else {
            shutter.accessibilityHint = "Records the next clip hands-free."
            shutter.accessibilityCustomActions = []
        }
    }

    /// A recording that needs no finger on the shutter: locked from the start,
    /// after the timer if one is set. What a hold becomes once slid onto the
    /// padlock, or when a timer is set.
    @discardableResult
    private func recordHandsFree() -> Bool {
        guard authorizedToShoot, !isBusy, !isFinishingClip, !isRecording, countdownTask == nil else { return false }
        take.disarm()
        guard case .startRecording = shutterLogic.beginHold(takeIsFull: take.isFull) else {
            if take.isFull { say(take.limitReachedMessage) }
            return false
        }
        _ = shutterLogic.moveHold(by: CGPoint(x: -CaptureShutterLogic.lockDistance, y: 0))
        afterCountdown { [weak self] in self?.startRecording(locked: true) }
        refreshTakeControls(animated: true)
        return true
    }

    private var authorizedToShoot: Bool {
        if case .authorized = authorization { return true }
        return false
    }

    // MARK: - Countdown

    private func afterCountdown(_ body: @escaping () -> Void) {
        let seconds = settings.timer.rawValue
        guard seconds > 0 else {
            body()
            return
        }
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.tickCountdown(remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownLabel.alpha = 0
            self.countdownTask = nil
            body()
        }
        setChromeHidden(true)
    }

    private func tickCountdown(_ remaining: Int) {
        countdownLabel.text = "\(remaining)"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !reducesMotion() else {
            countdownLabel.alpha = 1
            return
        }
        countdownLabel.alpha = 0
        countdownLabel.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.countdownLabel.alpha = 1
            self.countdownLabel.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 0.65, options: [.curveEaseIn]) {
            self.countdownLabel.alpha = 0.15
            self.countdownLabel.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
    }

    private func cancelCountdown() {
        guard let task = countdownTask else { return }
        task.cancel()
        countdownTask = nil
        countdownLabel.alpha = 0
        // A countdown for a recording had already put the shutter's logic in
        // the phase the recording would have started in.
        if !isRecording { shutterLogic.recordingEnded() }
        setChromeHidden(false)
    }

    // MARK: - Photograph

    private func takePhoto() {
        guard !isBusy else { return }
        isBusy = true
        shutter.setLook(.busy, animated: true)
        flashScreen()
        let flash = source.hasFlash ? settings.flash : .off
        Task { [weak self] in
            guard let self else { return }
            do {
                let photo = try await source.capturePhoto(flash: flash, into: folder)
                photographed(photo)
            } catch {
                say("The photo could not be taken")
            }
            isBusy = false
            shutter.setLook(.idle, animated: true)
            setChromeHidden(false)
        }
    }

    /// The shutter's blink — a white flash over the preview, over in a quarter
    /// of a second. With motion reduced, a dimmer and shorter one.
    private func flashScreen() {
        flashView.alpha = reducesMotion() ? 0.4 : 0.85
        UIView.animate(withDuration: reducesMotion() ? 0.1 : 0.28, delay: 0.02, options: [.curveEaseOut]) {
            self.flashView.alpha = 0
        }
    }

    /// ⚠️ **HANDED OVER ONLY WHILE THE CAMERA IS STILL WHAT IS SHOWN.** If
    /// anything was pushed while the photograph was being written, the author
    /// has gone somewhere else; the editor would land on top of it. The
    /// photograph is dropped, file and all.
    private func photographed(_ photo: CapturedPhoto) {
        guard canHandOff else {
            folder.discard(photo.url)
            return
        }
        let item = captures.register(photo.url, kind: .photo)
        let edits = handOffEdits(uprightSize: photo.uprightSize)
        openEditor([item], edits: [item.id: edits])
    }

    /// What the capture arrives in the editor wearing: the look and the ratio
    /// chosen here, as the editor's own edits.
    ///
    /// ⚠️ **A SHAPE THAT CUTS ALSO ARRIVES SHOWN WHOLE (`fit`).** The editor
    /// lays a picture FILLING its full-screen canvas by default, and a square
    /// filled into a phone-shaped canvas is cut a second time, on screen: the
    /// author would open the editor on a picture framed nothing like the one
    /// they shot. Shown whole, the square is the square. `fit` is a screen's
    /// concern and reaches no pixel (`MediaEdits.fit`), so this changes what the
    /// author SEES, never what is published; they can still fill it there.
    func handOffEdits(uprightSize: CGSize) -> MediaEdits {
        var edits = MediaEdits()
        edits.filter = settings.filter
        edits.crop = settings.ratio.crop(forUpright: uprightSize)
        if !edits.crop.isUntouched { edits.fit = .fit }
        return edits
    }

    /// ⚠️ **AN EDIT THAT SAYS NOTHING IS NOT HANDED OVER** — `MediaEdits`'
    /// rule that absent means untouched, kept at the source rather than left
    /// for the editor to filter.
    private func openEditor(_ items: [MediaLibraryItem], edits: [String: MediaEdits]) {
        let edits = edits.filter { !$0.value.isUntouched }
        let editor = makeEditor(items, edits)
        debugLastHandOff = (items, edits)
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - Recording

    private func startRecording(locked: Bool) {
        guard !isRecording else { return }
        guard !take.isFull else {
            shutterLogic.recordingEnded()
            say(take.limitReachedMessage)
            return
        }
        let url = folder.newFile("clip", pathExtension: "mov")
        let torch = settings.flash.lightsTorch && source.hasFlash
        isRecording = true
        dropStitch()
        let promise = source.startRecording(to: url, torch: torch, limit: take.remaining)
        shutter.setLook(locked ? .locked : .holding, animated: true)
        setChromeHidden(true)
        ringLink.start()
        Task { [weak self] in
            do {
                var clip = try await promise.value
                if clip.duration <= 0 {
                    clip = CaptureClip(url: clip.url, duration: await CapturedMediaLibrary.duration(of: clip.url))
                }
                self?.recordingFinished(clip)
            } catch {
                self?.recordingFinished(nil)
                self?.folder.discard(url)
            }
        }
    }

    /// ⚠️ **A FAILED CLIP THAT WAS STOPPED BEFORE IT WAS A CLIP IS A SLIP, NOT
    /// AN ERROR.** A movie output asked to stop before its first sample still
    /// calls back — with an error, since there is nothing in the file — and the
    /// author, who only let go of the shutter at once, would read "could not be
    /// recorded". Stopped under `CaptureTake.shortest`, it goes as a slip goes:
    /// silently.
    private func recordingFinished(_ clip: CaptureClip?) {
        let wasSlip = clip == nil && (recordedAtStop ?? .infinity) < CaptureTake.shortest
        recordedAtStop = nil
        isRecording = false
        ringLink.stop()
        shutterLogic.recordingEnded()
        showLock(false)
        shutter.setLive(from: 0, to: 0)
        if let clip, !take.append(clip) {
            // Too short to be a clip: its file goes at once.
            folder.discard(clip.url)
        }
        shutter.setLook(.idle, animated: true)
        setChromeHidden(false)
        refreshTakeControls(animated: true)
        if clip == nil, !wasSlip { say("The clip could not be recorded") }
        if take.isFull { say(take.limitReachedMessage) }
    }

    private func ringTick() {
        guard isRecording else { return }
        let start = take.total / take.limit
        let now = min(take.remaining, source.recordedDuration)
        shutter.setLive(from: start, to: start + now / take.limit)
        timeLabel.text = Self.clock(take.total + now, of: take.limit)
    }

    static func clock(_ seconds: TimeInterval, of limit: TimeInterval) -> String {
        func spelled(_ value: TimeInterval) -> String {
            let whole = Int(value.rounded(.down))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return "\(spelled(seconds)) / \(spelled(limit))"
    }

    // MARK: - Undo, Next

    /// ⚠️ **NOT WHILE THE TAKE IS BEING STITCHED OR RECORDED.** Undo stayed
    /// live under Next's spinner: a double tap deleted the last clip's file
    /// while the stitcher was reading it, or after, so the editor opened on a
    /// video holding a clip the author had just thrown away.
    private func undoTapped() {
        guard !isBusy, !isRecording else { return }
        switch take.undo() {
        case .nothing:
            break
        case .armed:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .deleted(let clip):
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            // A one-clip take was handed over as this very clip.
            release(clip.url)
            dropStitch()
        }
        refreshTakeControls(animated: true)
    }

    private func nextTapped() {
        guard !take.isEmpty, !isRecording, !isBusy else { return }
        take.disarm()
        isBusy = true
        // A bar item carries no spinner: the shutter says the take is being
        // joined, with the look it wears while a photograph is written.
        shutter.setLook(.busy, animated: true)
        refreshTakeControls(animated: true)
        let clips = take.clips.map(\.url)
        Task { [weak self] in
            guard let self else { return }
            defer {
                isBusy = false
                shutter.setLook(.idle, animated: true)
                refreshTakeControls(animated: true)
            }
            do {
                let url: URL
                let duration: TimeInterval
                if let stitched, stitched.clips == clips {
                    url = stitched.url
                    duration = stitched.duration
                } else {
                    url = try await CaptureStitcher.stitch(clips, to: folder.newFile("take", pathExtension: "mov"))
                    duration = await CapturedMediaLibrary.duration(of: url)
                    dropStitch()
                    stitched = (clips, url, duration)
                }
                let size = await CapturedMediaLibrary.uprightVideoSize(at: url) ?? .zero
                // A take that changed while it was being joined is not the
                // take on screen; nothing is handed over for it.
                guard take.clips.map(\.url) == clips, canHandOff else { return }
                let item = captures.register(url, kind: .video(duration: duration))
                openEditor([item], edits: [item.id: handOffEdits(uprightSize: size)])
            } catch {
                say("The video could not be put together")
            }
        }
    }

    /// Files the camera is done with that a screen it handed them to still
    /// reads — deleted once nobody does (`sweepReleased`).
    private var awaitingRelease: Set<URL> = []

    /// Deletes a file the camera no longer needs — later, if a screen it was
    /// handed to still reads it. See `CapturedMediaLibrary.hold(_:by:)`.
    private func release(_ url: URL) {
        sweepReleased()
        if captures.isHeld(url) {
            awaitingRelease.insert(url)
        } else {
            folder.discard(url)
        }
    }

    /// Deletes the files that were waiting for their readers to go. Whatever is
    /// still held when the sheet closes goes with the folder.
    private func sweepReleased() {
        for url in awaitingRelease where !captures.isHeld(url) {
            folder.discard(url)
            awaitingRelease.remove(url)
        }
    }

    /// Forgets the joined take — and deletes its file.
    ///
    /// ⚠️ **THE FILE GOES WITH THE CACHE.** The first version only let go of
    /// the reference: every Next, back, record left another full-length copy of
    /// the take in the folder, for as long as the sheet was up — minutes of
    /// video, twice over, on a phone. The one file never deleted here is a
    /// one-clip take's, which is handed over as that clip itself and is still
    /// the take's.
    private func dropStitch() {
        if let stitched, !stitched.clips.contains(stitched.url) {
            release(stitched.url)
        }
        stitched = nil
        sweepReleased()
    }

    /// Lays out what the take allows: the library shortcut, undo and Next once
    /// it holds a clip, the ring's segments, the clock.
    ///
    /// ⚠️ **THE LIBRARY SHORTCUT STAYS BESIDE A TAKE.** It used to give way to
    /// undo, which had its place; undo has moved to the other side of the
    /// shutter, and the library is as much a way on from a take as from an
    /// empty camera: the picker is pushed over the camera, the take waits
    /// under it, and back comes back to it whole.
    private func refreshTakeControls(animated: Bool) {
        let recordingOrCounting = isRecording || countdownTask != nil
        let hasClips = !take.isEmpty
        // It pops when it arrives on an empty camera, not when it comes back
        // after each clip.
        setShown(libraryButton, !recordingOrCounting && !isBusy && makeLibraryPicker != nil, animated: animated, pops: !hasClips)
        setShown(undoButton, hasClips && !recordingOrCounting, animated: animated, pops: true)
        refreshNextItem(shown: hasClips && !recordingOrCounting, animated: animated)
        undoButton.isEnabled = !isBusy
        var undo = UIButton.Configuration.glass()
        if take.isArmedToUndo {
            undo = .prominentGlass()
            undo.baseBackgroundColor = .systemRed
        }
        undo.image = UIImage(systemName: "delete.left.fill")
        undo.baseForegroundColor = .white
        undoButton.configuration = undo
        undoButton.accessibilityLabel = take.isArmedToUndo ? "Delete last clip — tap again to confirm" : "Delete last clip"
        shutter.setSegments(take.segments, armedLast: take.isArmedToUndo)
        refreshShutterAccessibility()
        timeLabel.text = Self.clock(take.total, of: take.limit)
        setShown(timePill, hasClips || isRecording, animated: animated)
        // ⚠️ A SHEET WITH CLIPS IN IT DOES NOT SWIPE AWAY: the drag would throw
        // the take out with no question asked. Cancel asks.
        navigationController?.isModalInPresentation = hasClips || isRecording
        if !hasClips { hasSaidTheLookIsWhole = false }
        applyShapeLock()
    }

    /// Puts "Next" in the header — or takes it out — and enables it.
    ///
    /// ⚠️ **IN THE HEADER, AS THE PICKER'S AND THE EDITOR'S ARE — ASKED FOR**
    /// ("le bouton 'Next' sera affiché dans la toolbar du haut à droite"): a
    /// prominent (`.done`) item at the trailing edge, `[Cancel] ---- [Next]`.
    /// It arrives with the first clip, is disabled while the take is joined
    /// or a photograph written, and goes while a clip records or a countdown
    /// runs, with the rest of the chrome.
    ///
    /// ⚠️ **A FRESH ITEM EACH TIME IT ARRIVES, UNDER ONE IDENTIFIER**
    /// (`bar-item-wrapper-drift`): an item handed back to a bar is never one
    /// the bar already had. It is not rebuilt while it stays: only enabled or
    /// not.
    private func refreshNextItem(shown: Bool, animated: Bool) {
        if shown, nextItem == nil {
            let item = UIBarButtonItem(title: "Next", primaryAction: UIAction { [weak self] _ in self?.nextTapped() })
            item.style = .done
            item.identifier = Self.nextItemID
            nextItem = item
            navigationItem.setRightBarButtonItems([item], animated: animated)
        } else if !shown, nextItem != nil {
            nextItem = nil
            navigationItem.setRightBarButtonItems(nil, animated: animated)
        }
        nextItem?.isEnabled = !isBusy
    }

    /// Dims the shape's icon while the take has a clip — see `optionChosen`.
    ///
    /// ⚠️ **FOUND BY ITS LABEL, BECAUSE THE BAR HAS NO PER-ITEM STATE.**
    /// `IconSelectorBar` offers no "dimmed" for one item, and DesignSystem is
    /// not this change's to edit; its buttons carry their item's
    /// accessibility label, which is how this one is found. Re-applied after
    /// every re-dress, since `setItems` builds new buttons.
    private func applyShapeLock() {
        guard let button = ratioButton else { return }
        let locked = !take.isEmpty
        button.alpha = locked ? 0.35 : 1
        button.accessibilityValue = locked ? "Locked. Undo your clips to change the shape." : nil
    }

    private var ratioButton: UIButton? {
        func find(in view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityLabel == CaptureOption.ratio.title { return button }
            for subview in view.subviews {
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        return find(in: selector)
    }

    /// Everything but the shutter, the ring and the zoom steps back while a
    /// clip records or a countdown runs.
    private func setChromeHidden(_ hidden: Bool) {
        isChromeHidden = hidden
        cancelItem.isHidden = hidden
        handOverSelector(animated: true)
        if hidden { showBand(nil); selector.selectNothing(notify: false) }
        refreshTakeControls(animated: true)
    }

    private var isChromeHidden = false

    /// A hand-over the toolbar could not take yet, owed to the first layout
    /// pass once the screen is in a window.
    private var owesAHandover = false

    /// Puts the two strips in the stack's toolbar — the flash and the flip
    /// leading, the options trailing — or takes them out while a clip records
    /// or a countdown runs.
    ///
    /// ⚠️ **THE EDITOR'S BAR, SHARED RATHER THAN COPIED.** The leading strip is
    /// held at its own width and the selector takes the rest, floored at one
    /// bubble (`EditorSelectorLayout`), in the room the bar leaves once its
    /// margins, platters and group gap are charged (`ToolbarGeometry`, measured
    /// from the two platters through `BottomBarShare`).
    ///
    /// ⚠️ **FRESH ITEMS ON EVERY HAND-OVER, UNDER STABLE IDENTIFIERS**
    /// (`bar-item-wrapper-drift`): UIKit keeps the wrapper it builds around a
    /// REUSED item's view, and that wrapper does not follow the view's width —
    /// the editor lost its strip to a `•••` that way.
    ///
    /// ⚠️ **NEVER BEFORE THE SCREEN IS IN A WINDOW, AND THE WIDTHS BEFORE THE
    /// ITEMS.** UIKit decides once, at the hand-over, whether an item fits; a
    /// toolbar that has never been in a window answers the SCREEN's width. An
    /// early call is owed to `viewDidLayoutSubviews`, which also hands over
    /// again when the share has moved since the last hand-over.
    ///
    /// ⚠️ **THE TOOLBAR STAYS UP WHILE ITS ITEMS ARE AWAY.** Hiding the toolbar
    /// for a recording would lower the safe area the shutter rests on, and the
    /// shutter would drop under the author's thumb mid-clip.
    private func handOverSelector(animated: Bool) {
        guard view.window != nil, (navigationController?.toolbar.bounds.width ?? 0) > 0 else {
            owesAHandover = true
            return
        }
        guard !isHandingOver else { return }
        isHandingOver = true
        defer { isHandingOver = false }
        owesAHandover = false
        _ = shareTheBar()
        let offered = !isChromeHidden && notice == nil
        setToolbarItems(offered ? [
            Self.barItem(leadingBar, as: Self.leadingItemID),
            .fixedSpace(Spacing.sm),
            Self.barItem(selector, as: Self.optionsItemID),
            .flexibleSpace()
        ] : [], animated: animated)
        handedWidths = shareTheBar()
    }

    private static func barItem(_ view: UIView, as identifier: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: view)
        item.identifier = identifier
        return item
    }

    /// `setToolbarItems` lays the bar out, and this is called from that layout.
    private var isHandingOver = false

    /// The two widths the bar was last handed; a share that has moved since
    /// is handed over again.
    private var handedWidths: (leading: CGFloat, trailing: CGFloat)?

    private(set) var barGeometry = ToolbarGeometry.fallback

    private lazy var leadingWidth: NSLayoutConstraint =
        leadingBar.widthAnchor.constraint(equalToConstant: IconActionBar.height)
    private lazy var selectorWidth: NSLayoutConstraint =
        selector.widthAnchor.constraint(equalToConstant: IconSelectorBar.height)

    /// Holds the two strips to their share of the bar — the editor's
    /// `shareTheBarBetweenTheTwoStrips`, for this bar's two strips.
    @discardableResult
    private func shareTheBar() -> (leading: CGFloat, trailing: CGFloat)? {
        if let measured = BottomBarShare.measure(leading: leadingBar, trailing: selector) { barGeometry = measured }
        guard let toolbar = navigationController?.toolbar, toolbar.bounds.width > 0 else {
            leadingWidth.isActive = false
            selectorWidth.isActive = false
            return nil
        }
        let held = EditorSelectorLayout.widths(
            leadingWants: BottomBarShare.wantedWidth(of: leadingBar),
            available: barGeometry.available(in: toolbar.bounds.width),
            trailingFloor: selector.intrinsicContentSize.height
        )
        leadingWidth.constant = held.leading
        selectorWidth.constant = held.trailing
        leadingWidth.isActive = true
        selectorWidth.isActive = true
        leadingBar.frame.size.width = held.leading
        selector.frame.size.width = held.trailing
        return held
    }

    static let leadingItemID = "upload.camera.toolbar.leading"
    static let optionsItemID = "upload.camera.toolbar.options"

    private func showLock(_ shown: Bool) {
        lockView.setLocked(false)
        lockView.setProgress(0)
        setShown(lockView, shown, animated: true)
    }

    // MARK: - Zoom, focus, flip

    private func refreshLenses() {
        // The camera changed, or reported: its flash comes and goes with it.
        refreshLeadingBar()
        lensChips.setLenses(source.lenses, zoom: source.zoom)
        setShown(lensChips, openOption == nil && source.lenses.count > 1, animated: false)
    }

    private func pickLens(_ lens: CaptureLens) {
        source.setZoom(lens.factor, smoothly: true)
        lensChips.setZoom(source.zoom)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchBaseZoom = source.zoom
        case .changed:
            source.setZoom(pinchBaseZoom * pinch.scale, smoothly: false)
            lensChips.setZoom(source.zoom)
        default:
            break
        }
    }

    @objc private func previewTapped(_ tap: UITapGestureRecognizer) {
        previewTapped(at: tap.location(in: previewContainer))
    }

    private func previewTapped(at point: CGPoint) {
        // A tap on the preview closes an open band first — the finger was
        // reaching for the picture, not for focus.
        if openOption != nil {
            closeOption()
            return
        }
        let bounds = previewContainer.bounds
        guard bounds.width > 0 else { return }
        source.focus(at: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
        focusRing.center = point
        // ⚠️ REDUCE MOTION FADES; IT DOES NOT SCALE. Staged at identity, the
        // spring below has nothing to move.
        focusRing.transform = reducesMotion() ? .identity : CGAffineTransform(scaleX: 1.4, y: 1.4)
        debugFocusRingStart = focusRing.transform
        focusRing.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.focusRing.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 0.9, options: [.beginFromCurrentState]) {
            self.focusRing.alpha = 0
        }
    }

    /// The flip's turn: a quarter away and a quarter back, about the vertical
    /// axis, in keyframes so every step is `turn(_:width:)` — never something
    /// Core Animation interpolated between two of them.
    private func turnThePictures() {
        let width = flipHost.bounds.width
        guard width > 0, !isTurning else { return }
        isTurning = true
        let steps = 8
        func half(_ duration: TimeInterval, angle: @escaping (Double) -> CGFloat, then: @escaping () -> Void) {
            UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.allowUserInteraction, .calculationModeLinear]) {
                for step in 1...steps {
                    let progress = Double(step) / Double(steps)
                    UIView.addKeyframe(withRelativeStartTime: progress - 1 / Double(steps), relativeDuration: 1 / Double(steps)) {
                        self.flipHost.transform3D = Self.turn(angle(progress), width: width)
                    }
                }
            } completion: { _ in then() }
        }
        // Away, easing in; back, easing out, from the other side.
        half(0.2, angle: { .pi / 2 * $0 * $0 }) {
            self.flipHost.transform3D = Self.turn(-.pi / 2, width: width)
            half(0.22, angle: { -.pi / 2 * (1 - $0) * (1 - $0) }) {
                self.flipHost.transform3D = CATransform3DIdentity
                self.isTurning = false
            }
        }
    }

    private var isTurning = false

    /// How far the eye is from the turning pictures, in points: the turn's
    /// perspective.
    static let turnDistance: CGFloat = 900

    /// How much of the zone's height the turning pictures' nearer edge may
    /// take at most.
    static let turnMargin: CGFloat = 0.96

    /// The pictures turned by `angle` about their vertical axis, seen with
    /// perspective — and shrunk just enough to stay inside the zone.
    ///
    /// ⚠️ **SHRUNK, OR THE NEAR CORNERS ARE CUT SQUARE — MEASURED.** A turn in
    /// perspective makes the nearer edge TALLER than the zone (by a quarter
    /// at 60° here), and the zone clips it: the recording showed the far
    /// corners rounded and the near ones cut flat by the zone's top and
    /// bottom. The scale is the one that holds the near edge at
    /// `turnMargin` of the zone's height, whatever the angle.
    static func turn(_ angle: CGFloat, width: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / turnDistance
        // The near edge comes forward by half the width times sin(angle),
        // which enlarges it by 1 / (1 − scale · lift).
        let lift = width / 2 * abs(sin(angle)) / turnDistance
        let scale = turnMargin / (1 + turnMargin * lift)
        transform = CATransform3DRotate(transform, angle, 0, 1, 0)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        flip()
    }

    /// ⚠️ **A FLIP WHILE RECORDING IS REFUSED**, not queued: the movie output
    /// cannot change inputs under a running file, and a clip is where a flip
    /// belongs anyway — between two of them.
    ///
    /// ⚠️ **TURNED BY HAND, NOT WITH `UIView.transition(.transitionFlipFromLeft)`
    /// — MEASURED.** That transition was given a view with rounded, clipping
    /// corners, and a recording of it still showed a card with SQUARE corners
    /// turning: the transition draws the view without its corner mask. The
    /// pictures' host is turned instead — a quarter away, then a quarter back
    /// in with the other camera — and its own mask turns with it.
    private func flip() {
        guard !isRecording, !isBusy else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if !reducesMotion() { turnThePictures() }
        Task { [weak self] in
            guard let self else { return }
            await source.flip()
            refreshLenses()
        }
    }

    // MARK: - Library shortcut

    /// The newest picture in the library, as the shortcut's face.
    ///
    /// ⚠️ **THE SHORTCUT IS ALWAYS OFFERED; ONLY ITS FACE WAITS FOR ACCESS.**
    /// It used to appear only once Photos access was granted and a thumbnail
    /// had loaded, so a person who had never been asked had no way from the
    /// camera to their library at all. It now stands with a neutral glyph, and
    /// the picker it opens asks for access itself — where asking is expected.
    /// The camera still never asks: reading `access` asks nothing, and the
    /// thumbnail is only fetched where access is already granted.
    ///
    /// ⚠️ **ONE PICTURE, ASKED FOR ONCE.** It used to enumerate the picker's
    /// whole Recents album on the main actor for this — see
    /// `CaptureLibraryFace`.
    private func loadLibraryShortcut() {
        guard let libraryFace, makeLibraryPicker != nil else { return }
        Task { [weak self] in
            guard let picture = await libraryFace() else { return }
            guard let self else { return }
            libraryButton.imageView?.contentMode = .scaleAspectFill
            libraryButton.backgroundColor = nil
            libraryButton.setImage(picture, for: .normal)
            hasLibraryThumbnail = true
        }
    }

    private(set) var hasLibraryThumbnail = false

    /// ⚠️ **NOT WHILE A CAPTURE IS IN FLIGHT.** A photograph still being
    /// written when the shortcut was tapped finished on top of the picker, and
    /// pushed the capture's editor over it.
    private func openLibrary() {
        guard !isBusy, !isRecording, countdownTask == nil, let picker = makeLibraryPicker?() else { return }
        navigationController?.pushViewController(picker, animated: true)
    }

    // MARK: - Notices

    private func showNotice(_ kind: CaptureAccessNoticeView.Kind) {
        guard notice == nil else { return }
        let notice = CaptureAccessNoticeView(kind)
        notice.onOpenSettings = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        notice.pin(to: previewContainer)
        self.notice = notice
        shutter.isUserInteractionEnabled = false
        shutter.alpha = 0.35
        handOverSelector(animated: false)
        lensChips.isHidden = true
    }

    private func say(_ text: String) {
        toastLabel.text = text
        debugLastToast = text
        debugToasts.append(text)
        // ⚠️ REDUCE MOTION FADES; IT DOES NOT SCALE.
        toast.transform = reducesMotion() ? .identity : CGAffineTransform(scaleX: 0.9, y: 0.9)
        debugToastStart = toast.transform
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.toast.alpha = 1
            self.toast.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 2, options: [.beginFromCurrentState]) {
            self.toast.alpha = 0
        }
    }

    // MARK: - Appearing and leaving

    /// ⚠️ **ELEMENTS ARRIVE WITH `BandPop` AND LEAVE QUICKER — AND ARE LEFT
    /// ALONE WHEN ALREADY WHERE THEY ARE ASKED TO BE.** Model values are end
    /// values: re-running an arrival on a view that is already shown would
    /// flash it from nothing.
    ///
    /// ⚠️ **`pops` IS FOR WHAT ARRIVES AS NEW** — undo once a clip lands, the
    /// library's face — never for chrome coming back after a clip:
    /// a selector that popped every time a recording ended would be noise. And
    /// nothing pops while recording, when the microphone is open.
    private func setShown(
        _ element: UIView, _ shown: Bool, animated: Bool, pops: Bool = false, delay: TimeInterval = 0
    ) {
        let isShown = !element.isHidden && element.alpha > 0.01 && element.isUserInteractionEnabled
        guard shown != isShown || (shown && element.isHidden) else { return }
        element.isUserInteractionEnabled = shown
        guard animated, !reducesMotion(), element.window != nil else {
            element.isHidden = !shown
            element.alpha = shown ? 1 : 0
            element.transform = .identity
            return
        }
        if shown {
            if pops, !isRecording { UISound.pop.play(after: delay) }
            element.isHidden = false
            element.alpha = 0
            element.transform = BandPop.collapsedTransform
            UIView.animate(
                withDuration: BandPop.duration, delay: delay, usingSpringWithDamping: BandPop.dampingRatio,
                initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                element.alpha = 1
                element.transform = .identity
            }
        } else {
            UIView.animate(
                withDuration: BandPop.departure, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
            ) {
                element.alpha = 0
                element.transform = BandPop.collapsedTransform
            } completion: { finished in
                guard finished, !element.isUserInteractionEnabled else { return }
                element.isHidden = true
                element.transform = .identity
            }
        }
    }

    // MARK: - Debug

    private(set) var debugPopIns = 0
    private(set) var debugCardRefreshes = 0
    private(set) var debugLastToast: String?
    private(set) var debugToasts: [String] = []
    /// What the focus ring and the toast were staged at before they spring in.
    private(set) var debugFocusRingStart: CGAffineTransform?
    private(set) var debugToastStart: CGAffineTransform?
    func debugTapPreview(at point: CGPoint) { previewTapped(at: point) }
    var debugShapeIsDimmed: Bool { (ratioButton?.alpha ?? 1) < 0.5 }
    private(set) var debugLastHandOff: ([MediaLibraryItem], [String: MediaEdits])?
    var debugSelector: IconSelectorBar { selector }
    var debugBand: MediaEditorBandView { band }
    var debugLeadingBar: IconActionBar { leadingBar }
    func debugPickFlash(_ mode: CaptureFlashMode) { setFlash(mode) }
    var debugBarShare: (leading: CGFloat, trailing: CGFloat, available: CGFloat, leadingWants: CGFloat, floor: CGFloat)? {
        guard let toolbar = navigationController?.toolbar, toolbar.bounds.width > 0 else { return nil }
        return (
            leadingBar.frame.width, selector.frame.width, barGeometry.available(in: toolbar.bounds.width),
            BottomBarShare.wantedWidth(of: leadingBar), selector.intrinsicContentSize.height
        )
    }
    var debugHeldWidths: (leading: CGFloat, trailing: CGFloat) { (leadingWidth.constant, selectorWidth.constant) }
    var debugTimerRow: CaptureChoiceRowView<CaptureTimer> { timerRow }
    var debugRatioRow: CaptureChoiceRowView<CaptureRatio> { ratioRow }
    var debugFilterRow: MediaFilterRowView { filterRow }
    var debugLensChips: CaptureLensChipsView { lensChips }
    var debugLiveView: CaptureLiveView { liveView }
    /// The view a flip turns.
    var debugFlippingView: UIView? { flipHost }
    var debugGridIsShowing: Bool { !gridView.isHidden && gridView.alpha > 0 }
    var debugUndoIsShowing: Bool { !undoButton.isHidden && undoButton.isUserInteractionEnabled }
    var debugUndoIsEnabled: Bool { undoButton.isEnabled }
    var debugNextIsShowing: Bool { debugNextItem != nil }
    /// The header's "Next", as the bar holds it.
    var debugNextItem: UIBarButtonItem? {
        navigationItem.rightBarButtonItems?.first { $0.identifier == Self.nextItemID }
    }
    var debugUndoFrame: CGRect { undoButton.frame }
    var debugLibraryFrame: CGRect { libraryButton.frame }
    var debugLibraryIsShowing: Bool { !libraryButton.isHidden && libraryButton.isUserInteractionEnabled }
    var debugLockIsShowing: Bool { lockView.isUserInteractionEnabled || (!lockView.isHidden && lockView.alpha > 0) }
    var debugWindow: CGRect { gridView.frame }
    var debugPreviewBounds: CGRect { previewContainer.bounds }
    var debugPreviewFrame: CGRect { previewContainer.frame }
    var debugPreviewCorners: (top: CGFloat, bottom: CGFloat) {
        (previewContainer.effectiveRadius(corner: .topLeft), previewContainer.effectiveRadius(corner: .bottomLeft))
    }
    var debugNoticeIsShowing: Bool { notice != nil }
    var debugNotice: CaptureAccessNoticeView? { notice }
    func debugTapUndo() { undoTapped() }
    func debugTapNext() { nextTapped() }
    func debugTapShutter() { shutterTapped() }
    func debugBeginHold() { holdBegan() }
    func debugMoveHold(_ translation: CGPoint) { holdMoved(translation) }
    func debugEndHold() { holdEnded() }
    func debugTapLibrary() { openLibrary() }
    func debugTapCancel() { cancelTapped() }
    var debugTimeText: String? { timeLabel.text }
    /// The accessibility labels the selector's buttons carry, in order.
    var debugSelectorLabels: [String] {
        func buttons(in view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        return buttons(in: selector).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            .compactMap(\.accessibilityLabel)
    }
    func debugFlip() { flip() }
}

/// Holds the ring's display link weakly, the `RevealLinkProxy` shape — a link
/// holds its target strongly and the run loop holds the link.
@MainActor
final class CaptureLinkProxy: NSObject {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// ⚠️ **STOPPED THE MOMENT RECORDING ENDS** — `RevealDriver`'s rule: a link
    /// left running is a callback at screen rate for the life of the screen.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { onTick?() }
}

private extension UIFont {
    var rounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
