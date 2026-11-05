// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2134).
#if DEBUG
import DesignSystem
import PencilKit
import UIKit

// MARK: - The app's windows

/// The dashboard's own windows — its sheet, badges and overlays — which the
/// tools never inspect, outline, slow down or screenshot.
@MainActor
protocol DebugOverlayWindow: UIWindow {}

@MainActor
enum DebugWindows {
    /// The app's own windows: every visible window but the dashboard's.
    static var app: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && !($0 is DebugOverlayWindow) }
    }

    static var main: UIWindow? { app.first(where: \.isKeyWindow) ?? app.first }
}

// MARK: - Bug report

public extension DebugDashboard {
    /// What the app adds to a bug report: named texts (context, failed
    /// calls…), gathered when the report is sent.
    static var reportAttachments: () -> [(name: String, text: String)] = { [] }

    static var bugReportEntry: Entry {
        Entry(title: "Report a Bug", symbol: "ladybug") { DebugReportViewController() }
    }

    /// Takes the screenshot of the app's main window: called as the
    /// dashboard opens, before its sheet is drawn over it.
    internal static func captureScreen() {
        guard let window = DebugWindows.main else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        DebugReport.screenshot = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

@MainActor
enum DebugReport {
    /// The screen under the dashboard as it last opened.
    static var screenshot: UIImage?
}

/// The screenshot to annotate (PencilKit: a red pen to circle, a black
/// marker to hide a face or a name), then a zip — the picture, the context, the last logs,
/// the last measured interactions and hangs, the app's attachments — to the
/// share sheet; or the issue draft copied.
final class DebugReportViewController: UIViewController {
    private let canvas = PKCanvasView()
    private let imageView = UIImageView()

    private static let circle = PKInkingTool(.pen, color: .systemRed, width: 6)
    private static let blackOut = PKInkingTool(.marker, color: .black, width: 40)

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Report a Bug"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        imageView.image = DebugReport.screenshot
        imageView.contentMode = .scaleAspectFit
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = Self.circle
        [imageView, canvas].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        let ratio = DebugReport.screenshot.map { $0.size.height / max(1, $0.size.width) } ?? 2
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -8),
            imageView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: ratio),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -32),
            canvas.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: imageView.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
        ])
        let width = imageView.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        width.priority = .defaultHigh
        width.isActive = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Send", primaryAction: UIAction { [weak self] _ in self?.send() }),
            UIBarButtonItem(image: UIImage(systemName: "pencil.tip.crop.circle"), menu: penMenu()),
        ]
    }

    /// No tool picker: it would cover the screenshot, and its own tool
    /// replaces the canvas's. Two pens and a clear are all a report needs.
    private func penMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Circle (Red Pen)", image: UIImage(systemName: "pencil.tip")) { [weak self] _ in
                self?.canvas.tool = Self.circle
            },
            UIAction(title: "Hide (Black Marker)", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.canvas.tool = Self.blackOut
            },
            UIAction(title: "Copy Issue Draft", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copyDraft()
            },
            UIAction(title: "Clear Drawing", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.canvas.drawing = PKDrawing()
            },
        ])
    }

    private var annotated: UIImage? {
        guard let screenshot = DebugReport.screenshot else { return nil }
        let drawing = canvas.drawing
        let scale = screenshot.size.width / max(1, canvas.bounds.width)
        return UIGraphicsImageRenderer(size: screenshot.size).image { _ in
            screenshot.draw(at: .zero)
            drawing.image(from: canvas.bounds, scale: UIScreen.main.scale)
                .draw(in: CGRect(origin: .zero, size: CGSize(width: canvas.bounds.width * scale, height: canvas.bounds.height * scale)))
        }
    }

    private func texts() -> [(name: String, text: String)] {
        let records = InteractionLatency.records.suffix(50).map { record in
            "\(Int(record.latencyMs.rounded())) ms \(record.response) ← \(record.input.kind) \(record.input.target)"
                + (record.context.map { " [\($0)]" } ?? "")
        }
        let latency = records.isEmpty && !InteractionLatency.isActive ? ["(the latency tool was off)"] : records
        let hangs = InteractionLatency.hangs.suffix(20).map { "\($0.at.ISO8601Format()) \(Int($0.ms.rounded())) ms \($0.during)" }
        let console = ConsoleCapture.shared.captured.suffix(500).map { "\($0.date.ISO8601Format()) \($0.text)" }
        return DebugDashboard.reportAttachments() + [
            ("latency.txt", (latency + ["", "hangs:"] + hangs).joined(separator: "\n")),
            ("console.txt", console.isEmpty ? "(console capture was off)" : console.joined(separator: "\n")),
        ]
    }

    private func copyDraft() {
        let context = DebugDashboard.reportAttachments().first { $0.name.hasPrefix("context") }?.text ?? ""
        UIPasteboard.general.string = """
        ## What happened

        ## What I expected

        ## Context
        \(context)

        _Screenshot and logs: attach the zip from the debug dashboard's Report a Bug._
        """
    }

    private func send() {
        let image = annotated?.jpegData(compressionQuality: 0.8)
        let texts = texts()
        Task { [weak self] in
            let zip = await Task.detached(priority: .userInitiated) { () -> URL? in
                Self.makeZip(image: image, texts: texts)
            }.value
            guard self != nil, let zip else { return }
            DebugDashboard.share([zip])
        }
    }

    /// The files in a folder, zipped by the file coordinator (`.forUploading`
    /// zips a folder), every text masked.
    nonisolated private static func makeZip(image: Data?, texts: [(name: String, text: String)]) -> URL? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("bug-report-\(Int(Date().timeIntervalSince1970))")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let image { try? image.write(to: folder.appendingPathComponent("screenshot.jpg")) }
        for (name, text) in texts {
            try? DebugRedaction.redact(text).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipped in
            let destination = manager.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            try? manager.removeItem(at: destination)
            if (try? manager.copyItem(at: zipped, to: destination)) != nil { result = destination }
        }
        return result
    }
}

