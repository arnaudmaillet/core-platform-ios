// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2131).
#if DEBUG
import DesignSystem
import UIKit

/// The in-app debug dashboard (#2131, #2132): shake the device (the
/// Simulator's Device ▸ Shake), long-press the build version in Settings, or
/// launch with `-debug-dashboard`.
///
/// It lives in ITS OWN WINDOW: nothing is presented on the app's stacks, so
/// the app's presentation chain, its covers and its navigation never see it.
/// While it is up the latency harness is paused — the dashboard's own taps
/// and sheets are never the app's (#2131's first rule).
///
/// The app hands it its sections (`entries`): context, routes, the mock
/// network…; the generic ones (flags, performance, logs) are built here.
@MainActor
public enum DebugDashboard {
    public struct Entry {
        public let title: String
        public let symbol: String
        public let make: @MainActor () -> UIViewController

        public init(title: String, symbol: String, make: @escaping @MainActor () -> UIViewController) {
            self.title = title
            self.symbol = symbol
            self.make = make
        }
    }

    /// The sections, in order; set once by the app.
    public static var entries: [Entry] = []

    private static var window: DashboardWindow?

    public static var isPresented: Bool { window.map { !$0.isHidden } ?? false }

    /// Opens the dashboard over the foreground scene. A second call while it
    /// is up does nothing.
    public static func present(in scene: UIWindowScene? = nil) {
        guard !isPresented, let scene = scene ?? foregroundScene() else { return }
        let window = window ?? DashboardWindow(windowScene: scene)
        self.window = window
        InteractionLatency.isPaused = true
        window.isHidden = false
        let root = DebugListViewController(title: "Debug") { rootSections() }
        root.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { _ in close() }
        )
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = true
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.presentationController?.delegate = window
        window.rootViewController?.present(navigation, animated: true)
    }

    public static func close() {
        guard let window, !window.isHidden else { return }
        window.rootViewController?.dismiss(animated: true) { finish() }
    }

    fileprivate static func finish() {
        window?.isHidden = true
        InteractionLatency.isPaused = false
    }

    private static func rootSections() -> [DebugSection] {
        var sections: [DebugSection] = []
        let running = DebugTools.running
        if !running.isEmpty {
            sections.append(DebugSection(
                title: "Running now",
                footer: "Costly tools distort what they measure. They turn off at the next launch.",
                rows: running.map { tool in
                    .toggle(DebugToggle(title: tool.title, detail: tool.cost ?? tool.detail,
                                        isOn: tool.isOn, set: { tool.set($0) }))
                }
            ))
        }
        sections.append(DebugSection(title: nil, footer: nil, rows: entries.map { entry in
            .link(entry.title, symbol: entry.symbol, make: entry.make)
        }))
        return sections
    }

    private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// A clear window above the app, below the latency and cost badges, that
    /// hosts the dashboard's sheet.
    private final class DashboardWindow: AppWindow, UIAdaptivePresentationControllerDelegate {
        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert - 1
            backgroundColor = .clear
            let root = UIViewController()
            root.view.backgroundColor = .clear
            rootViewController = root
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            DebugDashboard.finish()
        }
    }
}

// MARK: - The list every section is drawn with

/// A switch row. `set` turns it on or off; a costly tool's warning is asked
/// for first, through `warning`.
@MainActor
public struct DebugToggle {
    public let title: String
    public let detail: String?
    public let isOn: () -> Bool
    public let isEnabled: Bool
    public let warning: (() -> String?)?
    public let set: (Bool) -> Void

    public init(title: String, detail: String?, isOn: @escaping () -> Bool, isEnabled: Bool = true,
                warning: (() -> String?)? = nil, set: @escaping (Bool) -> Void) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.warning = warning
        self.set = set
    }

    /// The row for a registered tool, its cost in its subtitle and its
    /// warning asked before it joins another costly one.
    public static func tool(_ tool: DebugTool) -> DebugToggle {
        DebugToggle(
            title: tool.title,
            detail: tool.cost.map { "\(tool.detail) · costs \($0)" } ?? tool.detail,
            isOn: tool.isOn,
            warning: { DebugTools.warning(turningOn: tool) },
            set: { tool.set($0) }
        )
    }
}

@MainActor
public enum DebugRow {
    /// A fact; tapping copies its value.
    case info(String, String)
    case toggle(DebugToggle)
    case action(String, detail: String?, run: @MainActor () -> Void)
    case link(String, symbol: String?, make: @MainActor () -> UIViewController)
}

@MainActor
public struct DebugSection {
    public let title: String?
    public let footer: String?
    public let rows: [DebugRow]

    public init(title: String?, footer: String? = nil, rows: [DebugRow]) {
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// A grouped list of `DebugSection`s, rebuilt each time it appears and after
/// every switch.
public final class DebugListViewController: UITableViewController {
    private let build: @MainActor () -> [DebugSection]
    private var sections: [DebugSection] = []

    public init(title: String, build: @escaping @MainActor () -> [DebugSection]) {
        self.build = build
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    public func reload() {
        sections = build()
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        switch sections[indexPath.section].rows[indexPath.row] {
        case .info(let title, let value):
            content = UIListContentConfiguration.valueCell()
            content.text = title
            content.secondaryText = value
            content.secondaryTextProperties.numberOfLines = 2
        case .toggle(let toggle):
            content.text = toggle.title
            content.secondaryText = toggle.detail
            let control = UISwitch()
            control.isOn = toggle.isOn()
            control.isEnabled = toggle.isEnabled
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                self.flip(toggle, to: control.isOn, control: control)
            }, for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .action(let title, let detail, _):
            content.text = title
            content.secondaryText = detail
            content.textProperties.color = tableView.tintColor
        case .link(let title, let symbol, _):
            content.text = title
            content.image = symbol.flatMap { UIImage(systemName: $0) }
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .info(_, let value):
            UIPasteboard.general.string = value
        case .toggle:
            break
        case .action(_, _, let run):
            run()
            reload()
        case .link(_, _, let make):
            navigationController?.pushViewController(make(), animated: true)
        }
    }

    private func flip(_ toggle: DebugToggle, to on: Bool, control: UISwitch) {
        guard on, let warning = toggle.warning?() else {
            toggle.set(on)
            reload()
            return
        }
        let alert = UIAlertController(title: "Another costly tool", message: warning, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in control.setOn(false, animated: true) })
        alert.addAction(UIAlertAction(title: "Turn On", style: .default) { [weak self] _ in
            toggle.set(true)
            self?.reload()
        })
        present(alert, animated: true)
    }
}
#endif
