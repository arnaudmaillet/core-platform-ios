// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2131).
#if DEBUG
import DesignSystem
import LaunchArguments
import OSLog
import UIKit

// MARK: - Flags

public extension DebugDashboard {
    /// Every `DebugFlags` switch. Persisted (flags are the one thing that
    /// is); the launch argument overrides the switch.
    static var flagsEntry: Entry {
        Entry(title: "Flags", symbol: "flag") {
            DebugListViewController(title: "Flags") {
                [
                    DebugSection(
                        title: nil,
                        footer: "A flag passed at launch stays on. ⟳ = applies at the next launch.",
                        rows: DebugFlags.all.map { flag in
                            let passed = DebugFlags.isPassedAtLaunch(flag.argument)
                            let detail = [
                                flag.detail,
                                flag.argument + (flag.appliesAtLaunch ? " · ⟳" : ""),
                                passed ? "on from the launch argument" : nil,
                            ].compactMap { $0 }.joined(separator: "\n")
                            return .toggle(DebugToggle(
                                title: flag.title, detail: detail,
                                isOn: { DebugFlags.isOn(flag.argument) }, isEnabled: !passed,
                                set: { DebugFlags.set(flag.argument, on: $0) }
                            ))
                        }
                    ),
                    DebugSection(title: nil, rows: [
                        .action("Reset All Flags", detail: nil, run: { DebugFlags.reset() }),
                    ]),
                ]
            }
        }
    }
}

// MARK: - Performance

public extension DebugDashboard {
    /// The latency harness of #2116, switchable live, its last records and
    /// hangs; plus the tools the app registers (the presentation budget).
    static var performanceEntry: Entry {
        registerLatencyTool()
        DebugTools.register(DebugTool(
            id: "frame-rate",
            title: "Frames, hitches, memory",
            detail: "A corner badge: fps, hitch ms per second, hangs, footprint and CPU (#2133)",
            cost: "a display link while shown; its own ms per frame is on it",
            costMs: 0.1,
            isOn: { FrameRateOverlay.shared.isOn },
            apply: { FrameRateOverlay.shared.setOn($0) }
        ))
        return Entry(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
            DebugListViewController(title: "Performance") { performanceSections() }
        }
    }

    private static func registerLatencyTool() {
        // A record taken beside another costly tool, or under a quick
        // switch, says so.
        InteractionLatency.measuredUnder = {
            let others = DebugTools.running.filter { $0.id != "interaction-latency" }.map(\.title) + switchesOn
            return others.isEmpty ? nil : "under " + others.joined(separator: ", ")
        }
        DebugTools.register(DebugTool(
            id: "interaction-latency",
            title: "Interaction latency",
            detail: "Input → first frame for every tap, and HANG lines (#2116)",
            // Measured with -latency-bench-auto (#2132): +0.2–0.5 ms per push
            // at p50 on the iPhone 18 Pro simulator, inside the noise.
            cost: "about 0.3 ms per push (measured)",
            costMs: 0.3,
            isOn: { InteractionLatency.isActive },
            apply: { InteractionLatency.setActive($0, badge: InteractionLatency.showsBadge) }
        ))
    }

    private static func performanceSections() -> [DebugSection] {
        let tools = DebugTools.registered.filter { $0.isCostly }
        var sections = [DebugSection(
            title: "Instruments",
            footer: "Turn on only what you need now: each costly tool says what it adds, and all of them turn off at the next launch.",
            rows: tools.map { .toggle(.tool($0)) } + [
                .toggle(DebugToggle(
                    title: "Latency badge", detail: "A red badge over 100 ms, amber from 60 ms",
                    isOn: { InteractionLatency.showsBadge }, isEnabled: InteractionLatency.isActive,
                    set: { InteractionLatency.showsBadge = $0 }
                )),
            ]
        )]
        let memory = DebugSystemStats.footprintMB().map { "\(Int($0.rounded())) MB" } ?? "—"
        let cpu = DebugSystemStats.cpuPercent().map { "\(Int($0.rounded()))% of a core" } ?? "—"
        sections.append(DebugSection(title: "Now", footer: "Read when this screen opens; the badge reads them once a second.", rows: [
            .info("Memory (footprint)", memory),
            .info("CPU", cpu),
            .action("Simulate a Memory Warning", detail: "Posts didReceiveMemoryWarning to the app's observers", run: {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
            }),
        ]))
        let records = InteractionLatency.records.suffix(50).reversed()
        sections.append(DebugSection(
            title: "Last interactions",
            footer: records.isEmpty ? "None yet: turn the latency instrument on and use the app." : nil,
            rows: records.map { record in
                let verdict = record.latencyMs > InteractionLatency.budgetMs ? "OVER"
                    : record.latencyMs >= InteractionLatency.atRiskMs ? "at risk" : "ok"
                let under = record.context.map { " · \($0)" } ?? ""
                return .info(record.response, "\(Int(record.latencyMs.rounded())) ms · \(verdict)\(under)")
            }
        ))
        let hangs = InteractionLatency.hangs.suffix(20).reversed()
        if !hangs.isEmpty {
            let time = Date.FormatStyle(date: .omitted, time: .standard)
            sections.append(DebugSection(title: "Hangs (main thread ≥ 100 ms)", rows: hangs.map { hang in
                .info("\(hang.at.formatted(time)) · \(hang.during)", "\(Int(hang.ms.rounded())) ms")
            }))
        }
        let log = URL.documentsDirectory.appendingPathComponent("interaction-latency.log")
        if FileManager.default.fileExists(atPath: log.path) {
            sections.append(DebugSection(title: nil, rows: [
                .action("Share the Latency Log", detail: nil, run: { share([log]) }),
            ]))
        }
        return sections
    }