// MARK: - The view inspector

/// Tap a view to read it: class, frame, controller, accessibility, the
/// constraints on it; walk up to its parents. While on, an overlay takes
/// every touch — the app does not answer until it is off. Costly by nature:
/// registered as a tool, and records taken meanwhile are labelled.
@MainActor
public final class DebugViewInspector {
    public static let shared = DebugViewInspector()

    private var window: InspectorWindow?

    public var isOn: Bool { window.map { !$0.isHidden } ?? false }

    public func setOn(_ on: Bool) {
        if on {
            guard let scene = DebugWindows.main?.windowScene else { return }
            let overlay = window ?? InspectorWindow(windowScene: scene)
            window = overlay
            overlay.isHidden = false
        } else {
            window?.isHidden = true
            window?.clear()
        }
        DebugTools.didChange()
    }

    private final class InspectorWindow: AppWindow, DebugOverlayWindow {
        private let highlight = UIView()
        private let panel = UILabel()
        private var selected: UIView?

        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert - 2
            backgroundColor = .clear
            highlight.layer.borderColor = UIColor.systemRed.cgColor
            highlight.layer.borderWidth = 2
            highlight.isUserInteractionEnabled = false
            panel.numberOfLines = 0
            panel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            panel.textColor = .white
            panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            panel.layer.cornerRadius = 8
            panel.layer.masksToBounds = true
            panel.isUserInteractionEnabled = true
            addSubview(highlight)
            addSubview(panel)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            addGestureRecognizer(tap)
            let parent = UITapGestureRecognizer(target: self, action: #selector(parentTapped))
            panel.addGestureRecognizer(parent)
            panel.text = " Tap a view to inspect it; tap this panel for its parent.\n Shake to open the dashboard and turn the inspector off."
            layoutPanel(near: CGPoint(x: 0, y: 0))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func clear() {
            selected = nil
            highlight.frame = .zero
        }

        @objc private func tapped(_ tap: UITapGestureRecognizer) {
            guard let app = DebugWindows.main else { return }
            select(Self.deepest(in: app, at: tap.location(in: app)), near: tap.location(in: self))
        }

        /// The frontmost visible view under `point`, labels and images
        /// included — `hitTest` skips every view that takes no touch.
        private static func deepest(in view: UIView, at point: CGPoint) -> UIView? {
            guard !view.isHidden, view.alpha > 0.01, view.point(inside: point, with: nil) else { return nil }
            for subview in view.subviews.reversed() {
                if let found = deepest(in: subview, at: view.convert(point, to: subview)) { return found }
            }
            return view
        }

        @objc private func parentTapped() {
            guard let parent = selected?.superview else { return }
            select(parent, near: panel.center)
        }

        private func select(_ view: UIView?, near point: CGPoint) {
            guard let view else { return }
            selected = view
            highlight.frame = view.convert(view.bounds, to: self)
            panel.text = Self.describe(view)
            layoutPanel(near: point)
        }

        private func layoutPanel(near point: CGPoint) {
            let width = bounds.width - 24
            let size = panel.sizeThatFits(CGSize(width: width, height: 400))
            let y = point.y > bounds.midY ? safeAreaInsets.top + 8 : bounds.height - safeAreaInsets.bottom - size.height - 24
            panel.frame = CGRect(x: 12, y: y, width: width, height: size.height + 16)
        }

        private static func describe(_ view: UIView) -> String {
            var responder: UIResponder? = view
            var controller = "—"
            while let next = responder?.next {
                if let found = next as? UIViewController {
                    controller = String(describing: type(of: found))
                    break
                }
                responder = next
            }
            let frame = view.frame
            let constraints = view.constraints.prefix(6).map { "  \($0)" }
            return [
                " \(type(of: view))",
                " frame (\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width))×\(Int(frame.height)))",
                " controller \(controller)",
                " a11y \(view.accessibilityLabel ?? "—") · \(view.isAccessibilityElement ? "element" : "container")",
                " hidden \(view.isHidden) · alpha \(String(format: "%.2f", view.alpha)) · subviews \(view.subviews.count)",
                " constraints \(view.constraints.count)" + (constraints.isEmpty ? "" : ":\n" + constraints.joined(separator: "\n")),
                " ↑ tap for the parent",
            ].joined(separator: "\n")
        }
    }
}

// MARK: - Touches and layout bounds

/// A dot under every finger, for screen recordings. A recognizer on the
/// app's main window that never recognizes nor delays a touch; the dots in
/// an overlay that takes none.
@MainActor
public final class DebugTouchVisualizer {
    public static let shared = DebugTouchVisualizer()

