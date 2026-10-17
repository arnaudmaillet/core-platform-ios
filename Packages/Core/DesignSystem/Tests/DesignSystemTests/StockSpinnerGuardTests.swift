import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1329), like `RawHueGuardTests` for hues: every
/// loading state draws the branded loader (`AppLoaderView`,
/// `AppRefreshControl`, `HeroPullToRefreshView`), never the stock spinner.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for a stock `UIActivityIndicatorView(` or `UIRefreshControl(`. A file may
/// keep one only with a reason on the list below. Button busy states keep the
/// stock spinner through `UIButton.Configuration.showsActivityIndicator`
/// (decided 2026-10-17), which this scan does not match.
///
/// CI only runs this in DesignSystem's lane, which a change elsewhere does
/// not select: adding a spinner anywhere, run DesignSystem's tests too.
struct StockSpinnerGuardTests {
    /// File name → why its stock spinner stays.
    static let allowed: [String: String] = [
        "VideoRenderView.swift": "MediaPlayback sits below DesignSystem (it depends on CacheKit alone) and cannot draw the loader",
    ]

    static let patterns = ["UIActivityIndicatorView(", "UIRefreshControl("]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` builds a stock spinner — outside comments.
    static func buildsAStockSpinner(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && patterns.contains { code.contains($0) }
        }
    }

    @Test func everyLoaderIsTheBrandedOne() {
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
                if Self.buildsAStockSpinner(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "draw AppLoaderView / AppRefreshControl (or argue the case here): \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer build a stock spinner — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.buildsAStockSpinner("let spinner = UIActivityIndicatorView(style: .medium)"))
        #expect(Self.buildsAStockSpinner("private let refresh = UIRefreshControl()"))
        #expect(!Self.buildsAStockSpinner("let spinner = AppLoaderView(size: .medium)"))
        #expect(!Self.buildsAStockSpinner("/// mirrors `UIActivityIndicatorView(style:)`"))
    }
}
