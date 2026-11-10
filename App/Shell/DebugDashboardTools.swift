#if DEBUG
import AVFoundation
import CacheKit
import CoreLocation
import CoreNavigation
import CoreNetworking
import DesignSystem
import LocalStore
import PostGrid
import Photos
import UIKit
import UserNotifications
import VoiceKitUI

/// The debug dashboard's second batch (#2133), the app's side: the network
/// log, the caches and resets, the app's preferences, the permissions, a
/// local push and the mock scenarios. The frame-rate overlay and memory live
/// with the generic sections in CoreNavigation.
@MainActor
enum DebugDashboardTools {
    static func entries(container: AppContainer) -> [DebugDashboard.Entry] {
        DebugTools.register(DebugTool(
            id: "network-log",
            title: "Network log",
            detail: "Every BFF call: method, duration, status, sizes, bodies (#2133)",
            cost: "a copy per call, kept off the main thread",
            costMs: 0.1,
            isOn: { NetworkLog.shared.isOn },
            apply: { NetworkLog.shared.isOn = $0 }
        ))
        return [
            DebugDashboard.Entry(title: "Network", symbol: "arrow.up.arrow.down") { networkList() },
            DebugDashboard.Entry(title: "Caches and Resets", symbol: "internaldrive") {
                DebugListViewController(title: "Caches and Resets") { cacheSections(container: container) }
            },
            DebugDashboard.Entry(title: "Preferences", symbol: "slider.horizontal.3") { preferencesList() },
            DebugDashboard.Entry(title: "Permissions", symbol: "hand.raised") { permissionsList() },
            DebugDashboard.Entry(title: "Local Push", symbol: "bell.badge") {
                DebugListViewController(title: "Local Push") { pushSections() }
            },
            DebugDashboard.Entry(title: "Mock Scenarios", symbol: "theatermasks") {
                DebugListViewController(title: "Mock Scenarios") { scenarioSections() }
            },
            DebugDashboard.Entry(title: "Labs", symbol: "flask") {
                DebugListViewController(title: "Labs") { labSections() }
            },
        ]
    }

    /// The failed calls the network log kept, for a bug report.
    static func failedCallsText() -> String {
        let failed = NetworkLog.shared.snapshot.filter(\.failed)
        guard NetworkLog.shared.isOn || !failed.isEmpty else { return "(the network log was off)" }
        return failed.isEmpty ? "(no failed call kept)" : failed.map { call in
            "\(call.started.ISO8601Format()) \(call.path) \(call.code.map { "\($0)" } ?? "pending") \(call.errorMessage ?? "")"
        }.joined(separator: "\n")
    }

    // MARK: - Network

    private static var failedOnly = false
    private static var slowOnly = false

    private static func networkList() -> DebugListViewController {
        DebugListViewController(title: "Network") {
            let log = NetworkLog.shared
            let calls = log.snapshot.reversed().filter { call in
                (!failedOnly || call.failed) && (!slowOnly || (call.duration ?? 0) > 1)
            }
            let time = Date.FormatStyle(date: .omitted, time: .standard)
            return [
                DebugSection(title: nil, footer: log.isOn ? nil : "Off: turn it on, use the app, come back.", rows: [
                    .toggle(.tool(DebugTools.tool("network-log")!)),
                    .toggle(DebugToggle(title: "Failed calls only", detail: nil, isOn: { failedOnly }, set: { failedOnly = $0 })),
                    .toggle(DebugToggle(title: "Slow calls only (over 1 s)", detail: nil, isOn: { slowOnly }, set: { slowOnly = $0 })),
                ]),
                DebugSection(title: "\(calls.count) calls", rows: calls.prefix(200).map { call in
                    let status = call.code.map { "\($0)" } ?? "pending"
                    let ms = call.duration.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "…"
                    let title = "\(call.failed ? "⚠︎ " : "")\(call.service) · \(call.method)"
                    return .link("\(title)\n\(call.started.formatted(time)) · \(status) · \(ms) · \(call.requestBytes)→\(call.responseBytes ?? 0) B",
                                 symbol: nil, make: { callDetail(call) })
                }),
                DebugSection(title: nil, rows: [
                    .action("Share the Session", detail: "Every kept call as text, masked", run: { shareSession(calls: log.snapshot) }),
                    .action("Clear", detail: nil, run: { log.clear() }),
                ]),
            ]
        }
    }

    private static func callDetail(_ call: NetworkLog.Call) -> UIViewController {
        DebugListViewController(title: call.method) {
            [
                DebugSection(title: nil, rows: [
                    .info("Path", call.path),
                    .info("Started", call.started.formatted(date: .omitted, time: .standard)),
                    .info("Duration", call.duration.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "pending"),
                    .info("Status", call.code.map { "\($0)" } ?? "pending"),
                    .info("Error", call.errorMessage.map(DebugRedaction.redact) ?? "—"),
                    .info("Request", "\(call.requestBytes) B"),
                    .info("Response", call.responseBytes.map { "\($0) B" } ?? "—"),
                ]),
                DebugSection(title: "Bodies", footer: "Protobuf read without its schema; masked.", rows: [
                    .link("Request Body", symbol: nil, make: {
                        DebugTextViewController(title: "Request", text: body(call.requestBody))
                    }),
                    .link("Response Body", symbol: nil, make: {
                        DebugTextViewController(title: "Response", text: body(call.responseBody))
                    }),
                    .action("Share This Call", detail: nil, run: { shareSession(calls: [call]) }),
                ]),
            ]
        }
    }