    /// The share sheet, from the dashboard's own top screen.
    static func share(_ items: [Any]) {
        guard let top = topController() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }

    static func topController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let host = windows.first(where: { !$0.isHidden && $0.windowLevel == .alert - 1 }) else { return nil }
        var top = host.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Logs

public extension DebugDashboard {
    static var logsEntry: Entry {
        Entry(title: "Logs", symbol: "text.alignleft") { DebugLogViewController() }
    }

    /// The console capture from launch, when its flag is on (#2132).
    static func startConsoleCaptureIfFlagged() {
        if DebugFlags.isOn("-console-capture") { ConsoleCapture.shared.start() }
    }
}

/// What leaves the device or the screen is masked: tokens, authorization
/// values, secrets, email addresses and phone numbers (#2131's privacy rule).
public enum DebugRedaction {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#, "‹jwt›"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer ‹redacted›"),
        (#"(?i)\b(token|access_token|refresh_token|authorization|password|secret|api[_-]?key)(["']?\s*[:=]\s*["']?)[^\s"',}&]+"#, "$1$2‹redacted›"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "‹email›"),
        (#"\+?\d[\d\s().-]{8,}\d"#, "‹phone›"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1
            )
        }
    }
}

/// The app process's own log entries since launch (`OSLogStore`), read off
/// the main thread on demand — never in the background — filtered by level
/// and subsystem, searchable, exportable masked.
final class DebugLogViewController: UITableViewController, UISearchResultsUpdating {
    struct Entry: Sendable {
        let date: Date
        let level: Int
        let subsystem: String
        let category: String
        let message: String
    }

    private var all: [Entry] = []
    /// Why the unified log could not be read, when it could not.
    private var readError: String?
    private var shown: [Entry] = []
    private var minimumLevel = 0
    /// The app's own entries (its subsystems, and the console) by default:
    /// the process's log is mostly the system frameworks'.
    private var appOnly = true
    /// How far back the unified log is read: the last 5 minutes by default,
    /// since a full read of the process's log takes tens of seconds.
    private var sinceLaunch = false
    private var isReading = false
    private var subsystem: String?
    private var query = ""
    private let time = Date.FormatStyle(date: .omitted, time: .standard)

