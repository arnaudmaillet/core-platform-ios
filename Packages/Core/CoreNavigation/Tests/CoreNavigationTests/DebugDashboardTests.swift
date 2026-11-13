import Foundation
import Testing
import UIKit
@testable import CoreNavigation

/// The debug dashboard's rules (#2131): turn on only what the moment needs,
/// mask what leaves the screen, stay DEBUG only, and never be measured as the
/// app.
@MainActor
struct DebugDashboardTests {
    private func tool(_ id: String, costMs: Double?, on: Bool) -> DebugTool {
        var state = on
        return DebugTool(id: id, title: id, detail: "", cost: costMs.map { "~\($0) ms" }, costMs: costMs ?? 0,
                         isOn: { state }, apply: { state = $0 })
    }

    @Test func aSecondCostlyToolWarnsAndTheBadgeSumsThem() {
        let a = tool("test-a", costMs: 2, on: true)
        let b = tool("test-b", costMs: 3, on: false)
        let free = tool("test-free", costMs: nil, on: false)
        DebugTools.register(a)
        DebugTools.register(b)
        DebugTools.register(free)
        defer { [a, b, free].forEach { $0.set(false) } }
        #expect(DebugTools.warning(turningOn: free) == nil, "a free tool never warns")
        let warning = DebugTools.warning(turningOn: b)
        #expect(warning?.contains("2 costly tools") == true, "\(warning ?? "nil")")
        #expect(warning?.contains("5 ms") == true)
        b.set(true)
        #expect(DebugTools.badgeLine?.contains("~5 ms") == true, "\(DebugTools.badgeLine ?? "nil")")
        a.set(false)
        b.set(false)
        #expect(DebugTools.running.allSatisfy { !$0.id.hasPrefix("test-") })
    }

    @Test func aLoneCostlyToolDoesNotWarn() {
        let solo = tool("test-solo", costMs: 4, on: false)
        DebugTools.register(solo)
        let others = DebugTools.running.filter { $0.id != solo.id }
        others.forEach { $0.set(false) }
        #expect(DebugTools.warning(turningOn: solo) == nil)
    }

    @Test func whatLeavesTheScreenIsMasked() {
        // Built at run time: no source line holds a whole token, which a
        // secret scanner reads as a real one.
        let jwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjMifQ", "c2lnbmF0dXJl"].joined(separator: ".")
        let text: String = "Authorization: Bearer abc.def-123 token=s3cr3t user ava@example.com +33 6 12 34 56 78 "
            + "jwt \(jwt) password: hunter2"
        let masked = DebugRedaction.redact(text)
        for secret in ["abc.def-123", "s3cr3t", "ava@example.com", "12 34 56 78", "eyJhbGciOiJIUzI1NiJ9", "hunter2"] {
            #expect(!masked.contains(secret), "\(secret) leaked: \(masked)")
        }
        #expect(masked.contains("‹redacted›") && masked.contains("‹email›") && masked.contains("‹jwt›"))
    }

    /// ⚠️ DEBUG ONLY: every source of the dashboard compiles to nothing in
    /// Release.
    @Test func theDashboardIsDebugOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/DebugDashboard.swift",
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/DebugTools.swift",
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/DebugSections.swift",
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/ConsoleCapture.swift",
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/FrameRateOverlay.swift",
            "Packages/Core/CoreNavigation/Sources/CoreNavigation/DebugDashboard/DebugInterfaceTools.swift",
            "Packages/Core/CoreNetworking/Sources/CoreNetworking/NetworkLog.swift",
            "App/Shell/DebugDashboardTools.swift",
            "App/Shell/DebugDashboardWiring.swift",
            "Packages/Core/DebugTools/Sources/DebugTools/NetworkConditionsMenu.swift",
        ]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let code = text.split(separator: "\n").drop { $0.hasPrefix("//") || $0.isEmpty }
            #expect(code.first == "#if DEBUG", "\(file) does not open with #if DEBUG")
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"), "\(file) does not close with #endif")
        }
    }
}