    private static func body(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "(empty)" }
        let dump: String = DebugRedaction.redact(ProtoWireDump.dump(data))
        let cut: String = data.count >= NetworkLog.bodyCap ? "\n… cut at \(NetworkLog.bodyCap / 1024) KB" : ""
        return dump + cut
    }

    private static func shareSession(calls: [NetworkLog.Call]) {
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                let text = calls.map { call -> String in
                    let code: String = call.code.map { "\($0)" } ?? "pending"
                    let duration: String = call.duration.map { "\(Int(($0 * 1000).rounded()))ms" } ?? ""
                    let request: String = call.requestBody.map { DebugRedaction.redact(ProtoWireDump.dump($0)) } ?? "(empty)"
                    let response: String = call.responseBody.map { DebugRedaction.redact(ProtoWireDump.dump($0)) } ?? "(empty)"
                    return "\(call.started.ISO8601Format()) \(call.path) \(code) \(duration)\nrequest:\n\(request)\nresponse:\n\(response)\n"
                }.joined(separator: "\n")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("network-log.txt")
                return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
            }.value
            if let url { DebugDashboard.share([url]) }
        }
    }

    // MARK: - Caches and resets

    private static func cacheSections(container: AppContainer) -> [DebugSection] {
        let caches = container.cacheCoordinator.registeredCaches.sorted { $0.usage.bytes > $1.usage.bytes }
        let total = caches.reduce(0) { $0 + $1.usage.bytes }
        let bytes = ByteCountFormatter()
        var rows: [DebugRow] = caches.map { cache in
            let stats = cache.statistics
            let lookups = stats.hits + stats.misses
            let hitRate = lookups > 0 ? " · \(Int((Double(stats.hits) / Double(lookups) * 100).rounded()))% hits" : ""
            return .action(
                "Clear \(cache.namespace.name) (\(cache.medium))",
                detail: "\(bytes.string(fromByteCount: Int64(cache.usage.bytes))) · \(cache.usage.count) entries\(hitRate)",
                run: { cache.removeAll(reason: .clear) }
            )
        }
        rows.append(.action("Clear Every Cache", detail: bytes.string(fromByteCount: Int64(total)), run: {
            caches.forEach { $0.removeAll(reason: .clear) }
        }))
        var resets: [DebugRow] = []
        if let store = container.localStore {
            resets.append(.action("Clear the Local Store", detail: "Feed, chat, wallet history and pins kept offline", run: {
                store.removeAll()
            }))
        }
        resets.append(.action("Reset Onboarding, Tips and Preferences", detail: "Every app key in UserDefaults, flags included", run: {
            appDefaultsKeys().forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }))
        return [
            DebugSection(title: "Caches", footer: "The screens that use a cache reload from the network or the mock.", rows: rows),
            DebugSection(title: "Resets", rows: resets),
        ]
    }

    // MARK: - Preferences

    /// The app's own keys: what is not the system's.
    private static func appDefaultsKeys() -> [String] {
        let system = ["Apple", "NS", "AK", "com.apple", "PK", "WebKit", "MSV", "INNext", "UI", "_UI", "CK", "Car"]
        return UserDefaults.standard.dictionaryRepresentation().keys
            .filter { key in !system.contains { key.hasPrefix($0) } }
            .sorted()
    }

    private static func preferencesList() -> DebugListViewController {
        DebugListViewController(title: "Preferences") {
            let defaults = UserDefaults.standard
            let rows: [DebugRow] = appDefaultsKeys().map { key in
                let value = defaults.object(forKey: key)
                if let flag = value as? Bool {
                    return .toggle(DebugToggle(title: key, detail: nil, isOn: { defaults.bool(forKey: key) },
                                               set: { defaults.set($0, forKey: key) }))
                }
                let shown = value.map { DebugRedaction.redact("\($0)") } ?? "—"
                return .action(key, detail: String(shown.prefix(160)), run: { confirmRemove(key) })
            }
            return [DebugSection(title: "\(rows.count) keys", footer: "Tap a key to remove it. Switches flip booleans.", rows: rows)]
        }
    }

    private static func confirmRemove(_ key: String) {
        guard let top = DebugDashboard.topController() else { return }
        let alert = UIAlertController(title: key, message: "Remove this key?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
            UserDefaults.standard.removeObject(forKey: key)
            (top as? UINavigationController)?.viewControllers.compactMap { $0 as? DebugListViewController }.last?.reload()
        })
        top.present(alert, animated: true)
    }

    // MARK: - Permissions (read-only)

    private static func permissionsList() -> DebugListViewController {
        let controller = DebugListViewController(title: "Permissions") {
            [DebugSection(title: nil, footer: "Read only: change them in iOS Settings.", rows: [
                .info("Photos", "\(PHPhotoLibrary.authorizationStatus(for: .readWrite))"),
                .info("Camera", "\(AVCaptureDevice.authorizationStatus(for: .video))"),
                .info("Microphone", "\(AVAudioApplication.shared.recordPermission)"),
                .info("Location", "\(CLLocationManager().authorizationStatus)"),
                .info("Notifications", notificationStatus),
            ])]
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = "\(settings.authorizationStatus)"
            controller.reload()
        }
        return controller
    }

    private static var notificationStatus = "…"

    // MARK: - Local push

    private static func pushSections() -> [DebugSection] {
        let kinds: [(String, String, String, String)] = [
            ("A reaction on your post", "reaction", "post", "post-0000"),
            ("A comment", "comment", "post", "post-0003"),
            ("A new follower", "follow", "profile", "prof-demo-viewer"),
        ]
        return [DebugSection(
            title: "Delivered in 3 s",
            footer: "Background the app to see the banner, then tap it: it opens what a real push opens. Asks for notifications the first time.",
            rows: kinds.map { title, kind, subjectKind, subjectID in
                .action(title, detail: "\(kind) · \(subjectKind) \(subjectID)", run: {
                    deliver(title: title, kind: kind, subjectKind: subjectKind, subjectID: subjectID)
                })
            }
        )]
    }

    private static func deliver(title: String, kind: String, subjectKind: String, subjectID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let content = UNMutableNotificationContent()
            content.title = "Debug push"
            content.body = title
            content.userInfo = [
                "notification_id": UUID().uuidString, "kind": kind,
                "subject_kind": subjectKind, "subject_id": subjectID,
            ]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            )
            try? await center.add(request)
        }
    }

    // MARK: - Labs

    /// The labs, benches and audits are launch-time screens and traces: each
    /// row copies its simulator command. The haptics playground opens here
    /// instead (#2193): it is felt on a device, where a launch argument is
    /// awkward.
    private static func labSections() -> [DebugSection] {
        let groups: [(String, [(String, String)])] = [
            ("Labs", [
                ("Glass lens lab", "-lens-lab"),
                ("Voice messages lab", "-voice-lab"),
                // The comments sheet's shapes, tried without a rebuild
                // (#2195): any ratios, the layouts on their default.
                ("Comments sheet shapes (3:2 for 4:3)", "-comments-sheet-shapes \"3:4 1:1 3:2 16:9\""),
            ]),
            ("Benches", [
                ("Interaction latency bench", "-latency-bench"),
                ("Latency harness overhead (31 pushes)", "-latency-bench-auto 31"),
            ]),
            ("Audits", [
                ("Hero transitions", "-hero-audit"),
                ("Media", "-media-audit"),
                ("Carousel", "-carousel-audit"),
                ("Caches", "-cache-audit"),
                ("Post menu", "-post-menu-audit"),
                ("Status bar blur", "-status-bar-blur-audit"),
            ]),
        ]
        let playground = DebugSection(
            title: "Screens",
            footer: "Opens over the dashboard. Also -haptic-playground at launch.",
            rows: [
                .sheet("Haptics playground", detail: "Every haptic, in context and on the app's roles (#2193)", make: {
                    HapticPlaygroundViewController()
                }),
                .sheet("Voice component", detail: "Full, compact and mark, light and dark, text face and glass (#2205)", make: {
                    UINavigationController(rootViewController: VoiceCatalogViewController())
                }),
                .sheet("Embed card", detail: "A channel showcase's card: every size and state, light and dark (#2216)", make: {
                    UINavigationController(rootViewController: EmbedCatalogViewController())
                }),
            ]
        )
        return [playground] + groups.map { title, rows in
            DebugSection(
                title: title,
                footer: title == "Audits" ? "Each copies `xcrun simctl launch booted …`; the results print to the console." : nil,
                rows: rows.map { name, arguments in
                    .action(name, detail: arguments, run: {
                        UIPasteboard.general.string = "xcrun simctl launch booted cn.wynn.core-platform-ios -mock-auto-login \(arguments)"
                    })
                }
            )
        }
    }

    // MARK: - Mock scenarios

    /// The mock's dataset is built at launch from its arguments: a scenario
    /// is a relaunch with them (the simulator command is copied), or an
    /// in-app reset where one exists.
    private static func scenarioSections() -> [DebugSection] {
        let relaunch: [(String, String)] = [
            ("Guest", "-guest"),
            ("Empty wallet", "-wallet-reset"),
            ("Wallet with gems", "-wallet-gems 500"),
            ("Countries locked again", "-countries-reset"),
            ("Slow network (700 ms)", "-mock-latency 700"),
            ("Rich media", "-rich-media"),
        ]
        return [DebugSection(
            title: "Relaunch with",
            footer: "An app cannot relaunch itself: each copies the simulator command. The mock rebuilds its dataset from these at launch.",
            rows: relaunch.map { title, arguments in
                .action(title, detail: arguments, run: {
                    UIPasteboard.general.string = "xcrun simctl launch booted cn.wynn.core-platform-ios -mock-auto-login \(arguments)"
                })
            }
        )]
    }
}
#endif