    init() {
        super.init(style: .plain)
        title = "Logs"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.export() }),
            UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.load() }),
            UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: filterMenu()),
        ]
        load()
    }

    private func load() {
        isReading = true
        let since: Date? = sinceLaunch ? nil : Date().addingTimeInterval(-300)
        // The console at once (it is in memory); the unified log when its
        // slow read lands.
        all = Self.console(since: since)
        apply()
        Task { [weak self] in
            let (entries, error) = await Task.detached(priority: .userInitiated) { Self.read(since: since) }.value
            guard let self else { return }
            self.all = entries
            self.readError = error
            self.isReading = false
            self.apply()
            self.navigationItem.rightBarButtonItems?.last?.menu = self.filterMenu()
        }
    }

    /// The last 2000 entries of this process since launch: the unified
    /// log's (`Logger`, `os_log`) and, while it is captured, the console's
    /// (`print`, where most of the app logs).
    nonisolated private static func read(since: Date?) -> ([Entry], String?) {
        var collected: [Entry] = []
        var failure: String?
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try since.map { try store.getEntries(at: store.position(date: $0)) } ?? store.getEntries()
            for case let log as OSLogEntryLog in entries {
                collected.append(Entry(
                    date: log.date, level: log.level.rawValue, subsystem: log.subsystem,
                    category: log.category, message: log.composedMessage
                ))
                if collected.count > 4000 { collected.removeFirst(2000) }
            }
        } catch {
            failure = "\(error.localizedDescription)"
        }
        collected += console(since: since)
        return (Array(collected.sorted { $0.date < $1.date }.suffix(2000)), failure)
    }

    nonisolated private static func console(since: Date?) -> [Entry] {
        ConsoleCapture.shared.captured.suffix(2000)
            .filter { since == nil || $0.date >= since! }
            .map { line in
                Entry(date: line.date, level: line.isError ? 3 : 2, subsystem: "console",
                      category: line.isError ? "stderr" : "stdout", message: line.text)
            }
    }

    private func filterMenu() -> UIMenu {
        let levels: [(String, Int)] = [("All", 0), ("Info and up", 2), ("Notice and up", 3), ("Errors", 4)]
        let levelMenu = UIMenu(title: "Level", options: .displayInline, children: levels.map { name, value in
            UIAction(title: name, state: minimumLevel == value ? .on : .off) { [weak self] _ in
                self?.minimumLevel = value
                self?.apply()
            }
        })
        let subsystems = Array(Set(all.map(\.subsystem))).filter { !$0.isEmpty }.sorted()
        let subsystemMenu = UIMenu(title: "Subsystem", options: .displayInline, children:
            [UIAction(title: "Every subsystem", state: subsystem == nil ? .on : .off) { [weak self] _ in
                self?.subsystem = nil
                self?.apply()
            }] + subsystems.prefix(30).map { name in
                UIAction(title: name, state: subsystem == name ? .on : .off) { [weak self] _ in
                    self?.subsystem = name
                    self?.apply()
                }
            })
        let capture = ConsoleCapture.shared
        let console = UIAction(
            title: "Capture Console Output", subtitle: "print, stdout and stderr; read off the main thread",
            state: capture.isOn ? .on : .off
        ) { [weak self] _ in
            if capture.isOn { capture.stop() } else { capture.start() }
            self?.load()
        }
        let scope = UIMenu(title: "Scope", options: .displayInline, children: [
            UIAction(title: "The App's Own Entries", state: appOnly ? .on : .off) { [weak self] _ in
                self?.appOnly.toggle()
                self?.apply()
            },
            UIAction(title: "Since Launch (slow)", subtitle: "Otherwise the last 5 minutes",
                     state: sinceLaunch ? .on : .off) { [weak self] _ in
                self?.sinceLaunch.toggle()
                self?.load()
            },
        ])
        return UIMenu(children: [UIMenu(options: .displayInline, children: [console]), scope, levelMenu, subsystemMenu])
    }

    private func apply() {
        shown = all.reversed().filter { entry in
            entry.level >= minimumLevel
                && (!appOnly || entry.subsystem == "console" || entry.subsystem.hasPrefix("cn.wynn")
                    || entry.subsystem.isEmpty)
                && (subsystem == nil || entry.subsystem == subsystem)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query)
                    || entry.category.localizedCaseInsensitiveContains(query))
        }
        tableView.reloadData()
        navigationItem.rightBarButtonItems?.last?.menu = filterMenu()
        let footer = UILabel()
        footer.numberOfLines = 0
        footer.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .secondaryLabel
        footer.textAlignment = .center
        let reading: String = isReading ? "Reading…\n" : ""
        let window: String = sinceLaunch ? "since launch" : "last 5 min"
        let capture: String = ConsoleCapture.shared.isOn ? "on" : "off"
        let error: String = readError.map { "\nunified log: \($0)" } ?? ""
        footer.text = "\(reading)\(shown.count) of \(all.count) entries · \(window) · console capture \(capture)\(error)"
        footer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 54)
        tableView.tableFooterView = footer
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        apply()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = shown[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = DebugRedaction.redact(entry.message)
        content.textProperties.numberOfLines = 4
        content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.secondaryText = "\(entry.date.formatted(time)) · \(Self.levelName(entry.level)) · \(entry.subsystem) \(entry.category)"
        content.secondaryTextProperties.color = entry.level >= 4 ? .systemRed : .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    private func export() {
        let entries = shown
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                let text = entries.reversed().map { entry -> String in
                    let message: String = DebugRedaction.redact(entry.message)
                    return "\(entry.date.ISO8601Format()) [\(Self.levelName(entry.level))] \(entry.subsystem) \(entry.category): \(message)"
                }.joined(separator: "\n")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("app-log.txt")
                return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
            }.value
            guard self != nil, let url else { return }
            DebugDashboard.share([url])
        }
    }

    nonisolated private static func levelName(_ level: Int) -> String {
        switch level {
        case 1: "debug"
        case 2: "info"
        case 3: "notice"
        case 4: "error"
        case 5: "fault"
        default: "—"
        }
    }
}
#endif
