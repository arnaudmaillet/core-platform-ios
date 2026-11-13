#if DEBUG
import AuthInterface
import CoreModels
import CoreNavigation
import CoreNetworkingMocks
import DebugTools
import DesignSystem
import UIKit

/// The app's side of the debug dashboard (#2131, #2132): its sections in
/// order — context, routes, the mock network, flags, performance, logs — and
/// the app's own tools (the presentation budget). The dashboard itself and
/// its generic sections live in CoreNavigation.
@MainActor
enum DebugDashboardWiring {
    static func install(container: AppContainer) {
        DebugDashboard.startConsoleCaptureIfFlagged()
        DebugTools.register(DebugTool(
            id: "presentation-budget",
            title: "Presentation budget",
            detail: "Times the turn that builds each screen; samples the main thread past the budget (charter P2)",
            cost: "about 1 ms per screen, a sampled stack when over",
            costMs: 1,
            isOn: { PresentationBudget.isActive },
            apply: { PresentationBudget.setActive($0) }
        ))
        var entries: [DebugDashboard.Entry] = [
            DebugDashboard.Entry(title: "Context", symbol: "info.circle") {
                let controller = DebugListViewController(title: "Context") { contextSections(container: container) }
                Task { await refreshViewer(container: container); controller.reload() }
                return controller
            },
            DebugDashboard.bugReportEntry,
            DebugDashboard.Entry(title: "Routes", symbol: "arrow.triangle.turn.up.right.diamond") {
                DebugListViewController(title: "Routes") { routeSections(container: container) }
            },
        ]
        if container.environment == .mock {
            entries.append(NetworkConditionsMenu.entry(faults: container.mockNetworkFaults, bff: container.mockBackend.bff))
        }
        entries += [DebugDashboard.flagsEntry, DebugDashboard.performanceEntry, DebugDashboard.interfaceEntry]
        entries += DebugDashboardTools.entries(container: container)
        entries.append(DebugDashboard.logsEntry)
        DebugDashboard.entries = entries
        Task { await refreshViewer(container: container) }
        DebugDashboard.reportAttachments = {
            [
                ("context.txt", contextText(container: container)),
                ("failed-calls.txt", DebugDashboardTools.failedCallsText()),
            ]
        }
    }

    /// The shake: the dashboard — unless a text field is being edited, where
    /// the shake is iOS's undo and is left to it.
    static func handleShake(in scene: UIWindowScene) {
        guard !isEditingText(in: scene) else { return }
        DebugDashboard.present(in: scene)
    }

    private static func isEditingText(in scene: UIWindowScene) -> Bool {
        scene.windows.contains { window in
            var stack: [UIView] = [window]
            while let view = stack.popLast() {
                if view.isFirstResponder, view is UITextInput { return true }
                stack.append(contentsOf: view.subviews)
            }
            return false
        }
    }

    // MARK: - Context

    private static var viewer = "…"

    /// Read when Context opens and when the dashboard is installed, so a
    /// bug report made without opening Context still names the viewer.
    private static func refreshViewer(container: AppContainer) async {
        switch await container.viewerSession.current() {
        case .guest:
            viewer = "guest"
        case .member(let account, let profile):
            viewer = "member · account \(account.rawValue) · profile \(profile?.rawValue ?? "unresolved")"
        }
    }

    private static func text(of rows: [DebugRow]) -> String {
        rows.compactMap { row -> String? in
            if case .info(let title, let value) = row { return "\(title): \(value)" }
            return nil
        }.joined(separator: "\n")
    }

    /// The context as text, for a bug report.
    private static func contextText(container: AppContainer) -> String {
        text(of: contextSections(container: container).flatMap(\.rows))
    }

    private static func contextSections(container: AppContainer) -> [DebugSection] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let commit = info["GitCommit"] as? String ?? "not embedded in this build"
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        let environment: String
        switch container.environment {
        case .mock:
            let network = container.mockNetworkFaults.isOffline
                ? "offline" : NetworkConditionsMenu.describe(container.mockBackend.bff.simulatedConditions)
            environment = "mock BFF · \(network)"
        default:
            environment = "\(container.environment)"
        }
        let device = UIDevice.current
        let traits = UITraitCollection.current
        let rows: [DebugRow] = [
            .info("Version", "\(version) (\(build))"),
            .info("Commit", commit),
            .info("Configuration", "Debug"),
            .info("Built", built),
            .info("Environment", environment),
            .info("Viewer", viewer),
            .info("Token expiry", "not exposed by the session"),
            .info("Device", "\(device.model) · \(device.systemName) \(device.systemVersion)"),
            .info("Text size", traits.preferredContentSizeCategory.rawValue
                .replacingOccurrences(of: "UICTContentSizeCategory", with: "")),
            .info("Appearance", traits.userInterfaceStyle == .dark ? "dark" : "light"),
            .info("Language", Locale.preferredLanguages.first ?? "—"),
        ]
        let summary = text(of: rows)
        return [
            DebugSection(title: nil, footer: "Tap a row to copy it. Tokens are never shown.", rows: rows),
            DebugSection(title: nil, rows: [
                .action("Copy All", detail: nil, run: { UIPasteboard.general.string = summary }),
            ]),
        ]
    }

    // MARK: - Routes

    private static func routeSections(container: AppContainer) -> [DebugSection] {
        let samples: [(String, AppRoute)] = [
            ("Feed", .feed),
            ("Search", .search),
            ("Hashtag #goldenhour", .hashtag("goldenhour")),
            ("Profile @kenji.dev", .profileHandle("kenji.dev")),
            ("Profile @vera.lindqvist", .profileHandle("vera.lindqvist")),
            ("Post post-0000", .post(PostID("post-0000"))),
            ("Comments of post-0000", .comments(PostID("post-0000"))),
            ("Post stream (3 posts)", .postStream([PostID("post-0000"), PostID("post-0003"), PostID("post-0006")])),
        ]
        let open: (AppRoute) -> Void = { route in
            DebugDashboard.close()
            container.router.route(to: route)
        }
        return [
            DebugSection(title: "Open", footer: "Each closes the dashboard and routes as a tap would.",
                         rows: samples.map { title, route in .action(title, detail: nil, run: { open(route) }) }),
            DebugSection(title: "Deep link", footer: "A core-platform.click or wynn: link from the clipboard.", rows: [
                .action("Open the Link on the Clipboard", detail: UIPasteboard.general.string, run: {
                    guard let text = UIPasteboard.general.string, let url = URL(string: text),
                          let route = AppRoute(deepLink: url) else { return }
                    open(route)
                }),
            ]),
            DebugSection(
                title: "At launch only",
                footer: "An app cannot relaunch itself: these copy the simulator command that relaunches with the argument.",
                rows: launchOnly.map { argument, title in
                    .action(title, detail: argument, run: {
                        UIPasteboard.general.string = "xcrun simctl launch booted cn.wynn.core-platform-ios -mock-auto-login \(argument)"
                    })
                }
            ),
        ]
    }

    private static let launchOnly: [(String, String)] = [
        ("-guest", "As a guest"),
        ("-select-tab 2", "On Messages"),
        ("-open-settings security", "On Security and Login"),
        ("-latency-bench", "UIKit's floor bench"),
        ("-lens-lab", "The lens lab"),
        ("-voice-lab", "The voice lab"),
        ("-voice-catalog", "The voice component's sizes (#2205)"),
        ("-embed-catalog", "The embed card's sizes and states (#2216)"),
    ]
}
#endif
