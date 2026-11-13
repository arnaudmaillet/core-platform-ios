// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2131).
#if DEBUG
import DesignSystem
import LaunchArguments
import UIKit

/// One switchable instrument of the debug dashboard (#2131): the latency
/// harness, the presentation budget, the network log…
///
/// ⚠️ THE DASHBOARD MUST NOT DISTORT WHAT IT MEASURES (the epic's first
/// rule). A tool installs nothing until it is turned on and goes inert when
/// it is turned off; a COSTLY one (per frame, per event) states its cost on
/// its row, warns when a second one joins it, shows in the cost badge while
/// it runs, and is off again at the next launch — no tool state is
/// persisted, only flags are (`DebugFlags`).
@MainActor
public final class DebugTool {
    public let id: String
    public let title: String
    public let detail: String
    /// What it adds, measured ("~1 ms per interaction"); nil for a free one.
    public let cost: String?
    /// Roughly what `cost` says, in ms per interaction, for the badge's sum.
    public let costMs: Double
    public let isOn: () -> Bool
    private let apply: (Bool) -> Void

    public var isCostly: Bool { cost != nil }

    public init(id: String, title: String, detail: String, cost: String? = nil, costMs: Double = 0,
                isOn: @escaping () -> Bool, apply: @escaping (Bool) -> Void) {
        self.id = id
        self.title = title
        self.detail = detail
        self.cost = cost
        self.costMs = costMs
        self.isOn = isOn
        self.apply = apply
    }

    public func set(_ on: Bool) {
        apply(on)
        DebugTools.didChange()
    }
}

@MainActor
public enum DebugTools {
    public private(set) static var registered: [DebugTool] = []

    /// Adds `tool`, replacing one with the same id.
    public static func register(_ tool: DebugTool) {
        registered.removeAll { $0.id == tool.id }
        registered.append(tool)
    }

    public static func tool(_ id: String) -> DebugTool? { registered.first { $0.id == id } }

    /// The costly tools running now.
    public static var running: [DebugTool] { registered.filter { $0.isCostly && $0.isOn() } }

    /// What turning `tool` on adds to the ones already running, or nil when
    /// it runs alone (or costs nothing): the owner's rule, turn on only what
    /// the moment needs.
    public static func warning(turningOn tool: DebugTool) -> String? {
        guard tool.isCostly else { return nil }
        let others = running.filter { $0.id != tool.id }
        guard !others.isEmpty else { return nil }
        let total = others.reduce(tool.costMs) { $0 + $1.costMs }
        let names = (others.map(\.title) + [tool.title]).joined(separator: ", ")
        let added: String = format(total)
        return "\(others.count + 1) costly tools would run (\(names)): about \(added) added per interaction. "
            + "Measurements taken meanwhile are labelled. Turn on only what you need now."
    }

    /// The badge's line while costly tools run, nil when none does.
    public static var badgeLine: String? {
        let tools = running
        guard !tools.isEmpty else { return nil }
        let total = tools.reduce(0) { $0 + $1.costMs }
        return "⚙︎ \(tools.count) tool\(tools.count == 1 ? "" : "s") · \(total < 1 ? "" : "~")\(format(total))"
    }

    static func didChange() {
        DebugCostBadge.refresh()
    }

    static func format(_ ms: Double) -> String {
        ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
    }
}

/// The persistent cost indicator: a small badge at the screen's
/// bottom-trailing corner, above the tab bar, while any costly tool runs, so
/// nobody forgets that the numbers are distorted. A passthrough window; no animation (an animation of its own
/// would read as the next input's response).
@MainActor
enum DebugCostBadge {
    private static var window: BadgeWindow?

    static func refresh() {
        guard let line = DebugTools.badgeLine else {
            window?.isHidden = true
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let badge = window ?? BadgeWindow(windowScene: scene)
        window = badge
        badge.show(line)
    }

    private final class BadgeWindow: AppWindow, DebugOverlayWindow {
        private let label = UILabel()

        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert + 9
            isUserInteractionEnabled = false
            backgroundColor = .clear
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            label.textAlignment = .center
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.accessibilityLabel = "Debug tools running"
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func show(_ line: String) {
            label.text = line
            let size = label.sizeThatFits(CGSize(width: 240, height: 18))
            let width = size.width + 14
            // Above the tab bar, clear of the bars' items: it must never
            // cover a control.
            let y = bounds.height - safeAreaInsets.bottom - 96
            label.frame = CGRect(x: bounds.width - width - 12, y: y, width: width, height: 18)
            isHidden = false
        }
    }
}
#endif
