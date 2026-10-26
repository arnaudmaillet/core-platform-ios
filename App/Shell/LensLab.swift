#if DEBUG
import DesignSystem
import ObjectiveC
import UIKit

/// `-lens-lab`: a bench for the selector's Liquid Glass lens (#1748). A real
/// `UITabBarController` with native tabs, our `PagedTabBar` in its bottom
/// accessory exactly as the app hosts it, over a background chosen with
/// `-lens-lab-bg white|black|red|stripes|grid|photo|text`, so the native tab
/// bar's lens and ours can be filmed side by side under the same light.
///
/// `-lens-lab-dump`: while the native lens is lifted, walks its view and
/// layer tree once and prints every class, frame, filter (name and inputs)
/// and readable property of the private layers — the native lens's real
/// parameters, read rather than guessed.
@MainActor
enum LensLab {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-lens-lab") }

    static func makeRoot() -> UIViewController { LensLabTabBarController() }
}

@MainActor
private final class LensLabTabBarController: UITabBarController {
    private var accessory: SelectorAccessory?
    private var dumpLink: CADisplayLink?
    private var dumped = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        // A black page is a dark-mode page: the bars follow it, as in the app.
        if UserDefaults.standard.string(forKey: "lens-lab-bg") == "black" { overrideUserInterfaceStyle = .dark }
        let items: [(String, String)] = [("Explore", "paperplane"), ("For You", "play.square"),
                                         ("Messages", "bubble.left.and.bubble.right"), ("Profile", "person.crop.circle")]
        viewControllers = items.map { title, symbol in
            let page = LensLabPage()
            page.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
            return page
        }
        selectedIndex = 2
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard accessory == nil else { return }
        let bar = PagedTabBar(titles: ["Chats", "Requests", "Suggestions"], style: .navigationTitle)
        bar.badgeTint = Palette.counter
        bar.badgeGradient = Palette.accentGradient
        bar.setBadge(22, at: 0)
        bar.setBadge(10, at: 1)
        let accessory = SelectorAccessory(strip: bar)
        accessory.install(into: self, owner: selectedViewController)
        self.accessory = accessory
        if ProcessInfo.processInfo.arguments.contains("-lens-lab-dump") {
            let link = CADisplayLink(target: self, selector: #selector(probeNativeLens))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15)
            link.add(to: .main, forMode: .common)
            dumpLink = link
        }
    }

    /// Finds the native lens; while it reports lifted, dumps its tree once per
    /// lifted state seen (rest dumped once too, for comparison).
    @objc private func probeNativeLens() {
        guard let lens = Self.find(in: tabBar, where: { String(describing: type(of: $0)).contains("LiquidLens") }) else { return }
        let lifted = (lens.value(forKey: "lifted") as? Bool) ?? false
        let key = lifted ? "lifted" : "rest"
        guard !dumped.contains(key) else { return }
        dumped.insert(key)
        print("[lenslab] ===== native lens \(key) frame=\(lens.convert(lens.bounds, to: nil))")
        LensDumper.dumpView(lens, depth: 0)
        if lifted, let platter = lens.superview {
            print("[lenslab] ----- platter")
            LensDumper.dumpView(platter, depth: 0, maxDepth: 1)
        }
    }

    private static func find(in view: UIView, where match: (UIView) -> Bool) -> UIView? {
        if match(view) { return view }
        for child in view.subviews {
            if let found = find(in: child, where: match) { return found }
        }
        return nil
    }
}

@MainActor
private final class LensLabPage: UIViewController {
    override func loadView() {
        let mode = UserDefaults.standard.string(forKey: "lens-lab-bg") ?? "white"
        view = LensLabBackground(mode: mode)
    }

    /// A native `UISegmentedControl` with our selector's segments, on the page,
    /// so its lens can be held and compared with ours (owner, 2026-10-26).
    override func viewDidLoad() {
        super.viewDidLoad()
        let native = UISegmentedControl(items: ["Chats", "Requests", "Suggestions"])
        native.selectedSegmentIndex = 0
        native.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(native)
        // Ours, on the page under it, with its own glass (not in the accessory).
        let ours = PagedTabBar(titles: ["Chats", "Requests", "Suggestions"], style: .segmentedControl)
        // Drawn as the native control is: a tertiarySystemFill track, a white
        // pill — so only the lenses differ.
        ours.hosting = .container
        ours.fillsWidth = true
        ours.backgroundColor = .tertiarySystemFill
        ours.layer.cornerCurve = .continuous
        ours.layer.cornerRadius = 16
        ours.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ours)
        NSLayoutConstraint.activate([
            native.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            native.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            native.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ours.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            ours.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            ours.topAnchor.constraint(equalTo: native.bottomAnchor, constant: 32),
            // The native control's height, so the two lenses compare at one size.
            ours.heightAnchor.constraint(equalTo: native.heightAnchor)
        ])
    }
}

/// The page behind the bars: a flat colour, or a pattern whose displacement
/// and blur through the glass can be read off the frames.
private final class LensLabBackground: UIView {
    private let mode: String

