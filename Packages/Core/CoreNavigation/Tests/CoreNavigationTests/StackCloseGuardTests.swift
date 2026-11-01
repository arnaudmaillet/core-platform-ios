import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1144), like `RawHueGuardTests` for colours: a
/// screen closes through `closeScreen()` (its stack's `StackArbiter`) or
/// `closePresentation()` / `dismiss(presented:)` (DesignSystem), never
/// through a raw `popViewController(` or `dismiss(animated:`.
///
/// A raw pop closes whatever is on top, and a raw dismiss on a controller
/// presenting nothing closes the screen under it: both used to close a
/// screen the viewer had opened since, or a second one on a double tap.
///
/// It scans every source file under `App/` and `Packages/` (tests and
/// comments excluded). A file may keep a raw call only with a reason below.
///
/// CI only runs this in CoreNavigation's lane, which a change elsewhere does
/// not select: adding a close anywhere, run CoreNavigation's tests too.
struct StackCloseGuardTests {
    /// File name → why its raw call stays.
    static let allowed: [String: String] = [
        // The rule's own implementation.
        "StackArbiter.swift": "the arbiter's pop",
        // The two stacks that hand UIKit's pop (the back button's) to the
        // arbiter: the override, and its `super` call.
        "ArbitratedNavigationController.swift": "routes popViewController through the arbiter",
        "UploadNavigationController.swift": "routes popViewController through the arbiter",
        // The sign-in form's stack (#2022): the override, and its `super`
        // call — it only refuses UIKit's pop while a call runs.
        "ContentFittingNavigationController.swift": "holds UIKit's pop while a sign-in call runs",
        "PresentationClose.swift": "the guarded presentation close",
        // Not UIKit's `dismiss(animated:)`: a toast's own, on a view.
        "ToastView.swift": "the toast's own dismiss",
        "NavigationBarToasts.swift": "the toast's own dismiss",
        "PendingFeedback.swift": "the loading toast's own dismiss",
        "StakeMenu.swift": "the toast's own dismiss",
    ]

    static let patterns = ["popViewController(", "dismiss(animated:"]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CoreNavigationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CoreNavigation
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `line` closes a screen raw (a comment does not).
    static func closesRaw(_ line: Substring) -> Bool {
        let code = line.drop { $0 == " " || $0 == "\t" }
        guard !code.hasPrefix("//") else { return false }
        return patterns.contains { code.contains($0) }
    }

    @Test func theGuardSeesARawCloseAndNotAComment() {
        #expect(Self.closesRaw("        navigationController?.popViewController(animated: true)"))
        #expect(Self.closesRaw("    self?.dismiss(animated: true) { done() }"))
        #expect(!Self.closesRaw("    /// Kicks off `dismiss(animated:)` when a grab begins."))
        #expect(!Self.closesRaw("        closeScreen()"))
    }

    @Test func everyCloseGoesThroughTheArbiter() {
        var found: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      Self.allowed[url.lastPathComponent] == nil,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where Self.closesRaw(line) {
                    found.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(found.isEmpty, "raw closes — use closeScreen() / closePresentation() / dismiss(presented:): \(found)")
    }
}
