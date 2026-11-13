#if DEBUG
import CoreNavigation
import UIKit

/// `-latency-bench` (#2116): UIKit's own floor for each kind of response,
/// measured with `-interaction-latency` and real taps — a tab, a push, a
/// sheet, a full-screen cover, an alert, a menu — on screens that hold
/// nothing of the app's. A response that costs the same in the app is the
/// system's; the difference is ours.
///
/// The shell is the app's (a `UITabBarController` with the UITab API, two
/// tabs, a navigation stack each), so the tab and the push pay the same
/// chrome; the screens are empty.
public enum LatencyBench {
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-latency-bench") }

    public static func makeRoot() -> UIViewController {
        let tabs = UITabBarController()
        tabs.tabs = [
            UITab(title: "Bench", image: UIImage(systemName: "stopwatch"), identifier: "bench") { _ in
                UINavigationController(rootViewController: LatencyBenchViewController(title: "Bench"))
            },
            UITab(title: "Other", image: UIImage(systemName: "square"), identifier: "other") { _ in
                UINavigationController(rootViewController: LatencyBenchViewController(title: "Other"))
            },
        ]
        return tabs
    }
}

/// One empty screen with the bench's buttons; every screen it opens is
/// another of these, so each can open the next and close itself.
public final class LatencyBenchViewController: UIViewController {
    public init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [
            button("Push") { [weak self] in
                self?.navigationController?.pushViewController(LatencyBenchViewController(title: "Pushed"), animated: true)
            },
            button("Sheet") { [weak self] in
                let sheet = LatencyBenchViewController(title: "Sheet")
                sheet.sheetPresentationController?.detents = [.medium()]
                self?.present(sheet, animated: true)
            },
            button("Full screen") { [weak self] in
                let cover = LatencyBenchViewController(title: "Cover")
                cover.modalPresentationStyle = .fullScreen
                self?.present(cover, animated: true)
            },
            button("Alert") { [weak self] in
                let alert = UIAlertController(title: "Bench", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            },
            menuButton(),
            button("Close") { [weak self] in
                guard let self else { return }
                if presentingViewController != nil {
                    dismiss(animated: true)
                } else {
                    navigationController?.popViewController(animated: true)
                }
            },
        ])
        if title == "Bench", let cycles = Self.autoCycles { runAuto(cycles) }
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])
    }

    // MARK: - The overhead run (#2131)

    /// `-latency-bench-auto N`: N push/pop cycles, each push timed from the
    /// call through its layout and commit — the synchronous work every hook
    /// on the way adds to. The debug dashboard's cost is read by running it
    /// with and without its tools: `-interaction-latency` (on),
    /// `-latency-bench-auto-off` (installed, then switched off as the
    /// dashboard does), `-debug-dashboard` (opened, then closed first),
    /// `-latency-bench-tools frame-rate,touches` (those tools on, by id) and
    /// `-latency-bench-tools-off` (on, then off again: back to the baseline).
    private static var autoCycles: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-latency-bench-auto"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    private static var benchTools: [String] {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-latency-bench-tools"), index + 1 < arguments.count else { return [] }
        return arguments[index + 1].split(separator: ",").map(String.init)
    }

    private func runAuto(_ cycles: Int) {
        let arguments = ProcessInfo.processInfo.arguments
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if arguments.contains("-latency-bench-auto-off") { InteractionLatency.setActive(false, badge: false) }
            DebugDashboard.close()
            let tools = Self.benchTools.compactMap(DebugTools.tool)
            tools.forEach { $0.set(true) }
            if arguments.contains("-latency-bench-tools-off") { tools.forEach { $0.set(false) } }
            try? await Task.sleep(for: .seconds(1))
            var pushes: [Double] = []
            for _ in 0..<cycles {
                guard let self, let navigation = self.navigationController else { return }
                let started = CACurrentMediaTime()
                navigation.pushViewController(LatencyBenchViewController(title: "Pushed"), animated: true)
                navigation.view.layoutIfNeeded()
                CATransaction.flush()
                pushes.append((CACurrentMediaTime() - started) * 1000)
                try? await Task.sleep(for: .milliseconds(700))
                navigation.popViewController(animated: true)
                try? await Task.sleep(for: .milliseconds(700))
            }
            let sorted = pushes.dropFirst().sorted()
            func at(_ q: Double) -> String { String(format: "%.2f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) }
            let latency: String = InteractionLatency.isActive ? "on" : InteractionLatency.isInstalled ? "off" : "never"
            let dashboard: String = arguments.contains("-debug-dashboard") ? "opened-closed" : "never"
            let toolIDs: String = tools.isEmpty ? "none" : tools.map(\.id).joined(separator: ",")
            let toolState: String = tools.isEmpty ? "" : arguments.contains("-latency-bench-tools-off") ? "(on-off)" : "(on)"
            print("[bench-auto] latency=\(latency) dashboard=\(dashboard) tools=\(toolIDs)\(toolState)"
                  + " pushes=\(sorted.count) p50=\(at(0.5))ms p90=\(at(0.9))ms")
        }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private func menuButton() -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = "Menu"
        let button = UIButton(configuration: configuration)
        // A choice shows as the button's subtitle: the menu's own response
        // is what is measured, the row's is only there to do something.
        let choose: UIActionHandler = { [weak button] action in
            button?.configuration?.subtitle = action.title
        }
        button.menu = UIMenu(children: ["One", "Two", "Three"].map { UIAction(title: $0, handler: choose) })
        button.showsMenuAsPrimaryAction = true
        return button
    }
}
#endif
