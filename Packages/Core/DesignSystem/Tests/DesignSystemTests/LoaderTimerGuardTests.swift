import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1768), like `StockSpinnerGuardTests`: a loader's
/// timing is the kit's (`LoaderGate`, `LoadingTiming`), never a timer a host
/// writes around `startAnimating()` — the audit of 2026-10-27 counted seven
/// such timers, with seven different delays.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for an `asyncAfter(`, a `Timer` or a `DispatchWorkItem` whose next lines
/// start a loader. A file may keep one only with a reason on the list below.
///
/// CI only runs this in DesignSystem's lane: adding a loader anywhere, run
/// DesignSystem's tests too.
struct LoaderTimerGuardTests {
    /// File name → why its timer stays.
    static let allowed: [String: String] = [
        "VideoRenderView.swift": "MediaPlayback sits below DesignSystem (CacheKit alone) and cannot use the gate; its catch-up delay is the player's design",
    ]

    static let timers = ["asyncAfter(", "Timer.scheduledTimer(", "Timer(timeInterval", "DispatchWorkItem"]
    /// How far after a timer a loader's start counts as inside it.
    static let reach = 12

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` starts a loader from a timer of its own — outside comments.
    static func timesALoader(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        for (index, line) in lines.enumerated() where timers.contains(where: line.contains) {
            let body = lines[index..<min(lines.count, index + reach)]
            if body.contains(where: { $0.contains("startAnimating(") }) { return true }
        }
        return false
    }

    @Test func noLoaderHasItsOwnTimer() {
        var found: Set<String> = []
        var scanned = 0
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                scanned += 1
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.timesALoader(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "time the loader with LoaderGate (or argue the case here): \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer time a loader by hand — drop them: \(stale.sorted())")
    }

    @Test func theScanFindsTheShape() {
        #expect(Self.timesALoader("""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.loader.startAnimating()
        }
        """))
        #expect(!Self.timesALoader("""
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        gate.begin()
        """))
    }
}
