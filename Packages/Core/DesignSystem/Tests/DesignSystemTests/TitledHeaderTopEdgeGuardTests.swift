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
/// Since #2240 it also holds the soft blur to the contract, which rests
/// the first content below the blur's fade: no `topEdgeEffect.style =
/// .soft` by hand, and every opt-out of the clearance argued. What the
/// contract adds is pinned by `TopFadeClearanceTests`.
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

    /// File name → why it sets the soft style by hand rather than through
    /// the contract (#2240). None today: every soft top edge goes through
    /// `prefersSoftTopEdge()` / `applyTopEdge(for: .titled)`.
    static let softByHandAllowed: [String: String] = [:]

    private static let setsSoftByHand = try! NSRegularExpression(
        pattern: #"topEdgeEffect\.style = \.soft"#
    )

    /// Whether `text` sets the soft top-edge style itself.
    static func setsSoftStyleByHand(_ text: String) -> Bool {
        codeLines(text).contains { matches(setsSoftByHand, $0) }
    }

    /// ⚠️ THE SOFT BLUR GOES THROUGH THE CONTRACT (#2240): the contract also
    /// rests the first content below the blur's fade, so a screen setting
    /// `topEdgeEffect.style = .soft` itself gets the blur over its first
    /// row at rest — the owner's report on Relationships. Such a file needs
    /// a reason on `softByHandAllowed`.
    @Test func everySoftTopEdgeGoesThroughTheContract() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "ClearTopEdge.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.setsSoftStyleByHand(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.softByHandAllowed.keys)
        #expect(unexplained.isEmpty, "the soft top edge set by hand skips the fade's clearance — use applyTopEdge(for: .titled), or argue the case here: \(unexplained.sorted())")
        let stale = Set(Self.softByHandAllowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer set the soft style by hand — drop them from the list: \(stale.sorted())")
    }

    /// File name → why its soft top edge leaves the content in the fade
    /// (`prefersSoftTopEdge(keepsContentBelowFade: false)`, #2240).
    static let fadeClearanceOptOuts: [String: String] = [
        "PostDetailViewController.swift":
            "the comments sheet's stream owns its top inset (its shapes, #2195, and the short stream's anchor re-assert it): a clearance under it would fight them every pass",
        "NotificationsViewController.swift":
            "it rests on a large title, so its first section already starts far below the fade, which only reaches the rows once the title has folded into the bar by scrolling; a clearance there left 40 pt of empty space under the title (seen on the simulator)",
    ]

    @Test func everyFadeClearanceOptOutIsArgued() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "ClearTopEdge.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.codeLines(text).contains(where: { $0.contains("keepsContentBelowFade: false") }) {
                    found.insert(url.lastPathComponent)
                }
            }
        }
        let unexplained = found.subtracting(Self.fadeClearanceOptOuts.keys)
        #expect(unexplained.isEmpty, "a titled list left in the soft fade at rest — argue the case here: \(unexplained.sorted())")
        let stale = Set(Self.fadeClearanceOptOuts.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer opt out of the fade's clearance — drop them from the list: \(stale.sorted())")
    }

    @Test func theSoftByHandPatternFindsTheShape() {
        #expect(Self.setsSoftStyleByHand("collectionView.topEdgeEffect.style = .soft"))
        #expect(!Self.setsSoftStyleByHand("// collectionView.topEdgeEffect.style = .soft"))
        #expect(!Self.setsSoftStyleByHand("collectionView.applyTopEdge(for: .titled)"))
        #expect(!Self.setsSoftStyleByHand("edge.topEdgeEffect.style = .automatic"))
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