    private var recognizer: TouchSpy?
    private var overlay: DotsWindow?

    public var isOn: Bool { recognizer != nil }

    public func setOn(_ on: Bool) {
        if on, recognizer == nil, let main = DebugWindows.main, let scene = main.windowScene {
            let dots = overlay ?? DotsWindow(windowScene: scene)
            overlay = dots
            dots.isHidden = false
            let spy = TouchSpy { [weak dots] touches in dots?.show(touches) }
            main.addGestureRecognizer(spy)
            recognizer = spy
        } else if !on, let spy = recognizer {
            spy.view?.removeGestureRecognizer(spy)
            recognizer = nil
            overlay?.isHidden = true
        }
        DebugTools.didChange()
    }

    private final class TouchSpy: UIGestureRecognizer {
        private let report: (Set<UITouch>) -> Void
        private var live: Set<UITouch> = []

        init(report: @escaping (Set<UITouch>) -> Void) {
            self.report = report
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            live.formUnion(touches)
            report(live)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { report(live) }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            live.subtract(touches)
            report(live)
            if live.isEmpty { state = .failed }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            live.subtract(touches)
            report(live)
            if live.isEmpty { state = .failed }
        }

        override func reset() {
            live.removeAll()
            report(live)
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        // A scroll or a pan that recognizes must not end the dots.
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }

    private final class DotsWindow: AppWindow, DebugOverlayWindow {
        private var dots: [UIView] = []

        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert + 7
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func show(_ touches: Set<UITouch>) {
            while dots.count < touches.count {
                let dot = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
                dot.layer.cornerRadius = 22
                dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
                dot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
                dot.layer.borderWidth = 2
                addSubview(dot)
                dots.append(dot)
            }
            for (index, dot) in dots.enumerated() {
                if index < touches.count {
                    let touch = Array(touches)[index]
                    dot.center = touch.location(in: self)
                    dot.isHidden = false
                } else {
                    dot.isHidden = true
                }
            }
        }
    }
}

/// The outline of every view on screen, redrawn once a second while on.
@MainActor
public final class DebugLayoutBounds {
    public static let shared = DebugLayoutBounds()

    private var window: OutlineWindow?
    private var timer: Timer?

    public var isOn: Bool { timer != nil }

    public func setOn(_ on: Bool) {
        if on, timer == nil, let scene = DebugWindows.main?.windowScene {
            let outline = window ?? OutlineWindow(windowScene: scene)
            window = outline
            outline.isHidden = false
            outline.redraw()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DebugLayoutBounds.shared.window?.redraw() }
            }
        } else if !on {
            timer?.invalidate()
            timer = nil
            window?.isHidden = true
        }
        DebugTools.didChange()
    }