    init(mode: String) {
        self.mode = mode
        super.init(frame: .zero)
        switch mode {
        case "black": backgroundColor = .black
        case "red": backgroundColor = UIColor(red: 0.85, green: 0.15, blue: 0.2, alpha: 1)
        default: backgroundColor = .white
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        switch mode {
        case "stripes":
            context.setFillColor(UIColor.black.cgColor)
            var x: CGFloat = 0
            while x < bounds.width { context.fill(CGRect(x: x, y: 0, width: 6, height: bounds.height)); x += 12 }
        case "grid":
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(1)
            var x: CGFloat = 0
            while x < bounds.width { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: bounds.height)); x += 10 }
            var y: CGFloat = 0
            while y < bounds.height { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: bounds.width, y: y)); y += 10 }
            context.strokePath()
        case "photo":
            let colors = [UIColor.systemOrange, .systemTeal, .systemPurple, .systemGreen, .systemPink, .systemBlue]
            for (index, color) in colors.enumerated() {
                context.setFillColor(color.cgColor)
                let size: CGFloat = 140
                let x = CGFloat(index % 3) * 140 - 10, y = bounds.height - 260 + CGFloat(index / 3) * 90
                context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            }
        case "text":
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.black]
            var y: CGFloat = 60
            while y < bounds.height {
                ("Liquid Glass lens bench — the quick brown fox jumps" as NSString).draw(at: CGPoint(x: 8, y: y), withAttributes: attributes)
                y += 30
            }
        default:
            break
        }
    }
}

/// Prints a view/layer tree with its filters and readable private properties.
@MainActor
enum LensDumper {
    static func dumpView(_ view: UIView, depth: Int, maxDepth: Int = 12) {
        let pad = String(repeating: "  ", count: depth)
        let frame = view.convert(view.bounds, to: nil)
        print("[lenslab] \(pad)V \(type(of: view)) frame=\(fmt(frame)) alpha=\(view.alpha) hidden=\(view.isHidden) bg=\(view.backgroundColor.map { "\($0)" } ?? "-")")
        dumpLayer(view.layer, depth: depth + 1, pad: pad + "  ", descend: false)
        guard depth < maxDepth else { return }
        for child in view.subviews { dumpView(child, depth: depth + 1, maxDepth: maxDepth) }
        // Sublayers that belong to no subview (portals, SDF layers, backdrops).
        let viewLayers = Set(view.subviews.map { ObjectIdentifier($0.layer) })
        for sub in view.layer.sublayers ?? [] where !viewLayers.contains(ObjectIdentifier(sub)) {
            dumpLayer(sub, depth: depth + 1, pad: pad + "  ", descend: true)
        }
    }

    static func dumpLayer(_ layer: CALayer, depth: Int, pad: String, descend: Bool) {
        var line = "[lenslab] \(pad)L \(type(of: layer)) frame=\(fmt(layer.frame)) opacity=\(layer.opacity)"
        if layer.cornerRadius > 0 { line += " r=\(layer.cornerRadius)" }
        if let compositing = layer.compositingFilter { line += " compositing=\(describe(compositing))" }
        if layer.backgroundColor != nil { line += " bg=\(UIColor(cgColor: layer.backgroundColor!))" }
        print(line)
        for filter in layer.filters ?? [] { print("[lenslab] \(pad)  filter \(describe(filter))") }
        for filter in layer.backgroundFilters ?? [] { print("[lenslab] \(pad)  bgfilter \(describe(filter))") }
        let className = String(describing: type(of: layer))
        if className != "CALayer" {
            for (key, value) in properties(of: layer) { print("[lenslab] \(pad)  .\(key) = \(value)") }
            // The SDF effect objects carry the shape's optics.
            if layer.responds(to: NSSelectorFromString("effect")), let effect = layer.value(forKey: "effect") as? NSObject {
                print("[lenslab] \(pad)  effect \(type(of: effect)): " + properties(of: effect).map { "\($0.0)=\($0.1)" }.joined(separator: " "))
                print("[lenslab] \(pad)  effect archive: " + describe(effect))
            }
        }
        if descend {
            for sub in layer.sublayers ?? [] { dumpLayer(sub, depth: depth + 1, pad: pad + "  ", descend: true) }
        }
    }

    /// A CAFilter's name and every input it declares.
    static func describe(_ filter: Any) -> String {
        guard let object = filter as? NSObject else { return "\(filter)" }
        var parts: [String] = []
        if object.responds(to: NSSelectorFromString("name")), let name = object.value(forKey: "name") { parts.append("name=\(name)") }
        if object.responds(to: NSSelectorFromString("type")), let type = object.value(forKey: "type") { parts.append("type=\(type)") }
        if object.responds(to: NSSelectorFromString("inputKeys")),
           let keys = object.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String] {
            for key in keys {
                let value = object.value(forKey: key)
                parts.append("\(key)=\(short(value))")
            }
        }
        // The inputs, read from the filter's own archive: CAFilter encodes
        // every input it carries (the prototype's technique).
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["$objects"] as? [Any] {
            // Every input key the archive names, read back by KVC.
            let keys = objects.compactMap { $0 as? String }.filter { $0.hasPrefix("input") }
            for key in Set(keys).sorted() {
                parts.append("\(key)=\(short(object.value(forKey: key)))")
            }
        }
        if parts.isEmpty { parts.append("\(object)") }
        return parts.joined(separator: " ")
    }

    /// Readable declared properties of the object's class (not its NSObject/CALayer basics).
    static func properties(of object: NSObject) -> [(String, String)] {
        var out: [(String, String)] = []
        var cls: AnyClass? = object_getClass(object)
        let stop: Set<String> = ["CALayer", "NSObject", "UIView", "UIResponder"]
        while let current = cls, !stop.contains(NSStringFromClass(current)) {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(current, &count) {
                for index in 0..<Int(count) {
                    let name = String(cString: property_getName(list[index]))
                    guard !name.hasPrefix("_"), object.responds(to: NSSelectorFromString(name)),
                          !["delegate", "superlayer", "sublayers", "layer", "description", "debugDescription", "hash", "superclass"].contains(name)
                    else { continue }
                    out.append((name, short(object.value(forKey: name))))
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return out
    }

    static func short(_ value: Any?) -> String {
        guard let value else { return "nil" }
        let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
#endif
