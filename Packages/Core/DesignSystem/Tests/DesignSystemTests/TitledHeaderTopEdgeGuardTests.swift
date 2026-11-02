import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1591, the owner 2026-10-22): a screen whose header
/// has a TITLE wears the soft blur over its bar — `applyTopEdge(for:
/// .titled)` — and never clears its top edge.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded):
/// a file that sets a title (`title = …`, `self.title = …`,
/// `navigationItem.title = …`, nil aside) and clears its top edge
/// (`prefersClearTopEdge()`, `applyTopEdge(for: .untitled)`) needs a reason
/// on the list below.
///
/// ⚠️ A FILE-LEVEL HEURISTIC: a title set in one view controller and a list
/// configured in another (Relationships) is not seen — such a list states
/// `.titled` where it is configured.
///
/// CI only runs this in DesignSystem's lane: changing a screen's header
/// anywhere, run DesignSystem's tests too.
struct TitledHeaderTopEdgeGuardTests {
    /// File name → why its titled header stays clear.
    /// (The snap feed's embedded comment stream, where a blur would band the
    /// panel, clears its edge in `CommentStream`, which sets no title, since
    /// #2007.)
    static let allowed: [String: String] = [:]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private static let setsTitle = try! NSRegularExpression(
        pattern: #"(^|[^\w.])(self\.)?title = (?!nil)|navigationItem\.title = (?!nil)"#
    )
    private static let clearsTopEdge = try! NSRegularExpression(
        pattern: #"prefersClearTopEdge\(\)|applyTopEdge\(for: \.untitled\)"#
    )

    /// The code lines of `text`: comments and local `let`/`var` titles out.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Whether `text` sets a title and clears its top edge.
    static func titledButClear(_ text: String) -> Bool {
        let lines = codeLines(text)
        let titled = lines.contains { line in
            !line.hasPrefix("let ") && !line.hasPrefix("var ") && matches(setsTitle, line)
        }
        return titled && lines.contains { matches(clearsTopEdge, $0) }
    }

    @Test func everyTitledHeaderWearsTheSoftBlur() {
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
                if Self.titledButClear(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "a titled header clears its top edge — use applyTopEdge(for: .titled), or argue the case here: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer clear a titled header — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.titledButClear("title = \"Drafts\"\ncollectionView.prefersClearTopEdge()"))
        #expect(Self.titledButClear("navigationItem.title = viewModel.title\nlist.applyTopEdge(for: .untitled)"))
        #expect(!Self.titledButClear("title = \"Drafts\"\ncollectionView.applyTopEdge(for: .titled)"))
        #expect(!Self.titledButClear("navigationItem.title = nil\ncollectionView.prefersClearTopEdge()"))
        #expect(!Self.titledButClear("let title = formatter.string()\ncollectionView.prefersClearTopEdge()"))
        #expect(!Self.titledButClear("// title = \"x\"\ncollectionView.prefersClearTopEdge()"))
    }
}