    private final class OutlineWindow: AppWindow, DebugOverlayWindow {
        private let shape = CAShapeLayer()

        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert - 3
            isUserInteractionEnabled = false
            backgroundColor = .clear
            shape.strokeColor = UIColor.systemRed.withAlphaComponent(0.6).cgColor
            shape.fillColor = nil
            shape.lineWidth = 0.5
            layer.addSublayer(shape)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func redraw() {
            guard let app = DebugWindows.main else { return }
            let path = CGMutablePath()
            var stack: [UIView] = [app]
            var count = 0
            while let view = stack.popLast(), count < 3000 {
                count += 1
                guard !view.isHidden, view.alpha > 0.01 else { continue }
                path.addRect(view.convert(view.bounds, to: nil))
                stack.append(contentsOf: view.subviews)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            shape.path = path
            CATransaction.commit()
        }
    }
}

// MARK: - The interface section

public extension DebugDashboard {
    /// Interface tools and quick switches (#2134). The switches are trait
    /// overrides on the app's windows, not system settings; records taken
    /// under them are labelled by the costly tools that run beside them.
    static var interfaceEntry: Entry {
        DebugTools.register(DebugTool(
            id: "view-inspector", title: "View inspector",
            detail: "Tap a view to read it; the app does not answer meanwhile",
            cost: "every touch, while on", costMs: 0,
            isOn: { DebugViewInspector.shared.isOn }, apply: { DebugViewInspector.shared.setOn($0) }
        ))
        DebugTools.register(DebugTool(
            id: "touches", title: "Show touches", detail: "A dot under every finger, for recordings",
            cost: "a recognizer on every touch", costMs: 0.1,
            isOn: { DebugTouchVisualizer.shared.isOn }, apply: { DebugTouchVisualizer.shared.setOn($0) }
        ))
        DebugTools.register(DebugTool(
            id: "layout-bounds", title: "Layout bounds", detail: "Every view's outline, redrawn once a second",
            cost: "a walk of the whole hierarchy once a second", costMs: 2,
            isOn: { DebugLayoutBounds.shared.isOn }, apply: { DebugLayoutBounds.shared.setOn($0) }
        ))
        return Entry(title: "Interface", symbol: "rectangle.dashed") {
            DebugListViewController(title: "Interface") { interfaceSections() }
        }
    }

    /// The quick switches that are on, for the latency records' label:
    /// slow animations alone multiply every number by ten.
    static var switchesOn: [String] {
        [(slowAnimations, "slow animations"), (largestText, "largest text"), (forcedDark, "forced dark"),
         (rightToLeft, "right to left")].filter(\.0).map(\.1)
    }

    private static var slowAnimations = false
    private static var largestText = false
    private static var forcedDark = false
    private static var rightToLeft = false

    private static func interfaceSections() -> [DebugSection] {
        let tools = ["view-inspector", "touches", "layout-bounds"].compactMap(DebugTools.tool)
        return [
            DebugSection(title: "Tools", footer: "Costly: on only while you need them; off at the next launch.",
                         rows: tools.map { .toggle(.tool($0)) }),
            DebugSection(title: "Quick switches", footer: "Overrides on the app's windows, not iOS settings. Off at the next launch.", rows: [
                .toggle(DebugToggle(title: "Slow animations", detail: "The app's layers at a tenth of their speed",
                                    isOn: { slowAnimations }, set: { on in
                                        slowAnimations = on
                                        DebugWindows.app.forEach { $0.layer.speed = on ? 0.1 : 1 }
                                    })),
                .toggle(DebugToggle(title: "Largest text size", detail: "accessibility XXXL, capped by the app's ceiling",
                                    isOn: { largestText }, set: { on in
                                        largestText = on
                                        DebugWindows.app.forEach {
                                            if on {
                                                $0.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                                            } else {
                                                $0.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                                            }
                                        }
                                    })),
                .toggle(DebugToggle(title: "Dark", detail: "Off: back to Settings › Display's appearance",
                                    isOn: { forcedDark }, set: { on in
                                        forcedDark = on
                                        if on {
                                            DebugWindows.app.forEach { $0.overrideUserInterfaceStyle = .dark }
                                        } else {
                                            AppearancePreference.apply(to: DebugWindows.app)
                                        }
                                    })),
                .toggle(DebugToggle(title: "Right to left", detail: "A layout-direction override: a relaunch in an RTL language is the full check",
                                    isOn: { rightToLeft }, set: { on in
                                        rightToLeft = on
                                        DebugWindows.app.forEach {
                                            if on {
                                                $0.traitOverrides.layoutDirection = .rightToLeft
                                            } else {
                                                $0.traitOverrides.remove(UITraitLayoutDirection.self)
                                            }
                                        }
                                    })),
                .toggle(DebugToggle(title: "Reduce motion (the app's)", detail: "Settings › Display's switch: it persists",
                                    isOn: { MotionPreference.appReducesMotion },
                                    set: { MotionPreference.appReducesMotion = $0 })),
            ]),
        ]
    }
}
#endif
